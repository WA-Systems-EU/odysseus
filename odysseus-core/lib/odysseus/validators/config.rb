# lib/odysseus/validators/config.rb

module Odysseus
  module Validators
    class Config
      REQUIRED_KEYS = ['service', 'image', 'servers'].freeze

      def initialize(config)
        @config = config
      end

      # Validate config structure
      # @raise [Odysseus::ConfigValidationError] if invalid
      def validate!
        validate_required_keys!
        validate_servers!
        validate_proxy! if @config['proxy']
        validate_env! if @config['env']
        validate_ssh! if @config['ssh']
      end

      private

      def validate_required_keys!
        missing = REQUIRED_KEYS.select { |key| @config[key].nil? }
        return if missing.empty?

        raise Odysseus::ConfigValidationError,
              "Missing required keys: #{missing.join(', ')}"
      end

      def validate_servers!
        servers = @config['servers']
        raise Odysseus::ConfigValidationError,
              "servers must be a hash" unless servers.is_a?(Hash)

        servers.each do |role, config|
          raise Odysseus::ConfigValidationError,
                "server role '#{role}' must have 'hosts' array" \
                unless config.is_a?(Hash) && config['hosts'].is_a?(Array)

          validate_containers!(role, config['containers']) if config['containers']
          validate_deploy!(role, config['deploy']) if config['deploy']
        end
      end

      def validate_proxy!
        proxy = @config['proxy']
        return if proxy.nil?

        raise Odysseus::ConfigValidationError,
              "proxy must have 'app_port'" unless proxy['app_port']
      end

      def validate_env!
        env = @config['env']
        return if env.nil?

        unless env.is_a?(Hash)
          raise Odysseus::ConfigValidationError, "env must be a hash"
        end

        clear = env['clear']
        unless clear.nil? || clear.is_a?(Hash)
          raise Odysseus::ConfigValidationError, "env.clear must be a hash"
        end

        secret = env['secret']
        unless secret.nil? || secret.is_a?(Array)
          raise Odysseus::ConfigValidationError, "env.secret must be an array"
        end
      end

      def validate_containers!(role, containers)
        return unless containers.is_a?(Hash)

        count = containers['count']
        if count && (!count.is_a?(Integer) || count < 1)
          raise Odysseus::ConfigValidationError,
                "servers.#{role}.containers.count must be an integer >= 1"
        end
      end

      def validate_deploy!(role, deploy)
        return unless deploy.is_a?(Hash)

        strategy = deploy['strategy']
        if strategy && !Odysseus::Sails.registered?(strategy.to_sym)
          raise Odysseus::ConfigValidationError,
                "servers.#{role}.deploy.strategy '#{strategy}' is not registered — is the sail plugin gem loaded?"
        end

        %w[drain_timeout stop_timeout boot_timeout].each do |key|
          val = deploy[key]
          next unless val

          unless val.is_a?(Integer) && val > 0
            raise Odysseus::ConfigValidationError,
                  "servers.#{role}.deploy.#{key} must be a positive integer"
          end
        end
      end

      def validate_ssh!
        ssh = @config['ssh']
        return if ssh.nil?

        raise Odysseus::ConfigValidationError,
              "ssh must be a hash" unless ssh.is_a?(Hash)

        keys = ssh['keys']
        raise Odysseus::ConfigValidationError,
              "ssh.keys must be an array" \
              unless keys.nil? || keys.is_a?(Array)
      end
    end
  end
end
