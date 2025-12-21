# lib/odysseus/deployer/executor.rb

require 'odysseus/config/parser'
require 'odysseus/deployer/ssh'
require 'odysseus/docker/client'
require 'odysseus/caddy/client'
require 'odysseus/orchestrator/web_deploy'

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
      # @param image_tag [String] docker image tag (e.g., "v1.2.3")
      # @param dry_run [Boolean] if true, don't actually deploy
      # @param role [Symbol] server role (default: :web)
      def deploy(server:, image_tag:, dry_run: false, role: :web)
        puts "Preparing deploy for #{server}..."

        if dry_run
          puts "Dry run - would deploy #{@config[:image]}:#{image_tag} to #{server}"
          puts "Service: #{@config[:service]}"
          puts "Hosts: #{@config[:proxy][:hosts].join(', ')}"
          return { success: true, dry_run: true }
        end

        ssh = connect_to_server(server)

        begin
          orchestrator = Odysseus::Orchestrator::WebDeploy.new(
            ssh: ssh,
            config: @config
          )

          result = orchestrator.deploy(image_tag: image_tag, role: role)
          puts "Deploy complete!"
          result
        ensure
          ssh.close
        end
      end

      # Generate and print docker run command (for debugging)
      # @param image_tag [String] image tag
      # @param role [Symbol] server role
      def show_docker_command(image_tag:, role: :web)
        docker = Odysseus::Docker::Client.new(nil)
        # This would need refactoring to work without SSH
        puts "Docker command generation not yet implemented for dry-run"
      end

      private

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
