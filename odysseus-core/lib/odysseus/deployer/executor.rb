# lib/odysseus/deployer/executor.rb

module Odysseus
  module Deployer
    class Executor
      WEB_ROLE = :web

      # @param config_path [String] path to deploy.yml
      # @param verbose [Boolean] show commands being executed
      def initialize(config_path, verbose: false)
        @config_path = config_path
        @config_dir = File.dirname(config_path)
        parser = Odysseus::Config::Parser.new(config_path)
        @config = parser.parse
        @verbose = verbose
        @secrets_loader = Odysseus::Secrets::Loader.new(@config, config_dir: @config_dir)
      end

      # The identity of the deploy: version, ref and deployer.
      #
      # Resolved once per tag so a multi-role, multi-host deploy cannot end up
      # with two versions, and so the git commands run once rather than per host.
      #
      # @param image_tag [String, nil] explicit tag, or nil to resolve from git
      # @return [Odysseus::DeployVersion]
      def deploy_version(image_tag = nil)
        @deploy_versions ||= {}
        @deploy_versions[image_tag] ||= version_resolver.resolve(image_tag: image_tag)
      end

      # Build Docker image
      # @param image_tag [String, nil] docker image tag (e.g., "v1.0.0"), or nil to resolve from git
      # @param push [Boolean] push to registry after build
      # @param context_path [String] path to build context (defaults to config directory)
      # @return [Hash] build result
      def build(image_tag: nil, push: false, context_path: nil)
        resolved = deploy_version(image_tag)
        context = context_path || resolve_build_context
        full_image = "#{@config[:image]}:#{resolved.version}"

        builder = build_builder

        if push
          builder.build_and_push(
            context_path: context,
            image: full_image,
            registry: @config[:registry]
          )
        else
          builder.build(context_path: context, image: full_image)
        end
      end

      # Build and deploy in one step
      # @param image_tag [String, nil] docker image tag, or nil to resolve from git
      # @param context_path [String] path to build context
      # @param dry_run [Boolean] if true, don't actually deploy
      # @return [Hash] results
      def build_and_deploy(image_tag: nil, context_path: nil, dry_run: false)
        # First, build the image
        build_result = build(image_tag: image_tag, push: true, context_path: context_path)

        return { build: build_result, deploy: nil, success: false } unless build_result[:success]

        # Then deploy
        deploy_results = deploy_all(image_tag: image_tag, dry_run: dry_run)

        {
          build: build_result,
          deploy: deploy_results,
          success: deploy_results.values.all? { |r| r[:success] }
        }
      end

      # Push image to all configured hosts via SSH (using docker pussh)
      # @param image_tag [String, nil] docker image tag, or nil to resolve from git
      # @return [Hash] pussh results
      def pussh(image_tag: nil)
        resolved = deploy_version(image_tag)
        full_image = "#{@config[:image]}:#{resolved.version}"
        hosts = collect_all_hosts

        return { success: false, error: 'No hosts configured' } if hosts.empty?

        builder = build_builder
        builder.pussh_to_hosts(
          image: full_image,
          hosts: hosts,
          user: @config[:ssh][:user]
        )
      end

      # Build and pussh to all hosts (no registry needed)
      # @param image_tag [String, nil] docker image tag, or nil to resolve from git
      # @param context_path [String] path to build context
      # @return [Hash] build and pussh results
      def build_and_pussh(image_tag: nil, context_path: nil)
        # First, build the image locally
        build_result = build(image_tag: image_tag, push: false, context_path: context_path)

        return { build: build_result, pussh: nil, success: false } unless build_result[:success]

        # Then pussh to all hosts
        pussh_result = pussh(image_tag: image_tag)

        {
          build: build_result,
          pussh: pussh_result,
          success: pussh_result[:success]
        }
      end

      # Build and distribute image based on config
      # Uses registry if configured, otherwise pussh to hosts
      # @param image_tag [String, nil] docker image tag, or nil to resolve from git
      # @param context_path [String] path to build context
      # @return [Hash] build and distribution results
      def build_and_distribute(image_tag: nil, context_path: nil)
        if uses_registry?
          build_and_push_to_registry(image_tag: image_tag, context_path: context_path)
        else
          build_and_pussh(image_tag: image_tag, context_path: context_path)
        end
      end

      # Check if config uses a registry for image distribution
      # @return [Boolean]
      def uses_registry?
        @config[:registry] && @config[:registry][:server]
      end

      # Build and push to registry
      # @param image_tag [String, nil] docker image tag, or nil to resolve from git
      # @param context_path [String] path to build context
      # @return [Hash] build and push results
      def build_and_push_to_registry(image_tag: nil, context_path: nil)
        build_result = build(image_tag: image_tag, push: true, context_path: context_path)

        {
          build: build_result,
          push: build_result[:pushed] ? { success: true } : { success: false },
          success: build_result[:success] && build_result[:pushed]
        }
      end

      # Deploy all roles to their configured hosts
      # @param image_tag [String, nil] docker image tag, or nil to resolve from git
      # @param dry_run [Boolean] if true, don't actually deploy
      def deploy_all(image_tag: nil, dry_run: false)
        results = {}

        @config[:servers].each do |role, role_config|
          hosts = resolve_hosts(role_config)
          hosts.each do |host|
            puts "\n=== Deploying #{role} to #{host} ==="
            results["#{role}@#{host}"] = deploy_role(host: host, image_tag: image_tag, dry_run: dry_run, role: role)
          end
        end

        prune_old_images unless dry_run

        results
      end

      # What every host reports about this service's versions.
      #
      # One entry per unique host across all roles, so a host serving two roles
      # is surveyed once. Connections are opened and closed per host.
      #
      # @return [Array<Odysseus::HostVersions>]
      def version_survey
        host_roles.map do |host, roles|
          ssh = connect_to_server(host)

          begin
            Odysseus::HostVersions.read(
              host: host, ssh: ssh, service: @config[:service], image: @config[:image], roles: roles
            )
          ensure
            ssh.close
          end
        end
      end

      # Decide what a rollback would do, without doing it.
      #
      # Surveys the fleet and returns the plan, or raises RollbackError with a
      # message naming the hosts at fault. Separate from rollback_all so the
      # caller can show the target — and any approximate-ordering warning —
      # before anything is touched, and so the survey runs once.
      #
      # @param version [String, nil] explicit target, or nil for the previous one
      # @return [Odysseus::RollbackPlan]
      def rollback_plan(version: nil)
        Odysseus::RollbackPlanner.new(version_survey).plan(version: version)
      end

      # Roll every role on every host back to the planned version.
      #
      # Reuses the deploy path unchanged, so health gating, proxy handling and
      # zero-downtime behaviour are shared with deploy rather than
      # reimplemented. Sequential, and inheriting deploy's partial-failure
      # semantics: the plan's pre-flight rules out the common cause of a
      # half-rolled-back fleet — a missing image — but does not make the roll
      # atomic.
      #
      # @param plan [Odysseus::RollbackPlan] from #rollback_plan
      # @return [Hash] results keyed "role@host"
      def rollback_all(plan)
        resolved = Odysseus::DeployVersion.new(
          version: plan.version, ref: plan.ref, deployer: version_resolver.deployer
        )
        results = {}

        @config[:servers].each do |role, role_config|
          resolve_hosts(role_config).each do |host|
            puts "\n=== Rolling back #{role} on #{host} to #{plan.version} ==="
            results["#{role}@#{host}"] = run_deploy(
              host: host, role: role, resolved: resolved,
              kind: 'rolled-back', from: plan.from_for(host)
            )
          end
        end

        results
      end

      # Delete a service's images that no host needs any more.
      #
      # @return [Hash{String => Array<String>}] versions removed, keyed by host
      def prune_old_images
        retention_sweeper.sweep(host_roles)
      end

      # Deploy a single role to a specific host
      # @param host [String] target host (from config)
      # @param image_tag [String, nil] docker image tag (e.g., "v1.2.3"), or nil to resolve from git
      # @param dry_run [Boolean] if true, don't actually deploy
      # @param role [Symbol] server role
      def deploy_role(host:, role:, image_tag: nil, dry_run: false)
        resolved = deploy_version(image_tag)

        if dry_run
          puts "Dry run - would deploy #{@config[:image]}:#{resolved.version} to #{host}"
          puts "Service: #{@config[:service]}"
          puts "Role: #{role}"
          puts "Proxy hosts: #{@config[:proxy][:hosts].join(', ')}" if role == WEB_ROLE
          return { success: true, dry_run: true }
        end

        run_deploy(host: host, role: role, resolved: resolved)
      end

      # Deploy an dependency to all its configured hosts
      # @param name [Symbol] dependency name
      def deploy_dependency(name:)
        dependency_manager.deploy(name: name)
      end

      # Remove an dependency from all its configured hosts
      # @param name [Symbol] dependency name
      def remove_dependency(name:)
        dependency_manager.remove(name: name)
      end

      # Restart an dependency on all its configured hosts
      # @param name [Symbol] dependency name
      def restart_dependency(name:)
        dependency_manager.restart(name: name)
      end

      # Upgrade an dependency to a new image version on all its configured hosts
      # @param name [Symbol] dependency name
      def upgrade_dependency(name:)
        dependency_manager.upgrade(name: name)
      end

      # List dependency status on all configured hosts
      def dependency_status
        dependency_manager.status
      end

      # Boot all dependencies to their configured hosts
      def boot_dependencies
        dependency_manager.boot_all
      end

      private

      # Dependency verbs are a distinct concern from deploy/rollback; see
      # Odysseus::Deployer::DependencyManager.
      def dependency_manager
        @dependency_manager ||= Odysseus::Deployer::DependencyManager.new(
          config: @config, secrets_loader: @secrets_loader, connector: method(:connect_to_server)
        )
      end

      def version_resolver
        @version_resolver ||= Odysseus::VersionResolver.new(config_dir: @config_dir, logger: build_logger)
      end

      # Image retention is a distinct concern from deploy/rollback; see
      # Odysseus::Deployer::RetentionSweeper.
      def retention_sweeper
        @retention_sweeper ||= Odysseus::Deployer::RetentionSweeper.new(
          config: @config, connector: method(:connect_to_server), logger: build_logger
        )
      end

      # Sails are constructed with a fixed keyword set, so version metadata
      # travels in the config hash rather than as a new keyword argument.
      def orchestrator_config(resolved)
        @config.merge(deploy_version: resolved)
      end

      # One role on one host: connect, hand off to the orchestrator, record the
      # outcome on the host, close. Shared by deploy and rollback so both get
      # identical health gating, proxy handling and audit trail.
      #
      # @param kind [String] 'deployed' or 'rolled-back'
      # @param from [String, nil] the version being replaced, for a rollback
      def run_deploy(host:, role:, resolved:, kind: 'deployed', from: nil)
        ssh = connect_to_server(host)

        begin
          orchestrator = build_orchestrator(ssh, role, resolved)
          result = orchestrator.deploy(image_tag: resolved.version, role: role)
          record_deploy(ssh: ssh, host: host, role: role, resolved: resolved, kind: kind, from: from)
          result
        ensure
          ssh.close
        end
      end

      # The host's own record of what it is running, written only after the
      # orchestrator reports success.
      #
      # Best effort, and deliberately rescuing StandardError rather than
      # Odysseus::Error: SSH#execute can also raise Net::SSH::Disconnect,
      # IOError or Net::SSH::ChannelOpenFailed, none of which with_connection
      # translates. Traffic has already switched by this point, so any of them
      # escaping here would turn a completed deploy into a reported failure.
      def record_deploy(ssh:, host:, role:, resolved:, kind:, from:)
        Odysseus::DeployLog.new(ssh: ssh, service: @config[:service]).append(
          version: resolved.version, role: role, ref: resolved.ref,
          deployer: resolved.deployer, kind: kind, from: from
        )
      rescue StandardError => e
        build_logger.warn("Could not record the deploy on #{host}: #{e.message}")
      end

      def build_orchestrator(ssh, role, resolved)
        logger = build_logger
        role_config = @config[:servers][role] || {}
        strategy = role_config.dig(:deploy, :strategy)
        config = orchestrator_config(resolved)

        # Check if a sail plugin provides this strategy
        if strategy && Odysseus::Sails.registered?(strategy)
          sail_klass = Odysseus::Sails.resolve(strategy)
          sail_klass.new(
            ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader
          )
        elsif role == WEB_ROLE
          Odysseus::Orchestrator::WebDeploy.new(
            ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader
          )
        else
          Odysseus::Orchestrator::JobDeploy.new(
            ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader
          )
        end
      end

      def build_logger
        verbose = @verbose
        Object.new.tap do |l|
          l.define_singleton_method(:info) { |msg| puts msg }
          l.define_singleton_method(:warn) { |msg| puts "[WARN] #{msg}" }
          l.define_singleton_method(:error) { |msg| puts "[ERROR] #{msg}" }
          l.define_singleton_method(:debug) { |msg| puts "  > #{msg}" if verbose }
          l.define_singleton_method(:verbose?) { verbose }
        end
      end

      def connect_to_server(server)
        Odysseus::Deployer::SSH.new(
          host: server,
          user: @config[:ssh][:user],
          keys: @config[:ssh][:keys],
          use_tailscale: true,
          verbose: @verbose
        )
      end

      def build_builder
        Odysseus::Builder::Client.new(
          config: @config[:builder],
          ssh_config: @config[:ssh],
          logger: build_logger,
          verbose: @verbose
        )
      end

      def resolve_build_context
        builder_config = @config[:builder]
        context = builder_config[:context] || '.'

        if context.start_with?('/')
          context
        else
          File.join(@config_dir, context)
        end
      end

      def collect_all_hosts
        host_roles.keys
      end

      # Every configured host mapped to the roles it serves, each in config
      # order. A host serving two roles (e.g. web and cron on the same box)
      # gets both, in the order its roles are declared in deploy.yml — the
      # order #version_survey depends on to know which role's containers to
      # look for first.
      #
      # @return [Hash{String => Array<Symbol>}]
      def host_roles
        roles_by_host = {}

        @config[:servers].each do |role, role_config|
          resolve_hosts(role_config).each { |host| (roles_by_host[host] ||= []) << role }
        end

        roles_by_host
      end

      # Resolve hosts for a role using the appropriate provider
      # @param role_config [Hash] role configuration
      # @return [Array<String>] list of hosts
      def resolve_hosts(role_config)
        Odysseus::HostProviders.resolve(role_config)
      end
    end
  end
end
