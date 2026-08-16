# odysseus-cli/lib/odysseus/cli/cli.rb

require 'odysseus'
require 'yaml'
require 'tempfile'
require_relative 'ui'
require_relative 'rollback_commands'
require_relative 'interactive_commands'

module Odysseus
  module CLI
    class CLI
      include RollbackCommands
      include InteractiveCommands

      def initialize(debug: false)
        @ui = UI.new(debug: debug)
      end

      # Deploy command
      def deploy(options = {})
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image]
        should_build = options[:build] || false
        dry_run = options[:'dry-run'] || false
        verbose = options[:verbose] || @ui.debug?

        config = load_config(config_file)
        uses_registry = config[:registry] && config[:registry][:server]

        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)
        resolved = executor.deploy_version(image_tag)

        distribution = uses_registry ? "registry (#{config[:registry][:server]})" : 'pussh (SSH)'
        @ui.deploy_header(
          service: config[:service],
          image: config[:image],
          image_tag: resolved.version,
          build: should_build,
          distribution: distribution
        )

        start_time = Time.now

        if should_build
          # Build phase — captured as streaming steps
          @ui.stream_steps(title: 'Building and distributing') do
            build_result = executor.build_and_distribute(image_tag: image_tag)

            raise Odysseus::BuildError, "Build failed: #{build_result[:build][:error]}" unless build_result[:build][:success]

            if uses_registry
              raise Odysseus::BuildError, 'Push to registry failed' unless build_result[:push][:success]
            else
              raise Odysseus::BuildError, 'Image distribution failed' unless build_result[:pussh][:success]
            end
          end
        end

        # Deploy phase — each orchestrator log line becomes a sub-step
        @ui.stream_steps(title: 'Deploying service') do
          executor.deploy_all(image_tag: image_tag, dry_run: dry_run)
        end

        duration = (Time.now - start_time).round(1)
        @ui.deploy_complete(duration: duration)
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      # Build command
      def build(options = {})
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image]
        push = options[:push] || false
        context_path = options[:context]
        verbose = options[:verbose] || @ui.debug?

        config = load_config(config_file)

        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)
        resolved = executor.deploy_version(image_tag)

        @ui.header 'Odysseus Build'
        @ui.info 'Image', "#{config[:image]}:#{resolved.version}"
        @ui.info 'Strategy', (config.dig(:builder, :strategy) || :local).to_s
        @ui.blank

        result = @ui.spin_step("Building image #{config[:image]}:#{resolved.version}") do
          executor.build(image_tag: image_tag, push: push, context_path: context_path)
        end

        if result[:success]
          @ui.step_ok 'Pushed to registry' if result[:pushed]
          @ui.step_ok 'Build complete'
        else
          @ui.step_fail "Build failed: #{result[:error]}"
          exit 1
        end
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      # Pussh command
      def pussh(options = {})
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image]
        should_build = options[:build] || false
        verbose = options[:verbose] || @ui.debug?

        config = load_config(config_file)

        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)
        resolved = executor.deploy_version(image_tag)

        @ui.header 'Odysseus Pussh'
        @ui.info 'Image', "#{config[:image]}:#{resolved.version}"
        @ui.blank

        if should_build
          result = @ui.spin_step("Building image #{config[:image]}:#{resolved.version}") do
            executor.build_and_pussh(image_tag: image_tag)
          end

          unless result[:build][:success]
            @ui.step_fail "Build failed: #{result[:build][:error]}"
            exit 1
          end
          pussh_result = result[:pussh]
        else
          pussh_result = @ui.spin_step('Pushing image via SSH...') do
            executor.pussh(image_tag: image_tag)
          end
        end

        if pussh_result[:success]
          @ui.step_ok "Pussh complete (#{pussh_result[:results]&.size || 0} host(s))"
        else
          @ui.step_fail 'Pussh failed'
          exit 1
        end
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      # Status command
      def status(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        config = load_config(config_file)
        service_name = config[:service]

        @ui.header 'Odysseus Status'
        @ui.info 'Service', service_name
        @ui.info 'Server', server
        @ui.blank

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          caddy = Odysseus::Caddy::Client.new(ssh: ssh, docker: docker)

          # Web containers
          @ui.section 'Web'
          web_containers = docker.list(service: service_name)
          if web_containers.empty?
            @ui.step '(no containers running)'
          else
            rows = web_containers.map { |c| web_container_row(c) }
            @ui.table(headers: %w[Version Ref Deployed Image State Health], rows: rows)
          end

          caddy_status = caddy.status
          if caddy_status[:running]
            svc_route = caddy_status[:services].find { |s| s[:service] == service_name }
            if svc_route
              @ui.info 'Proxy', svc_route[:hosts].join(', ')
              @ui.info 'Upstreams', svc_route[:upstreams].join(', ')
            end
          end
          @ui.blank

          # Workers
          non_web_roles = config[:servers].keys.reject { |r| r == :web }
          if non_web_roles.any?
            @ui.section 'Workers'
            rows = []
            non_web_roles.each do |role|
              role_service = "#{service_name}-#{role}"
              containers = docker.list(service: role_service)
              if containers.empty?
                rows << [role.to_s, 'stopped', '-', '-']
              else
                containers.each do |c|
                  rows << [role.to_s, c['State'], c['Names'], c['Image']]
                end
              end
            end
            @ui.table(headers: %w[Role State Name Image], rows: rows)
            @ui.blank
          end

          # Dependencies
          if config[:dependencies]&.any?
            @ui.section 'Dependencies'
            rows = config[:dependencies].map do |name, acc_config|
              acc_service = "#{service_name}-#{name}"
              containers = docker.list(service: acc_service, all: true)
              running = containers.find { |c| c['State'] == 'running' }
              if running
                health = running['Status'].include?('healthy') ? '✓' : ''
                [name.to_s, 'running', acc_config[:image], running['ID'][0..11], health]
              else
                [name.to_s, 'stopped', acc_config[:image], '-', '']
              end
            end
            @ui.table(headers: %w[Name State Image Container Health], rows: rows)
            @ui.blank
          end

          # TLS
          if config[:proxy][:hosts]&.any?
            @ui.section 'TLS'
            if caddy_status[:running] && caddy_status[:tls][:enabled]
              service_hosts = config[:proxy][:hosts]
              relevant_policy = caddy_status[:tls][:policies].find do |p|
                p[:subjects].intersect?(service_hosts)
              end
              if relevant_policy
                @ui.info 'Domains', (relevant_policy[:subjects] & service_hosts).join(', ')
                @ui.info 'Issuer', relevant_policy[:issuer]
                @ui.info 'Email', relevant_policy[:email] || '(not set)'
              else
                @ui.step '(not configured for this service)'
              end
            else
              @ui.step '(Caddy not running or TLS not configured)'
            end
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Containers command
      def containers(server, options = {})
        config_file = options[:config] || 'deploy.yml'

        @ui.header 'Odysseus Containers'
        @ui.info 'Server', server
        @ui.blank

        config = load_config(config_file)
        service_name = options[:service] || config[:service]
        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            @ui.step "No containers found for #{service_name}"
          else
            rows = containers.map do |c|
              [c['ID'][0..11], c['State'], c['Names'], c['Image'], c['Status']]
            end
            @ui.table(headers: %w[ID State Name Image Status], rows: rows)
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Validate command
      def validate(options = {})
        config_file = options[:config] || 'deploy.yml'

        @ui.header "Validating #{config_file}"
        config = load_config(config_file)

        @ui.success 'Configuration is valid'
        @ui.info 'Service', config[:service]
        @ui.info 'Image', config[:image]
        @ui.info 'Servers', config[:servers].keys.join(', ')
        @ui.info 'Proxy', config[:proxy][:hosts]&.join(', ')
        @ui.info 'Dependencies', config[:dependencies].keys.join(', ') if config[:dependencies]&.any?
      rescue Odysseus::Error => e
        @ui.error "Validation failed: #{e.message}"
        exit 1
      end

      # Dependency commands
      def dependency_boot(options = {})
        config_file = options[:config] || 'deploy.yml'
        name = require_name!(options)

        @ui.header 'Dependency Boot'
        @ui.info 'Dependency', name
        @ui.blank

        executor = Odysseus::Deployer::Executor.new(config_file)
        @ui.spin_step("Booting #{name}...") { executor.deploy_dependency(name: name) }
        @ui.step_ok "Dependency #{name} deployed"
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      def dependency_boot_all(options = {})
        config_file = options[:config] || 'deploy.yml'

        @ui.header 'Dependency Boot All'
        @ui.blank

        executor = Odysseus::Deployer::Executor.new(config_file)
        @ui.spin_step('Booting all dependencies...') { executor.boot_dependencies }
        @ui.step_ok 'All dependencies deployed'
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      def dependency_remove(options = {})
        config_file = options[:config] || 'deploy.yml'
        name = require_name!(options)

        @ui.header 'Dependency Remove'
        @ui.info 'Dependency', name
        @ui.blank

        executor = Odysseus::Deployer::Executor.new(config_file)
        @ui.spin_step("Removing #{name}...") { executor.remove_dependency(name: name) }
        @ui.step_ok "Dependency #{name} removed"
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      def dependency_restart(options = {})
        config_file = options[:config] || 'deploy.yml'
        name = require_name!(options)

        @ui.header 'Dependency Restart'
        @ui.info 'Dependency', name
        @ui.blank

        executor = Odysseus::Deployer::Executor.new(config_file)
        @ui.spin_step("Restarting #{name}...") { executor.restart_dependency(name: name) }
        @ui.step_ok "Dependency #{name} restarted"
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      def dependency_upgrade(options = {})
        config_file = options[:config] || 'deploy.yml'
        name = require_name!(options)

        @ui.header 'Dependency Upgrade'
        @ui.info 'Dependency', name
        @ui.blank

        executor = Odysseus::Deployer::Executor.new(config_file)
        @ui.spin_step("Upgrading #{name}...") { executor.upgrade_dependency(name: name) }
        @ui.step_ok "Dependency #{name} upgraded"
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end

      def dependency_status(options = {})
        config_file = options[:config] || 'deploy.yml'

        @ui.header 'Dependency Status'
        @ui.blank

        executor = Odysseus::Deployer::Executor.new(config_file)
        statuses = executor.dependency_status

        if statuses.empty?
          @ui.step 'No dependencies configured'
        else
          rows = statuses.map do |s|
            state = s[:running] ? 'running' : 'stopped'
            container = s[:container_id] ? s[:container_id][0..11] : '-'
            proxy = s[:has_proxy] ? '✓' : ''
            [s[:name].to_s, s[:host], state, s[:image], container, proxy]
          end
          @ui.table(headers: %w[Name Host State Image Container Proxy], rows: rows)
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Logs command
      def logs(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        role = (options[:role] || 'web').to_sym
        follow = options[:follow] || false
        lines = options[:lines] || 100
        since = options[:since]

        config = load_config(config_file)
        service_name = Odysseus::Docker::Labels.service_for(service: config[:service], role: role)

        @ui.header "Logs: #{service_name}"
        @ui.info 'Server', server
        @ui.blank

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          container_id = log_container_id!(docker, service_name, server, config, role: role)

          if follow
            @ui.step 'Following logs (Ctrl+C to stop)...'
            @ui.blank
            docker.logs(container_id, follow: true, tail: lines, since: since) { |line| print line }
          else
            puts docker.logs(container_id, tail: lines, since: since)
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Dependency logs
      def dependency_logs(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = require_name!(options)
        follow = options[:follow] || false
        lines = options[:lines] || 100
        since = options[:since]

        config = load_config(config_file)
        service_name = "#{config[:service]}-#{name}"

        @ui.header "Dependency Logs: #{service_name}"
        @ui.info 'Server', server
        @ui.blank

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          container_id = log_container_id!(docker, service_name, server, config)

          if follow
            @ui.step 'Following logs (Ctrl+C to stop)...'
            @ui.blank
            docker.logs(container_id, follow: true, tail: lines, since: since) { |line| print line }
          else
            puts docker.logs(container_id, tail: lines, since: since)
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # App exec
      def app_exec(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        role = (options[:role] || 'web').to_sym
        command = options[:command]

        unless command
          @ui.error 'Command required (--command)'
          exit 1
        end

        config = load_config(config_file)
        image = running_image(server, config, role)

        @ui.header 'App Exec'
        @ui.info 'Server', server
        @ui.info 'Role', role
        @ui.info 'Command', command
        @ui.blank

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          env = build_environment(config, config_file, ssh)

          puts docker.run_once(image: image, command: command, options: { env: env, network: 'odysseus' })
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Dependency exec
      def dependency_exec(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = require_name!(options)
        command = options[:command]

        unless command
          @ui.error 'Command required (--command)'
          exit 1
        end

        config = load_config(config_file)
        service_name = "#{config[:service]}-#{name}"

        @ui.header 'Dependency Exec'
        @ui.info 'Dependency', name
        @ui.info 'Command', command
        @ui.blank

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            @ui.error "No running containers found for #{service_name}"
            exit 1
          end

          puts docker.exec(containers.first['ID'], command)
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Cleanup command
      def cleanup(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        prune_images = options[:all] || false

        config = load_config(config_file)
        service_name = config[:service]

        @ui.header 'Odysseus Cleanup'
        @ui.info 'Service', service_name
        @ui.info 'Server', server
        @ui.blank

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          caddy = Odysseus::Caddy::Client.new(ssh: ssh, docker: docker)

          if @ui.debug?
            @ui.section 'Disk usage (before)'
            puts docker.disk_usage
            @ui.blank
          end

          service_names = [service_name]
          config[:servers].keys.reject { |r| r == :web }.each { |role| service_names << "#{service_name}-#{role}" }
          config[:dependencies]&.each_key { |name| service_names << "#{service_name}-#{name}" }

          total_removed = 0
          service_names.each do |svc|
            containers = docker.list(service: svc, all: true)
            containers.each do |c|
              docker.stop(c['ID'], timeout: 10) if c['State'] == 'running'
              docker.remove(c['ID'], force: true)
              total_removed += 1
            end
          end

          @ui.step "Removed #{total_removed} container(s)"

          # Clean Caddy routes
          if caddy.running?
            begin
              caddy.remove_upstream(service: service_name, upstream: nil)
            rescue StandardError
              nil
            end
            config[:dependencies]&.each do |name, acc_config|
              next unless acc_config[:proxy]

              begin
                caddy.remove_upstream(service: "#{service_name}-#{name}", upstream: nil)
              rescue StandardError
                nil
              end
            end

            remaining = caddy.list_services.reject { |s| s[:service] == 'unknown' || s[:service].empty? }
            if remaining.empty?
              begin
                docker.stop('odysseus-caddy', timeout: 10)
              rescue StandardError
                nil
              end
              begin
                docker.remove('odysseus-caddy', force: true)
              rescue StandardError
                nil
              end
              @ui.step 'Caddy removed (no other services)'
            else
              @ui.step "Caddy kept (#{remaining.size} other service(s))"
            end
          end

          if prune_images
            @ui.step 'Pruning dangling images...'
            docker.prune(containers: false, images: true, volumes: false, networks: false)
          end

          @ui.blank
          @ui.success 'Cleanup complete'
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Secrets commands
      def secrets_generate_key(_options = {})
        @ui.header 'Secrets: Generate Key'
        @ui.blank

        key = Odysseus::Secrets::EncryptedFile.generate_key
        @ui.success 'Generated master key:'
        @ui.blank
        puts "  #{key}"
        @ui.blank
        @ui.warn 'Save this key securely!'
        @ui.step 'Set as ODYSSEUS_MASTER_KEY environment variable'
      end

      def secrets_encrypt(options = {})
        input_file = options[:input]
        output_file = options[:file] || 'secrets.yml.enc'

        unless input_file
          @ui.error 'Input file required (--input)'
          exit 1
        end

        unless File.exist?(input_file)
          @ui.error "Input file not found: #{input_file}"
          exit 1
        end

        @ui.header 'Secrets: Encrypt'
        @ui.info 'Input', input_file
        @ui.info 'Output', output_file
        @ui.blank

        secrets = YAML.load_file(input_file)
        encrypted_file = Odysseus::Secrets::EncryptedFile.new(output_file)
        encrypted_file.write(secrets)

        @ui.success "Secrets encrypted to #{output_file}"
      rescue Odysseus::Secrets::EncryptedFile::MissingKeyError => e
        @ui.error e.message
        @ui.step 'Generate a key with: odysseus secrets generate-key'
        exit 1
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      def secrets_decrypt(options = {})
        secrets_file = options[:file] || 'secrets.yml.enc'

        unless File.exist?(secrets_file)
          @ui.error "Secrets file not found: #{secrets_file}"
          exit 1
        end

        @ui.header 'Secrets: Decrypt'
        @ui.info 'File', secrets_file
        @ui.blank

        encrypted_file = Odysseus::Secrets::EncryptedFile.new(secrets_file)
        secrets = encrypted_file.read

        secrets.each do |key, value|
          masked = value.to_s.length > 4 ? "#{value[0..3]}#{'*' * (value.length - 4)}" : '****'
          @ui.info key, masked
        end
        @ui.blank
        @ui.step '(values masked)'
      rescue Odysseus::Secrets::EncryptedFile::MissingKeyError, Odysseus::Secrets::EncryptedFile::DecryptionError => e
        @ui.error e.message
        exit 1
      end

      def secrets_edit(options = {})
        secrets_file = options[:file] || 'secrets.yml.enc'
        editor = ENV['EDITOR'] || 'vi'

        @ui.header 'Secrets: Edit'
        @ui.info 'File', secrets_file
        @ui.info 'Editor', editor
        @ui.blank

        encrypted_file = Odysseus::Secrets::EncryptedFile.new(secrets_file)
        secrets = encrypted_file.exists? ? encrypted_file.read : {}

        temp_file = Tempfile.new(['secrets', '.yml'])
        begin
          temp_file.write(YAML.dump(secrets))
          temp_file.close

          system("#{editor} #{temp_file.path}")

          edited_secrets = YAML.load_file(temp_file.path)
          encrypted_file.write(edited_secrets)

          @ui.success 'Secrets updated and encrypted'
        ensure
          temp_file.unlink
        end
      rescue Odysseus::Secrets::EncryptedFile::MissingKeyError => e
        @ui.error e.message
        @ui.step 'Generate a key with: odysseus secrets generate-key'
        exit 1
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      private

      def load_config(config_file)
        parser = Odysseus::Config::Parser.new(config_file)
        parser.parse
      end

      def web_container_row(container)
        labels = Odysseus::Docker::Labels.parse(container['Labels'])
        version = labels['odysseus.version'] || '(unlabelled)'
        ref = labels['odysseus.git_ref'] || '-'
        deployed_at = labels['odysseus.deployed_at'] || '-'
        health = container['Status'].include?('(healthy)') ? '✓' : ''
        [version, ref, deployed_at, container['Image'], container['State'], health]
      end

      # The image reference that is actually serving, so a one-off container runs
      # the same code as the deployed one. Prefers the container's own Image
      # field, which docker ps reports directly, over reconstructing a tag from
      # the odysseus.version label: a container deployed before this branch
      # carries a deploy timestamp in that label and was built from an image
      # tagged `latest`, so reconstruction would name a tag that was never
      # pushed. Falling back to reconstruction only covers the case where
      # Image is somehow absent from docker's own output.
      #
      # The lookup goes through Labels.service_for because only the web role is
      # labelled with the bare service name. Asking for that name on a jobs host
      # matches nothing, and on a service with no web role it matches nothing
      # anywhere — which is what these commands did before they took a role.
      def running_image(server, config, role)
        service_name = Odysseus::Docker::Labels.service_for(service: config[:service], role: role)
        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          container = docker.list(service: service_name).first

          # No search of other roles: running a command against a role other
          # than the one asked for is worse than being told what to type.
          no_container!(server, config, service_name, role: role, state: 'running') unless container

          container['Image'] || "#{config[:image]}:#{Odysseus::Docker::Labels.version_of(container)}"
        ensure
          ssh.close
        end
      end

      # The container to read logs from, chosen from everything carrying the
      # service label — stopped containers included. `docker ps` without -a
      # hides the container that has just exited, which is precisely the one
      # whose logs you came for, and cleanup keeps the previous two deploys
      # around on purpose, so a stopped container is the normal state of a host
      # rather than an edge case. `status` and `cleanup` already read with
      # all: true.
      #
      # Finding nothing is a failed request for logs, not a success, so it
      # exits non-zero. And when the only match is stopped, say so: otherwise
      # the log just ends and the reader has no way to know why.
      #
      # That notice goes to stderr. This command's stdout is a log stream —
      # `odysseus logs web1 > app.log`, or a pipe into something that parses it
      # — so a line about the logs must not arrive inside them, while still
      # reaching the terminal of whoever ran the command.
      #
      # @param role [Symbol, nil] the role the label came from, or nil for a
      #   dependency, which is named with --name rather than --role
      def log_container_id!(docker, service_name, server, config, role: nil)
        containers = docker.list(service: service_name, all: true)
        no_container!(server, config, service_name, role: role, state: 'running or stopped') if containers.empty?

        container = containers.find { |c| c['State'] == 'running' } || containers.first
        unless container['State'] == 'running'
          @ui.warn "No running container for #{service_name}: showing logs from " \
                   "#{container['State']} container #{container['ID'][0..11]}", io: $stderr
        end

        container['ID']
      end

      # What a container lookup that found nothing says, for every command that
      # finds one by its odysseus.service label. A mistyped --role is the
      # ordinary reason nothing matches, so the message names the role, the
      # exact label searched, the option that changes it and the roles this
      # config declares. `logs` used to say only `No containers found for
      # myapp-jbos on w1 (stopped ones included)`, naming a label the reader
      # never typed: one job, two messages, and only one of them any use.
      #
      # A dependency passes no role. It is chosen with --name, and advising
      # --role would send the reader to an option that command does not have.
      def no_container!(server, config, service_name, role: nil, state: 'running')
        subject = role ? "role '#{role}'" : service_name
        @ui.error "No #{state} container for #{subject} on #{server} " \
                  "(nothing labelled odysseus.service=#{service_name})", io: $stderr
        if role
          @ui.step "Name the role with --role. Roles in this config: #{config[:servers].keys.join(', ')}",
                   io: $stderr
        end
        exit 1
      end

      # The environment a one-off container starts with, built by the same class
      # the deploy paths use. These commands used to inject env.clear alone, so
      # `app exec … --command "rails db:migrate"` ran against a container with
      # no DATABASE_URL while the container deployed seconds earlier had one.
      #
      # The secrets loader resolves a relative secrets_file against the
      # directory holding deploy.yml rather than the working directory, which is
      # what Executor does and what `--config ../other/deploy.yml` needs.
      def build_environment(config, config_file, ssh)
        loader = Odysseus::Secrets::Loader.new(config, config_dir: File.dirname(config_file))
        Odysseus::Core::Environment.new(config: config, secrets_loader: loader, ssh: ssh).build
      end

      def connect_to_server(server, config)
        Odysseus::Deployer::SSH.new(
          host: server,
          user: config[:ssh][:user],
          keys: config[:ssh][:keys],
          use_tailscale: true
        )
      end

      def require_name!(options)
        name = options[:name]
        unless name
          @ui.error 'Dependency name required (--name)'
          exit 1
        end
        name
      end
    end
  end
end
