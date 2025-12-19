# lib/odysseus/deployer/executor.rb

require 'odysseus/config/parser'
require 'odysseus/generators/docker_compose'
require 'odysseus/generators/caddy'
require 'odysseus/deployer/ssh'

module Odysseus
  module Deployer
    class Executor
      # @param config_path [String] path to deploy.yml
      def initialize(config_path)
        parser = Odysseus::Config::Parser.new(config_path)
        @config = parser.parse
      end

      # Execute full deploy
      # @param server [String] target server (hostname/IP)
      # @param image_tag [String] docker image tag (e.g., "myapp:v1.2.3")
      # @param dry_run [Boolean] if true, don't actually deploy
      def deploy(server:, image_tag:, dry_run: false)
        puts "Preparing deploy for #{server}..." unless dry_run

        # Generate files
        compose_content = generate_compose_file
        caddy_content = generate_caddy_file

        puts "Generated docker-compose.yml"
        puts "Generated Caddyfile"

        return if dry_run

        # Connect to server
        ssh = connect_to_server(server)

        begin
          # Upload files
          ssh.execute('mkdir -p /tmp/odysseus')
          ssh.upload_string(compose_content, '/tmp/odysseus/docker-compose.yml')
          ssh.upload_string(caddy_content, '/tmp/odysseus/Caddyfile')

          # Deploy
          ssh.execute('cd /tmp/odysseus && docker-compose pull')
          ssh.execute('cd /tmp/odysseus && docker-compose down')
          ssh.execute('cd /tmp/odysseus && docker-compose up -d')

          # Reload Caddy
          ssh.execute('docker exec caddy caddy reload --config /etc/caddy/Caddyfile')

          puts "Deploy complete!"
        ensure
          ssh.close
        end
      end

      private

      def generate_compose_file
        Odysseus::Generators::DockerCompose.new(@config).generate
      end

      def generate_caddy_file
        Odysseus::Generators::Caddy.new(@config).generate
      end

      def connect_to_server(server)
        Odysseus::Deployer::SSH.new(
          host: server,
          user: @config[:ssh][:user],
          keys: @config[:ssh][:keys],
          use_tailscale: true
        )
      end
    end
  end
end
