# lib/odysseus/deployer/executor.rb

require 'odysseus/config/parser'
require 'odysseus/deployer/ssh'
require 'odysseus/docker/client'
require 'odysseus/caddy/client'
require 'odysseus/secrets/loader'
require 'odysseus/orchestrator/web_deploy'
require 'odysseus/orchestrator/job_deploy'
require 'odysseus/orchestrator/accessory_deploy'

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

      # Deploy all roles to their configured hosts
      # @param image_tag [String] docker image tag
      # @param dry_run [Boolean] if true, don't actually deploy
      def deploy_all(image_tag:, dry_run: false)
        results = {}

        @config[:servers].each do |role, role_config|
          hosts = role_config[:hosts] || []
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
      def deploy_role(host:, image_tag:, dry_run: false, role:)
        if dry_run
          puts "Dry run - would deploy #{@config[:image]}:#{image_tag} to #{host}"
          puts "Service: #{@config[:service]}"
          puts "Role: #{role}"
          if role == WEB_ROLE
            puts "Proxy hosts: #{@config[:proxy][:hosts].join(', ')}"
          end
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
        logger = build_logger
        if role == WEB_ROLE
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
    end
  end
end
