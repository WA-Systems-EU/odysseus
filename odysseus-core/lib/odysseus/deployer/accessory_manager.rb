# lib/odysseus/deployer/accessory_manager.rb

module Odysseus
  module Deployer
    # Accessory verbs (deploy/remove/restart/upgrade/status/boot), split out of
    # Executor because they are a distinct concern from deploying and rolling
    # back the service itself, sharing only config and a way to open a
    # connection.
    class AccessoryManager
      # @param config [Hash] parsed deploy.yml
      # @param secrets_loader [Odysseus::Secrets::Loader]
      # @param connector [#call] returns an open SSH connection for a host
      def initialize(config:, secrets_loader:, connector:)
        @config = config
        @secrets_loader = secrets_loader
        @connector = connector
      end

      # @param name [Symbol] accessory name
      # @return [Hash] results keyed by host
      def deploy(name:)
        run_action(name, 'Deploying', 'to') { |orchestrator| orchestrator.deploy(name: name.to_sym) }
      end

      # @param name [Symbol] accessory name
      # @return [Hash] results keyed by host
      def remove(name:)
        run_action(name, 'Removing', 'from') { |orchestrator| orchestrator.remove(name: name.to_sym) }
      end

      # @param name [Symbol] accessory name
      # @return [Hash] results keyed by host
      def restart(name:)
        run_action(name, 'Restarting', 'on') { |orchestrator| orchestrator.restart(name: name.to_sym) }
      end

      # @param name [Symbol] accessory name
      # @return [Hash] results keyed by host
      def upgrade(name:)
        run_action(name, 'Upgrading', 'on') { |orchestrator| orchestrator.upgrade(name: name.to_sym) }
      end

      # @return [Array<Hash>] status for every accessory on every configured host
      def status
        return [] unless @config[:accessories]&.any?

        all_statuses = []
        @config[:accessories].each do |name, acc_config|
          (acc_config[:hosts] || []).each do |host|
            all_statuses << status_on(host, name)
          end
        end
        all_statuses
      end

      # @return [Hash] boot results keyed by accessory name
      def boot_all
        return {} unless @config[:accessories]&.any?

        results = {}
        @config[:accessories].each_key do |name|
          puts "\n=== Booting accessory: #{name} ==="
          results[name] = deploy(name: name)
        end
        results
      end

      private

      def status_on(host, name)
        ssh = @connector.call(host)

        begin
          orchestrator = build_orchestrator(ssh)
          acc_status = orchestrator.get_status(name: name.to_sym)
          acc_status[:host] = host
          acc_status
        ensure
          ssh.close
        end
      end

      def get_accessory_config(name)
        name_sym = name.to_sym
        acc_config = @config[:accessories]&.[](name_sym)
        raise Odysseus::ConfigError, "Accessory '#{name}' not found in config" unless acc_config

        acc_config
      end

      # Shared plumbing for the verbs above: resolve hosts, connect, build the
      # orchestrator, run the block, and always close the connection.
      def run_action(name, verb, preposition)
        acc_config = get_accessory_config(name)
        hosts = acc_config[:hosts] || []

        raise Odysseus::ConfigError, "No hosts configured for accessory #{name}" if hosts.empty?

        results = {}
        hosts.each do |host|
          puts "#{verb} accessory #{name} #{preposition} #{host}..."
          ssh = @connector.call(host)

          begin
            results[host] = yield(build_orchestrator(ssh))
          ensure
            ssh.close
          end
        end
        results
      end

      def build_orchestrator(ssh)
        Odysseus::Orchestrator::AccessoryDeploy.new(ssh: ssh, config: @config, secrets_loader: @secrets_loader)
      end
    end
  end
end
