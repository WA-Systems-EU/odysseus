# lib/odysseus/deployer/dependency_manager.rb

module Odysseus
  module Deployer
    # Dependency verbs (deploy/remove/restart/upgrade/status/boot), split out of
    # Executor because they are a distinct concern from deploying and rolling
    # back the service itself, sharing only config and a way to open a
    # connection.
    class DependencyManager
      # @param config [Hash] parsed deploy.yml
      # @param secrets_loader [Odysseus::Secrets::Loader]
      # @param connector [#call] returns an open SSH connection for a host
      def initialize(config:, secrets_loader:, connector:)
        @config = config
        @secrets_loader = secrets_loader
        @connector = connector
      end

      # @param name [Symbol] dependency name
      # @return [Hash] results keyed by host
      def deploy(name:)
        run_action(name, 'Deploying', 'to') { |orchestrator| orchestrator.deploy(name: name.to_sym) }
      end

      # @param name [Symbol] dependency name
      # @return [Hash] results keyed by host
      def remove(name:)
        run_action(name, 'Removing', 'from') { |orchestrator| orchestrator.remove(name: name.to_sym) }
      end

      # @param name [Symbol] dependency name
      # @return [Hash] results keyed by host
      def restart(name:)
        run_action(name, 'Restarting', 'on') { |orchestrator| orchestrator.restart(name: name.to_sym) }
      end

      # @param name [Symbol] dependency name
      # @return [Hash] results keyed by host
      def upgrade(name:)
        run_action(name, 'Upgrading', 'on') { |orchestrator| orchestrator.upgrade(name: name.to_sym) }
      end

      # @return [Array<Hash>] status for every dependency on every configured host
      def status
        return [] unless @config[:dependencies]&.any?

        all_statuses = []
        @config[:dependencies].each do |name, dep_config|
          (dep_config[:hosts] || []).each do |host|
            dep_status = status_on(host, name)
            all_statuses << dep_status if dep_status
          end
        end
        all_statuses
      end

      # @return [Hash] boot results keyed by dependency name
      def boot_all
        return {} unless @config[:dependencies]&.any?

        results = {}
        @config[:dependencies].each_key do |name|
          puts "\n=== Booting dependency: #{name} ==="
          results[name] = deploy(name: name)
        end
        results
      end

      private

      # DependencyDeploy exposes #list_status (no args, every dependency on the
      # host) rather than a per-dependency lookup, so pick out the one entry
      # this host/dependency pair needs; nil when it is somehow absent. One
      # #list_status call per dependency/host pair where one per host would
      # do; accepted for now rather than restructuring the dependency-then-host
      # result order.
      def status_on(host, name)
        ssh = @connector.call(host)

        begin
          dep_status = build_orchestrator(ssh).list_status.find { |entry| entry[:name] == name }
          dep_status&.merge(host: host)
        ensure
          ssh.close
        end
      end

      def dependency_config(name)
        config = @config[:dependencies]&.[](name.to_sym)
        raise Odysseus::ConfigError, "Dependency '#{name}' not found in config" unless config

        config
      end

      # Shared plumbing for the verbs above: resolve hosts, connect, build the
      # orchestrator, run the block, and always close the connection.
      def run_action(name, verb, preposition)
        hosts = dependency_config(name)[:hosts] || []

        raise Odysseus::ConfigError, "No hosts configured for dependency #{name}" if hosts.empty?

        results = {}
        hosts.each do |host|
          puts "#{verb} dependency #{name} #{preposition} #{host}..."
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
        Odysseus::Orchestrator::DependencyDeploy.new(ssh: ssh, config: @config, secrets_loader: @secrets_loader)
      end
    end
  end
end
