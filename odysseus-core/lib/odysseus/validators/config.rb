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
