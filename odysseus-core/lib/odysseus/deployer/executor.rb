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

      # Build Docker image
      # @param image_tag [String] docker image tag (e.g., "v1.0.0")
      # @param push [Boolean] push to registry after build
      # @param context_path [String] path to build context (defaults to config directory)
      # @return [Hash] build result
      def build(image_tag:, push: false, context_path: nil)
        context = context_path || resolve_build_context
        full_image = "#{@config[:image]}:#{image_tag}"

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
      # @param image_tag [String] docker image tag
      # @param context_path [String] path to build context
      # @param dry_run [Boolean] if true, don't actually deploy
      # @return [Hash] results
      def build_and_deploy(image_tag:, context_path: nil, dry_run: false)
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
      # @param image_tag [String] docker image tag
      # @return [Hash] pussh results
      def pussh(image_tag:)
        full_image = "#{@config[:image]}:#{image_tag}"
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
      # @param image_tag [String] docker image tag
      # @param context_path [String] path to build context
      # @return [Hash] build and pussh results
      def build_and_pussh(image_tag:, context_path: nil)
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
      # @param image_tag [String] docker image tag
      # @param context_path [String] path to build context
      # @return [Hash] build and distribution results
      def build_and_distribute(image_tag:, context_path: nil)
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
      # @param image_tag [String] docker image tag
      # @param context_path [String] path to build context
      # @return [Hash] build and push results
      def build_and_push_to_registry(image_tag:, context_path: nil)
        build_result = build(image_tag: image_tag, push: true, context_path: context_path)

        {
          build: build_result,
          push: build_result[:pushed] ? { success: true } : { success: false },
          success: build_result[:success] && build_result[:pushed]
        }
      end

      # Deploy all roles to their configured hosts
      # @param image_tag [String] docker image tag
      # @param dry_run [Boolean] if true, don't actually deploy
      def deploy_all(image_tag:, dry_run: false)
        results = {}

        @config[:servers].each do |role, role_config|
          hosts = resolve_hosts(role_config)
          hosts.each do |host|
            puts "\n=== Deploying #{role} to #{host} ==="
            results["#{role}@#{host}"] = deploy_role(host: host, image_tag: image_tag, dry_run: dry_run, role: role)
          end
        end

        results
      end

      # Deploy a single role to a specific host
      # @param host [String] target host (from config)
      # @param image_tag [String] docker image tag (e.g., "v1.2.3")
      # @param dry_run [Boolean] if true, don't actually deploy
      # @param role [Symbol] server role
      def deploy_role(host:, image_tag:, role:, dry_run: false)
        if dry_run
          puts "Dry run - would deploy #{@config[:image]}:#{image_tag} to #{host}"
          puts "Service: #{@config[:service]}"
          puts "Role: #{role}"
          puts "Proxy hosts: #{@config[:proxy][:hosts].join(', ')}" if role == WEB_ROLE
          return { success: true, dry_run: true }
        end

        ssh = connect_to_server(host)

        begin
          orchestrator = build_orchestrator(ssh, role)
          orchestrator.deploy(image_tag: image_tag, role: role)
        ensure
          ssh.close
        end
      end

      # Deploy an accessory to all its configured hosts
      # @param name [Symbol] accessory name
      def deploy_accessory(name:)
        acc_config = get_accessory_config(name)
        hosts = acc_config[:hosts] || []

        raise Odysseus::ConfigError, "No hosts configured for accessory #{name}" if hosts.empty?

        results = {}
        hosts.each do |host|
          puts "Deploying accessory #{name} to #{host}..."
          ssh = connect_to_server(host)

          begin
            orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config,
                                                                       secrets_loader: @secrets_loader)
            results[host] = orchestrator.deploy(name: name.to_sym)
          ensure
            ssh.close
          end
        end
        results
      end

      # Remove an accessory from all its configured hosts
      # @param name [Symbol] accessory name
      def remove_accessory(name:)
        acc_config = get_accessory_config(name)
        hosts = acc_config[:hosts] || []

        raise Odysseus::ConfigError, "No hosts configured for accessory #{name}" if hosts.empty?

        results = {}
        hosts.each do |host|
          puts "Removing accessory #{name} from #{host}..."
          ssh = connect_to_server(host)

          begin
            orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config,
                                                                       secrets_loader: @secrets_loader)
            results[host] = orchestrator.remove(name: name.to_sym)
          ensure
            ssh.close
          end
        end
        results
      end

      # Restart an accessory on all its configured hosts
      # @param name [Symbol] accessory name
      def restart_accessory(name:)
        acc_config = get_accessory_config(name)
        hosts = acc_config[:hosts] || []

        raise Odysseus::ConfigError, "No hosts configured for accessory #{name}" if hosts.empty?

        results = {}
        hosts.each do |host|
          puts "Restarting accessory #{name} on #{host}..."
          ssh = connect_to_server(host)

          begin
            orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config,
                                                                       secrets_loader: @secrets_loader)
            results[host] = orchestrator.restart(name: name.to_sym)
          ensure
            ssh.close
          end
        end
        results
      end

      # Upgrade an accessory to a new image version on all its configured hosts
      # @param name [Symbol] accessory name
      def upgrade_accessory(name:)
        acc_config = get_accessory_config(name)
        hosts = acc_config[:hosts] || []

        raise Odysseus::ConfigError, "No hosts configured for accessory #{name}" if hosts.empty?

        results = {}
        hosts.each do |host|
          puts "Upgrading accessory #{name} on #{host}..."
          ssh = connect_to_server(host)

          begin
            orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config,
                                                                       secrets_loader: @secrets_loader)
            results[host] = orchestrator.upgrade(name: name.to_sym)
          ensure
            ssh.close
          end
        end
        results
      end

      # List accessory status on all configured hosts
      def accessory_status
        return [] unless @config[:accessories]&.any?

        all_statuses = []
        @config[:accessories].each do |name, acc_config|
          hosts = acc_config[:hosts] || []
          hosts.each do |host|
            ssh = connect_to_server(host)
            begin
              orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config,
                                                                         secrets_loader: @secrets_loader)
              status = orchestrator.get_status(name: name.to_sym)
              status[:host] = host
              all_statuses << status
            ensure
              ssh.close
            end
          end
        end
        all_statuses
      end

      # Boot all accessories to their configured hosts
      def boot_accessories
        return {} unless @config[:accessories]&.any?

        results = {}
        @config[:accessories].each_key do |name|
          puts "\n=== Booting accessory: #{name} ==="
          results[name] = deploy_accessory(name: name)
        end
        results
      end

      private

      def get_accessory_config(name)
        name_sym = name.to_sym
        acc_config = @config[:accessories]&.[](name_sym)
        raise Odysseus::ConfigError, "Accessory '#{name}' not found in config" unless acc_config

        acc_config
      end

      def build_orchestrator(ssh, role)
        logger = build_logger
        role_config = @config[:servers][role] || {}
        strategy = role_config.dig(:deploy, :strategy)

        # Check if a sail plugin provides this strategy
        if strategy && Odysseus::Sails.registered?(strategy)
          sail_klass = Odysseus::Sails.resolve(strategy)
          sail_klass.new(
            ssh: ssh, config: @config, logger: logger, secrets_loader: @secrets_loader
          )
        elsif role == WEB_ROLE
          Odysseus::Orchestrator::WebDeploy.new(
            ssh: ssh, config: @config, logger: logger, secrets_loader: @secrets_loader
          )
        else
          Odysseus::Orchestrator::JobDeploy.new(
            ssh: ssh, config: @config, logger: logger, secrets_loader: @secrets_loader
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
        hosts = []

        @config[:servers].each_value do |role_config|
          role_hosts = resolve_hosts(role_config)
          hosts.concat(role_hosts)
        end

        hosts.uniq
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
