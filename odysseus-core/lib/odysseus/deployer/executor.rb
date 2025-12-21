# lib/odysseus/deployer/executor.rb

require 'odysseus/config/parser'
require 'odysseus/deployer/ssh'
require 'odysseus/docker/client'
require 'odysseus/caddy/client'
require 'odysseus/orchestrator/web_deploy'
require 'odysseus/orchestrator/job_deploy'
require 'odysseus/orchestrator/accessory_deploy'

module Odysseus
  module Deployer
    class Executor
      WEB_ROLE = :web

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
          puts "Role: #{role}"
          if role == WEB_ROLE
            puts "Hosts: #{@config[:proxy][:hosts].join(', ')}"
          end
          return { success: true, dry_run: true }
        end

        ssh = connect_to_server(server)

        begin
          orchestrator = build_orchestrator(ssh, role)
          result = orchestrator.deploy(image_tag: image_tag, role: role)
          puts "Deploy complete!"
          result
        ensure
          ssh.close
        end
      end

      # Deploy all roles defined in config
      # @param server [String] target server
      # @param image_tag [String] docker image tag
      # @param dry_run [Boolean] if true, don't actually deploy
      def deploy_all(server:, image_tag:, dry_run: false)
        results = {}

        @config[:servers].each_key do |role|
          puts "\n=== Deploying #{role} ==="
          results[role] = deploy(server: server, image_tag: image_tag, dry_run: dry_run, role: role)
        end

        results
      end

      # Deploy an accessory
      # @param server [String] target server
      # @param name [Symbol] accessory name
      def deploy_accessory(server:, name:)
        puts "Deploying accessory #{name} to #{server}..."

        ssh = connect_to_server(server)

        begin
          orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config)
          orchestrator.deploy(name: name.to_sym)
        ensure
          ssh.close
        end
      end

      # Remove an accessory
      # @param server [String] target server
      # @param name [Symbol] accessory name
      def remove_accessory(server:, name:)
        puts "Removing accessory #{name} from #{server}..."

        ssh = connect_to_server(server)

        begin
          orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config)
          orchestrator.remove(name: name.to_sym)
        ensure
          ssh.close
        end
      end

      # Restart an accessory
      # @param server [String] target server
      # @param name [Symbol] accessory name
      def restart_accessory(server:, name:)
        puts "Restarting accessory #{name} on #{server}..."

        ssh = connect_to_server(server)

        begin
          orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config)
          orchestrator.restart(name: name.to_sym)
        ensure
          ssh.close
        end
      end

      # Upgrade an accessory to a new image version (preserves volumes)
      # @param server [String] target server
      # @param name [Symbol] accessory name
      def upgrade_accessory(server:, name:)
        puts "Upgrading accessory #{name} on #{server}..."

        ssh = connect_to_server(server)

        begin
          orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config)
          orchestrator.upgrade(name: name.to_sym)
        ensure
          ssh.close
        end
      end

      # List accessory status
      # @param server [String] target server
      def accessory_status(server:)
        ssh = connect_to_server(server)

        begin
          orchestrator = Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config)
          orchestrator.list_status
        ensure
          ssh.close
        end
      end

      # Boot all accessories
      # @param server [String] target server
      def boot_accessories(server:)
        return [] unless @config[:accessories]&.any?

        results = {}
        @config[:accessories].each_key do |name|
          puts "\n=== Booting accessory: #{name} ==="
          results[name] = deploy_accessory(server: server, name: name)
        end
        results
      end

      private

      def build_orchestrator(ssh, role)
        if role == WEB_ROLE
          Odysseus::Orchestrator::WebDeploy.new(ssh: ssh, config: @config)
        else
          Odysseus::Orchestrator::JobDeploy.new(ssh: ssh, config: @config)
        end
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
