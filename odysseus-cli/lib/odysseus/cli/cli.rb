# odysseus-cli/lib/odysseus/cli/cli.rb

require 'odysseus'
require 'odysseus/deployer/executor'
require 'odysseus/config/parser'
require 'odysseus/deployer/ssh'
require 'odysseus/docker/client'
require 'odysseus/caddy/client'
require 'pastel'

module Odysseus
  module CLI
    class CLI
      def initialize
        @pastel = Pastel.new
      end

      # Deploy command
      # Usage: odysseus deploy <server> [--config FILE] [--image TAG] [--dry-run]
      def deploy(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image] || 'latest'
        dry_run = options[:'dry-run'] || false

        puts @pastel.cyan("Odysseus Deploy")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Config: #{config_file}")
        puts @pastel.blue("Image tag: #{image_tag}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        executor.deploy(server: server, image_tag: image_tag, dry_run: dry_run)

        puts @pastel.green("Deploy complete!")
      rescue Odysseus::Error => e
        puts @pastel.red("Error: #{e.message}")
        exit 1
      end

      # Status command - show Caddy proxy status on a server
      # Usage: odysseus status <server> [--config FILE]
      def status(server, options = {})
        config_file = options[:config] || 'deploy.yml'

        puts @pastel.cyan("Odysseus Status")
        puts @pastel.blue("Server: #{server}")
        puts ""

        config = load_config(config_file)
        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          caddy = Odysseus::Caddy::Client.new(ssh: ssh, docker: docker)

          status = caddy.status

          # Caddy status
          if status[:running]
            puts @pastel.green("Caddy: running")
            puts "Listen: #{status[:listen].join(', ')}"
          else
            puts @pastel.red("Caddy: not running")
            return
          end

          puts ""

          # Services
          puts @pastel.cyan("Services:")
          if status[:services].empty?
            puts "  (no services configured)"
          else
            status[:services].each do |svc|
              puts "  #{@pastel.yellow(svc[:service])}"
              puts "    Hosts: #{svc[:hosts].join(', ')}"
              puts "    Upstreams: #{svc[:upstreams].join(', ')}"
              puts "    Healthcheck: #{svc[:has_healthcheck] ? 'yes' : 'no'}"
            end
          end

          puts ""

          # TLS
          puts @pastel.cyan("TLS:")
          if status[:tls][:enabled]
            status[:tls][:policies].each do |policy|
              puts "  Domains: #{policy[:subjects].join(', ')}"
              puts "  Issuer: #{policy[:issuer]}"
              puts "  Email: #{policy[:email] || '(not set)'}"
            end
          else
            puts "  (not configured)"
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
      rescue Odysseus::Error => e
        puts @pastel.red("Validation failed: #{e.message}")
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
