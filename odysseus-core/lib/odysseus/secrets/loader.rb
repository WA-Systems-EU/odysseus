# lib/odysseus/secrets/loader.rb

require 'odysseus/secrets/encrypted_file'

module Odysseus
  module Secrets
    class Loader
      # @param config [Hash] parsed deploy config
      # @param config_dir [String] directory containing deploy.yml (for relative paths)
      def initialize(config, config_dir: '.')
        @config = config
        @config_dir = config_dir
        @cached_secrets = nil
      end

      # Load secrets from encrypted file if configured
      # @return [Hash] secrets hash (key => value)
      def load
        return @cached_secrets if @cached_secrets

        secrets_file = @config[:secrets_file]
        return {} unless secrets_file

        path = resolve_path(secrets_file)
        encrypted = EncryptedFile.new(path)

        unless encrypted.exists?
          raise Odysseus::ConfigError, "Secrets file not found: #{path}"
        end

        @cached_secrets = encrypted.read
      end

      # Get a specific secret value
      # @param key [String, Symbol] secret key
      # @return [String, nil] secret value or nil
      def get(key)
        load[key.to_sym] || load[key.to_s]
      end

      # Check if secrets file is configured
      # @return [Boolean]
      def configured?
        !@config[:secrets_file].nil?
      end

      private

      def resolve_path(secrets_file)
        if secrets_file.start_with?('/')
          secrets_file
        else
          File.join(@config_dir, secrets_file)
        end
      end
    end
  end
end
