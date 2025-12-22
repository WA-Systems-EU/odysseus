# odysseus-cli/lib/odysseus/cli/cli.rb

require 'odysseus'
require 'odysseus/deployer/executor'
require 'odysseus/config/parser'
require 'odysseus/deployer/ssh'
require 'odysseus/docker/client'
require 'odysseus/caddy/client'
require 'odysseus/secrets/encrypted_file'
require 'pastel'
require 'yaml'
require 'tempfile'

module Odysseus
  module CLI
    class CLI
      def initialize
        @pastel = Pastel.new
      end

      # Deploy command - deploys all roles to their configured hosts
      # Usage: odysseus deploy [--config FILE] [--image TAG] [--build] [--dry-run] [--verbose]
      def deploy(options = {})
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image] || 'latest'
        should_build = options[:build] || false
        dry_run = options[:'dry-run'] || false
        verbose = options[:verbose] || false

        config = load_config(config_file)
        uses_registry = config[:registry] && config[:registry][:server]

        puts @pastel.cyan("Odysseus Deploy")
        puts @pastel.blue("Service: #{config[:service]}")
        puts @pastel.blue("Image: #{config[:image]}:#{image_tag}")
        if should_build
          distribution = uses_registry ? "registry (#{config[:registry][:server]})" : "pussh (SSH)"
          puts @pastel.blue("Build & distribute via: #{distribution}")
        end
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)

        # Build and distribute image if requested
        if should_build
          puts @pastel.cyan("=== Building and distributing image ===")
          result = executor.build_and_distribute(image_tag: image_tag)

          if result[:build][:success]
            puts @pastel.green("Build complete!")
          else
            puts @pastel.red("Build failed: #{result[:build][:error]}")
            exit 1
          end

          # Handle distribution result (either pussh or registry push)
          if uses_registry
            if result[:push][:success]
              puts @pastel.green("Pushed to registry!")
            else
              puts @pastel.red("Push to registry failed!")
              exit 1
            end
          else
            if result[:pussh][:success]
              puts @pastel.green("Pussh complete!")
              result[:pussh][:results]&.each do |host, host_result|
                status = host_result[:success] ? @pastel.green('✓') : @pastel.red('✗')
                puts "  #{status} #{host}"
              end
            else
              puts @pastel.red("Pussh failed!")
              result[:pussh][:results]&.each do |host, host_result|
                status = host_result[:success] ? @pastel.green('✓') : @pastel.red('✗')
                puts "  #{status} #{host}"
                puts "      #{host_result[:error]}" unless host_result[:success]
              end
              exit 1
            end
          end
          puts ""
        end

        executor.deploy_all(image_tag: image_tag, dry_run: dry_run)

        puts ""
        puts @pastel.green("Deploy complete!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Build command - builds Docker image locally or on a build host
      # Usage: odysseus build [--config FILE] [--image TAG] [--push] [--context PATH] [--verbose]
      def build(options = {})
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image] || 'latest'
        push = options[:push] || false
        context_path = options[:context]
        verbose = options[:verbose] || false

        config = load_config(config_file)
        builder_config = config[:builder] || {}
        strategy = builder_config[:strategy] || :local

        puts @pastel.cyan("Odysseus Build")
        puts @pastel.blue("Service: #{config[:service]}")
        puts @pastel.blue("Image: #{config[:image]}:#{image_tag}")
        puts @pastel.blue("Strategy: #{strategy}")
        puts @pastel.blue("Build host: #{builder_config[:host]}") if builder_config[:host]
        puts @pastel.blue("Push: #{push ? 'yes' : 'no'}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)
        result = executor.build(image_tag: image_tag, push: push, context_path: context_path)

        if result[:success]
          puts ""
          puts @pastel.green("Build complete!")
          puts @pastel.blue("Image: #{result[:image]}")
          if result[:pushed]
            puts @pastel.blue("Pushed to registry: yes")
          end
        else
          puts ""
          puts @pastel.red("Build failed: #{result[:error]}")
          exit 1
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Pussh command - push image to hosts via SSH (no registry needed)
      # Usage: odysseus pussh [--config FILE] [--image TAG] [--build] [--verbose]
      def pussh(options = {})
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image] || 'latest'
        should_build = options[:build] || false
        verbose = options[:verbose] || false

        config = load_config(config_file)

        puts @pastel.cyan("Odysseus Pussh")
        puts @pastel.blue("Service: #{config[:service]}")
        puts @pastel.blue("Image: #{config[:image]}:#{image_tag}")
        puts @pastel.blue("Build first: #{should_build ? 'yes' : 'no'}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)

        if should_build
          result = executor.build_and_pussh(image_tag: image_tag)

          if result[:build][:success]
            puts @pastel.green("Build complete!")
          else
            puts @pastel.red("Build failed: #{result[:build][:error]}")
            exit 1
          end
        else
          result = executor.pussh(image_tag: image_tag)
        end

        pussh_result = should_build ? result[:pussh] : result

        if pussh_result[:success]
          puts ""
          puts @pastel.green("Pussh complete!")
          pussh_result[:results]&.each do |host, host_result|
            status = host_result[:success] ? @pastel.green('✓') : @pastel.red('✗')
            puts "  #{status} #{host}"
          end
        else
          puts ""
          puts @pastel.red("Pussh failed!")
          pussh_result[:results]&.each do |host, host_result|
            status = host_result[:success] ? @pastel.green('✓') : @pastel.red('✗')
            puts "  #{status} #{host}"
            puts "      #{host_result[:error]}" unless host_result[:success]
          end
          exit 1
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Status command - show full service status on a server
      # Usage: odysseus status <server> [--config FILE]
      def status(server, options = {})
        config_file = options[:config] || 'deploy.yml'

        config = load_config(config_file)
        service_name = config[:service]

        puts @pastel.cyan("Odysseus Status: #{service_name}")
        puts @pastel.blue("Server: #{server}")
        puts ""

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          caddy = Odysseus::Caddy::Client.new(ssh: ssh, docker: docker)

          # Web containers
          puts @pastel.cyan("Web:")
          web_containers = docker.list(service: service_name)
          if web_containers.empty?
            puts "  (no containers running)"
          else
            web_containers.each do |c|
              status_color = c['State'] == 'running' ? :green : :red
              health = c['Status'].include?('healthy') ? ' (healthy)' : ''
              puts "  #{@pastel.send(status_color, c['State'])} #{c['Names']}#{health}"
              puts "    Image: #{c['Image']}"
            end
          end

          # Show Caddy route for this service
          caddy_status = caddy.status
          if caddy_status[:running]
            svc_route = caddy_status[:services].find { |s| s[:service] == service_name }
            if svc_route
              puts "  Proxy: #{svc_route[:hosts].join(', ')}"
              puts "  Upstreams: #{svc_route[:upstreams].join(', ')}"
            end
          end

          puts ""

          # Job/worker containers (non-web roles)
          non_web_roles = config[:servers].keys.reject { |r| r == :web }
          if non_web_roles.any?
            puts @pastel.cyan("Jobs/Workers:")
            non_web_roles.each do |role|
              role_service = "#{service_name}-#{role}"
              containers = docker.list(service: role_service)
              if containers.empty?
                puts "  #{@pastel.yellow(role.to_s)}: #{@pastel.red('not running')}"
              else
                containers.each do |c|
                  status_color = c['State'] == 'running' ? :green : :red
                  puts "  #{@pastel.yellow(role.to_s)}: #{@pastel.send(status_color, c['State'])} #{c['Names']}"
                  puts "    Image: #{c['Image']}"
                end
              end
            end
            puts ""
          end

          # Accessories
          if config[:accessories]&.any?
            puts @pastel.cyan("Accessories:")
            config[:accessories].each do |name, acc_config|
              acc_service = "#{service_name}-#{name}"
              containers = docker.list(service: acc_service, all: true)
              running = containers.find { |c| c['State'] == 'running' }

              if running
                health = running['Status'].include?('healthy') ? ' (healthy)' : ''
                puts "  #{@pastel.yellow(name.to_s)}: #{@pastel.green('running')}#{health}"
                puts "    Image: #{acc_config[:image]}"
                puts "    Container: #{running['ID'][0..11]}"
              else
                puts "  #{@pastel.yellow(name.to_s)}: #{@pastel.red('stopped')}"
                puts "    Image: #{acc_config[:image]}"
              end
            end
            puts ""
          end

          # TLS status for this service's domains
          if config[:proxy][:hosts]&.any?
            puts @pastel.cyan("TLS:")
            if caddy_status[:running] && caddy_status[:tls][:enabled]
              service_hosts = config[:proxy][:hosts]
              relevant_policy = caddy_status[:tls][:policies].find do |p|
                (p[:subjects] & service_hosts).any?
              end
              if relevant_policy
                puts "  Domains: #{(relevant_policy[:subjects] & service_hosts).join(', ')}"
                puts "  Issuer: #{relevant_policy[:issuer]}"
                puts "  Email: #{relevant_policy[:email] || '(not set)'}"
              else
                puts "  (not configured for this service)"
              end
            else
              puts "  (Caddy not running or TLS not configured)"
            end
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Containers command - list running containers for a service
      # Usage: odysseus containers <server> [--config FILE] [--service NAME]
      def containers(server, options = {})
        config_file = options[:config] || 'deploy.yml'

        puts @pastel.cyan("Odysseus Containers")
        puts @pastel.blue("Server: #{server}")
        puts ""

        config = load_config(config_file)
        service_name = options[:service] || config[:service]
        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            puts "No containers found for service: #{service_name}"
          else
            puts @pastel.cyan("Containers for #{service_name}:")
            containers.each do |c|
              status_color = c['State'] == 'running' ? :green : :red
              puts "  #{c['ID'][0..11]} #{@pastel.send(status_color, c['State'])} #{c['Names']} (#{c['Image']})"
              puts "    Created: #{c['CreatedAt']}"
              puts "    Status: #{c['Status']}"
            end
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Validate command
      # Usage: odysseus validate [--config FILE]
      def validate(options = {})
        config_file = options[:config] || 'deploy.yml'

        puts @pastel.cyan("Validating #{config_file}...")

        config = load_config(config_file)

        puts @pastel.green("Configuration is valid!")
        puts ""
        puts "Service: #{config[:service]}"
        puts "Image: #{config[:image]}"
        puts "Servers: #{config[:servers].keys.join(', ')}"
        puts "Proxy hosts: #{config[:proxy][:hosts]&.join(', ')}"
        if config[:accessories]&.any?
          puts "Accessories: #{config[:accessories].keys.join(', ')}"
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Validation failed: #{e.message}")
        exit 1
      end

      # Accessory boot command
      # Usage: odysseus accessory boot <server> <name> [--config FILE]
      def accessory_boot(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = options[:name]

        unless name
          puts @pastel.red("Error: accessory name required (--name)")
          exit 1
        end

        puts @pastel.cyan("Odysseus Accessory Boot")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Accessory: #{name}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        executor.deploy_accessory(server: server, name: name)

        puts @pastel.green("Accessory #{name} deployed!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Boot all accessories
      # Usage: odysseus accessory boot-all <server> [--config FILE]
      def accessory_boot_all(server, options = {})
        config_file = options[:config] || 'deploy.yml'

        puts @pastel.cyan("Odysseus Accessory Boot All")
        puts @pastel.blue("Server: #{server}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        executor.boot_accessories(server: server)

        puts @pastel.green("All accessories deployed!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Accessory remove command
      # Usage: odysseus accessory remove <server> <name> [--config FILE]
      def accessory_remove(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = options[:name]

        unless name
          puts @pastel.red("Error: accessory name required (--name)")
          exit 1
        end

        puts @pastel.cyan("Odysseus Accessory Remove")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Accessory: #{name}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        executor.remove_accessory(server: server, name: name)

        puts @pastel.green("Accessory #{name} removed!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Accessory restart command
      # Usage: odysseus accessory restart <server> <name> [--config FILE]
      def accessory_restart(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = options[:name]

        unless name
          puts @pastel.red("Error: accessory name required (--name)")
          exit 1
        end

        puts @pastel.cyan("Odysseus Accessory Restart")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Accessory: #{name}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        executor.restart_accessory(server: server, name: name)

        puts @pastel.green("Accessory #{name} restarted!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Accessory upgrade command - upgrade to new image version (preserves volumes)
      # Usage: odysseus accessory upgrade <server> <name> [--config FILE]
      def accessory_upgrade(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = options[:name]

        unless name
          puts @pastel.red("Error: accessory name required (--name)")
          exit 1
        end

        puts @pastel.cyan("Odysseus Accessory Upgrade")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Accessory: #{name}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        executor.upgrade_accessory(server: server, name: name)

        puts @pastel.green("Accessory #{name} upgraded!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Accessory status command
      # Usage: odysseus accessory status <server> [--config FILE]
      def accessory_status(server, options = {})
        config_file = options[:config] || 'deploy.yml'

        puts @pastel.cyan("Odysseus Accessory Status")
        puts @pastel.blue("Server: #{server}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        statuses = executor.accessory_status(server: server)

        if statuses.empty?
          puts "No accessories configured"
        else
          statuses.each do |status|
            status_text = status[:running] ? @pastel.green('running') : @pastel.red('stopped')
            puts "  #{@pastel.yellow(status[:name].to_s)}: #{status_text}"
            puts "    Image: #{status[:image]}"
            puts "    Container: #{status[:container_id] ? status[:container_id][0..11] : '(none)'}"
            puts "    Has proxy: #{status[:has_proxy] ? 'yes' : 'no'}"
          end
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Logs command - tail logs for a service
      # Usage: odysseus logs <server> [--config FILE] [--role ROLE] [--follow] [--lines N] [--since TIME]
      def logs(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        role = (options[:role] || 'web').to_sym
        follow = options[:follow] || false
        lines = options[:lines] || 100
        since = options[:since]

        config = load_config(config_file)
        service_name = role == :web ? config[:service] : "#{config[:service]}-#{role}"

        puts @pastel.cyan("Odysseus Logs: #{service_name}")
        puts @pastel.blue("Server: #{server}")
        puts ""

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            puts @pastel.yellow("No running containers found for #{service_name}")
            return
          end

          container = containers.first
          container_id = container['ID']

          if follow
            puts @pastel.dim("Following logs (Ctrl+C to stop)...")
            puts ""
            docker.logs(container_id, follow: true, tail: lines, since: since) do |line|
              print line
            end
          else
            output = docker.logs(container_id, tail: lines, since: since)
            puts output
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Accessory logs command
      # Usage: odysseus accessory logs <server> --name NAME [--config FILE] [--follow] [--lines N] [--since TIME]
      def accessory_logs(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = options[:name]
        follow = options[:follow] || false
        lines = options[:lines] || 100
        since = options[:since]

        unless name
          puts @pastel.red("Error: accessory name required (--name)")
          exit 1
        end

        config = load_config(config_file)
        service_name = "#{config[:service]}-#{name}"

        puts @pastel.cyan("Odysseus Accessory Logs: #{service_name}")
        puts @pastel.blue("Server: #{server}")
        puts ""

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            puts @pastel.yellow("No running containers found for #{service_name}")
            return
          end

          container = containers.first
          container_id = container['ID']

          if follow
            puts @pastel.dim("Following logs (Ctrl+C to stop)...")
            puts ""
            docker.logs(container_id, follow: true, tail: lines, since: since) do |line|
              print line
            end
          else
            output = docker.logs(container_id, tail: lines, since: since)
            puts output
          end
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # App exec command - run a command in a new container using the app image
      # Usage: odysseus app exec <server> <command> [--config FILE]
      def app_exec(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        command = options[:command]

        unless command
          puts @pastel.red("Error: command required")
          exit 1
        end

        config = load_config(config_file)
        image = "#{config[:image]}:latest"

        puts @pastel.cyan("Odysseus App Exec")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Image: #{image}")
        puts @pastel.blue("Command: #{command}")
        puts ""

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)

          # Build environment from config
          env = {}
          config[:env][:clear]&.each { |k, v| env[k.to_s] = v.to_s }

          output = docker.run_once(
            image: image,
            command: command,
            options: {
              env: env,
              network: 'odysseus'
            }
          )

          puts output
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # App shell command - open an interactive shell in a temporary container
      # Usage: odysseus app shell <server> [--config FILE]
      def app_shell(server, options = {})
        config_file = options[:config] || 'deploy.yml'

        config = load_config(config_file)
        image = "#{config[:image]}:latest"

        puts @pastel.cyan("Odysseus App Shell")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Image: #{image}")
        puts ""

        ssh_keys = config[:ssh][:keys].map { |k| "-i #{File.expand_path(k)}" }.join(' ')
        env_flags = config[:env][:clear]&.map { |k, v| "-e #{k}=#{v}" }&.join(' ') || ''

        system("ssh #{ssh_keys} -t #{config[:ssh][:user]}@#{server} 'docker run -it --rm --network odysseus #{env_flags} #{image} /bin/sh'")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # App console command - run an interactive console in a new container
      # Usage: odysseus app console <server> [--config FILE] [--cmd COMMAND]
      def app_console(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        console_cmd = options[:cmd] || '/bin/sh'

        config = load_config(config_file)
        image = "#{config[:image]}:latest"

        puts @pastel.cyan("Odysseus App Console")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Image: #{image}")
        puts @pastel.blue("Console: #{console_cmd}")
        puts ""
        puts @pastel.dim("Note: This runs 'docker run -it' via SSH. For full interactivity, use:")
        puts @pastel.dim("  ssh #{config[:ssh][:user]}@#{server} -t 'docker run -it --rm --network odysseus #{image} #{console_cmd}'")
        puts ""

        # For truly interactive sessions, we need to exec through SSH directly
        # The CLI can't easily support full TTY passthrough
        ssh_keys = config[:ssh][:keys].map { |k| "-i #{File.expand_path(k)}" }.join(' ')
        env_flags = config[:env][:clear]&.map { |k, v| "-e #{k}=#{v}" }&.join(' ') || ''

        system("ssh #{ssh_keys} -t #{config[:ssh][:user]}@#{server} 'docker run -it --rm --network odysseus #{env_flags} #{image} #{console_cmd}'")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Accessory shell command - open an interactive shell in a running accessory container
      # Usage: odysseus accessory shell <server> --name NAME [--config FILE]
      def accessory_shell(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = options[:name]

        unless name
          puts @pastel.red("Error: accessory name required (--name)")
          exit 1
        end

        config = load_config(config_file)
        service_name = "#{config[:service]}-#{name}"

        puts @pastel.cyan("Odysseus Accessory Shell")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Accessory: #{name}")
        puts ""

        # Get container ID first
        ssh = connect_to_server(server, config)
        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            puts @pastel.red("No running containers found for #{service_name}")
            exit 1
          end

          container_id = containers.first['ID']
        ensure
          ssh.close
        end

        # Now exec with SSH passthrough for TTY
        ssh_keys = config[:ssh][:keys].map { |k| "-i #{File.expand_path(k)}" }.join(' ')
        system("ssh #{ssh_keys} -t #{config[:ssh][:user]}@#{server} 'docker exec -it #{container_id} /bin/sh'")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Cleanup command - remove containers for this service
      # Usage: odysseus cleanup <server> [--config FILE] [--prune-images]
      def cleanup(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        prune_images = options[:all] || false

        config = load_config(config_file)
        service_name = config[:service]

        puts @pastel.cyan("Odysseus Cleanup: #{service_name}")
        puts @pastel.blue("Server: #{server}")
        puts ""

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          caddy = Odysseus::Caddy::Client.new(ssh: ssh, docker: docker)

          # Show current disk usage
          puts @pastel.cyan("Current disk usage:")
          puts docker.disk_usage
          puts ""

          # Collect all service names for this deploy.yml
          service_names = [service_name]
          config[:servers].keys.reject { |r| r == :web }.each do |role|
            service_names << "#{service_name}-#{role}"
          end
          config[:accessories]&.each_key do |name|
            service_names << "#{service_name}-#{name}"
          end

          puts @pastel.yellow("Removing containers for #{service_name}...")

          total_removed = 0

          # Remove all containers for each service (not just old ones)
          service_names.each do |svc|
            containers = docker.list(service: svc, all: true)
            containers.each do |c|
              docker.stop(c['ID'], timeout: 10) if c['State'] == 'running'
              docker.remove(c['ID'], force: true)
              total_removed += 1
            end
          end

          puts "  Removed #{total_removed} container(s)"

          # Remove routes from Caddy for this service
          puts ""
          puts @pastel.yellow("Removing Caddy routes for #{service_name}...")

          if caddy.running?
            # Remove web service route
            caddy.remove_upstream(service: service_name, upstream: nil) rescue nil

            # Remove accessory routes
            config[:accessories]&.each do |name, acc_config|
              if acc_config[:proxy]
                acc_service = "#{service_name}-#{name}"
                caddy.remove_upstream(service: acc_service, upstream: nil) rescue nil
              end
            end

            # Check if Caddy still has other services
            remaining_services = caddy.list_services
            remaining_services.reject! { |s| s[:service] == 'unknown' || s[:service].empty? }

            if remaining_services.empty?
              puts @pastel.yellow("No other services using Caddy, stopping Caddy...")
              docker.stop('odysseus-caddy', timeout: 10) rescue nil
              docker.remove('odysseus-caddy', force: true) rescue nil
              puts "  Caddy removed"
            else
              puts @pastel.dim("  Keeping Caddy (#{remaining_services.size} other service(s) configured)")
            end
          end

          # Optionally prune dangling images
          if prune_images
            puts ""
            puts @pastel.yellow("Pruning dangling images...")
            results = docker.prune(containers: false, images: true, volumes: false, networks: false)
            puts results[:images]
          end

          puts ""
          puts @pastel.cyan("Disk usage after cleanup:")
          puts docker.disk_usage
        ensure
          ssh.close
        end

        puts ""
        puts @pastel.green("Cleanup complete!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Accessory exec command - run a command in a running accessory container
      # Usage: odysseus accessory exec <server> --name NAME <command> [--config FILE]
      def accessory_exec(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = options[:name]
        command = options[:command]

        unless name
          puts @pastel.red("Error: accessory name required (--name)")
          exit 1
        end

        unless command
          puts @pastel.red("Error: command required")
          exit 1
        end

        config = load_config(config_file)
        service_name = "#{config[:service]}-#{name}"

        puts @pastel.cyan("Odysseus Accessory Exec")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Accessory: #{name}")
        puts @pastel.blue("Command: #{command}")
        puts ""

        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            puts @pastel.red("No running containers found for #{service_name}")
            exit 1
          end

          container_id = containers.first['ID']
          output = docker.exec(container_id, command)
          puts output
        ensure
          ssh.close
        end
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Generate a new master key for encrypting secrets
      # Usage: odysseus secrets generate-key
      def secrets_generate_key(_options = {})
        puts @pastel.cyan("Odysseus Secrets: Generate Key")
        puts ""

        key = Odysseus::Secrets::EncryptedFile.generate_key

        puts @pastel.green("Generated master key:")
        puts ""
        puts "  #{key}"
        puts ""
        puts @pastel.yellow("Save this key securely!")
        puts @pastel.dim("Set it as ODYSSEUS_MASTER_KEY environment variable for encrypt/decrypt operations.")
      end

      # Encrypt a secrets file
      # Usage: odysseus secrets encrypt --input secrets.yml --file secrets.yml.enc
      def secrets_encrypt(options = {})
        input_file = options[:input]
        output_file = options[:file] || 'secrets.yml.enc'

        unless input_file
          puts @pastel.red("Error: input file required (--input)")
          exit 1
        end

        unless File.exist?(input_file)
          puts @pastel.red("Error: input file not found: #{input_file}")
          exit 1
        end

        puts @pastel.cyan("Odysseus Secrets: Encrypt")
        puts @pastel.blue("Input: #{input_file}")
        puts @pastel.blue("Output: #{output_file}")
        puts ""

        secrets = YAML.load_file(input_file)
        encrypted_file = Odysseus::Secrets::EncryptedFile.new(output_file)
        encrypted_file.write(secrets)

        puts @pastel.green("Secrets encrypted to #{output_file}")
        puts ""
        puts @pastel.dim("You can now delete the plaintext file: rm #{input_file}")
        puts @pastel.dim("Add to deploy.yml: secrets_file: #{output_file}")
      rescue Odysseus::Secrets::EncryptedFile::MissingKeyError => e
        puts @pastel.red("Error: #{e.message}")
        puts @pastel.dim("Generate a key with: odysseus secrets generate-key")
        exit 1
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Decrypt and display secrets
      # Usage: odysseus secrets decrypt --file secrets.yml.enc
      def secrets_decrypt(options = {})
        secrets_file = options[:file] || 'secrets.yml.enc'

        unless File.exist?(secrets_file)
          puts @pastel.red("Error: secrets file not found: #{secrets_file}")
          exit 1
        end

        puts @pastel.cyan("Odysseus Secrets: Decrypt")
        puts @pastel.blue("File: #{secrets_file}")
        puts ""

        encrypted_file = Odysseus::Secrets::EncryptedFile.new(secrets_file)
        secrets = encrypted_file.read

        puts @pastel.yellow("Decrypted secrets:")
        puts ""
        secrets.each do |key, value|
          # Mask values for display
          masked_value = value.to_s.length > 4 ? "#{value[0..3]}#{'*' * (value.length - 4)}" : '****'
          puts "  #{key}: #{masked_value}"
        end
        puts ""
        puts @pastel.dim("(Values are masked for security)")
      rescue Odysseus::Secrets::EncryptedFile::MissingKeyError => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      rescue Odysseus::Secrets::EncryptedFile::DecryptionError => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Edit encrypted secrets using $EDITOR
      # Usage: odysseus secrets edit --file secrets.yml.enc
      def secrets_edit(options = {})
        secrets_file = options[:file] || 'secrets.yml.enc'
        editor = ENV['EDITOR'] || 'vi'

        puts @pastel.cyan("Odysseus Secrets: Edit")
        puts @pastel.blue("File: #{secrets_file}")
        puts @pastel.blue("Editor: #{editor}")
        puts ""

        encrypted_file = Odysseus::Secrets::EncryptedFile.new(secrets_file)

        # Load existing secrets or start with empty hash
        secrets = if encrypted_file.exists?
          encrypted_file.read
        else
          {}
        end

        # Write to temp file for editing
        temp_file = Tempfile.new(['secrets', '.yml'])
        begin
          temp_file.write(YAML.dump(secrets))
          temp_file.close

          # Open in editor
          system("#{editor} #{temp_file.path}")

          # Read back and encrypt
          edited_secrets = YAML.load_file(temp_file.path)
          encrypted_file.write(edited_secrets)

          puts @pastel.green("Secrets updated and encrypted to #{secrets_file}")
        ensure
          temp_file.unlink
        end
      rescue Odysseus::Secrets::EncryptedFile::MissingKeyError => e
        puts @pastel.red("Error: #{e.message}")
        puts @pastel.dim("Generate a key with: odysseus secrets generate-key")
        exit 1
      rescue Odysseus::Secrets::EncryptedFile::DecryptionError => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      private

      def load_config(config_file)
        parser = Odysseus::Config::Parser.new(config_file)
        parser.parse
      end

      def connect_to_server(server, config)
        Odysseus::Deployer::SSH.new(
          host: server,
          user: config[:ssh][:user],
          keys: config[:ssh][:keys],
          use_tailscale: true
        )
      end
    end
  end
end
