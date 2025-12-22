# lib/odysseus/config/parser.rb

require 'yaml'
require 'odysseus/errors'
require 'odysseus/validators/config'

module Odysseus
  module Config
    class Parser
      # @param config_path [String] Path to deploy.yml
      def initialize(config_path)
        @config_path = config_path
      end

      # Parse and return config hash
      # @return [Hash]
      # @raise [Odysseus::ConfigError] if invalid
      def parse
        raw_config = load_yaml
        validate!(raw_config)
        normalize(raw_config)
      rescue Psych::SyntaxError => e
        raise Odysseus::ConfigParseError, "Failed to parse YAML: #{e.message}"
      end

      private

      # Load YAML file
      def load_yaml
        YAML.load_file(@config_path)
      rescue Errno::ENOENT
        raise Odysseus::ConfigError, "Config file not found: #{@config_path}"
      end

      # Validate config structure
      def validate!(config)
        validator = Odysseus::Validators::Config.new(config)
        validator.validate!
      end

      # Normalize config to standard format
      def normalize(config)
        {
          service: config['service'],
          image: config['image'],
          servers: parse_servers(config['servers']),
          proxy: parse_proxy(config['proxy']),
          env: parse_env(config['env']),
          secrets_file: config['secrets_file'],
          ssh: parse_ssh(config['ssh']),
          accessories: parse_accessories(config['accessories']),
          builder: config['builder'] || {}
        }
      end

      # Parse servers config
      # @param servers [Hash] servers block from config
      # @return [Hash] normalized servers config
      def parse_servers(servers)
        return {} unless servers

        servers.each_with_object({}) do |(role, config), acc|
          acc[role.to_sym] = {
            hosts: config['hosts'] || [],
            options: symbolize_keys(config['options'] || {}),
            cmd: config['cmd'],
            healthcheck: parse_server_healthcheck(config['healthcheck'])
          }
        end
      end

      # Parse server-level healthcheck (for workers/jobs)
      def parse_server_healthcheck(healthcheck)
        return nil unless healthcheck

        {
          cmd: healthcheck['cmd'],
          interval: healthcheck['interval'] || 30,
          timeout: healthcheck['timeout'] || 10,
          retries: healthcheck['retries'] || 3
        }
      end

      # Parse proxy (Caddy) config
      def parse_proxy(proxy)
        return {} unless proxy

        {
          ssl: proxy.key?('ssl') ? proxy['ssl'] : true,
          ssl_email: proxy['ssl_email'],
          hosts: proxy['hosts'] || [],
          app_port: proxy['app_port'],
          healthcheck: parse_healthcheck(proxy['healthcheck']),
          response_timeout: proxy['response_timeout'] || 60
        }
      end

      # Parse healthcheck config
      def parse_healthcheck(healthcheck)
        return {} unless healthcheck

        {
          interval: healthcheck['interval'] || 5,
          path: healthcheck['path'] || '/',
          timeout: healthcheck['timeout'] || 5
        }
      end

      # Parse environment variables
      def parse_env(env)
        return { clear: {}, secret: [] } unless env

        {
          clear: symbolize_keys(env['clear'] || {}),
          secret: env['secret'] || []
        }
      end

      # Parse SSH config
      def parse_ssh(ssh)
        return { user: 'root', keys: [] } unless ssh

        {
          user: ssh['user'] || 'root',
          keys: ssh['keys'] || []
        }
      end

      # Parse accessories config
      def parse_accessories(accessories)
        return {} unless accessories

        accessories.each_with_object({}) do |(name, config), acc|
          acc[name.to_sym] = {
            image: config['image'],
            cmd: config['cmd'],
            ports: config['ports'],
            volumes: config['volumes'],
            env: parse_env(config['env']),
            healthcheck: parse_accessory_healthcheck(config['healthcheck']),
            proxy: parse_accessory_proxy(config['proxy'])
          }
        end
      end

      # Parse accessory healthcheck
      def parse_accessory_healthcheck(healthcheck)
        return nil unless healthcheck

        {
          cmd: healthcheck['cmd'],
          interval: healthcheck['interval'] || 30,
          timeout: healthcheck['timeout'] || 10,
          retries: healthcheck['retries'] || 3
        }
      end

      # Parse accessory proxy config
      def parse_accessory_proxy(proxy)
        return nil unless proxy

        {
          hosts: proxy['hosts'] || [],
          app_port: proxy['app_port'],
          ssl: proxy.key?('ssl') ? proxy['ssl'] : true,
          ssl_email: proxy['ssl_email']
        }
      end

      # Convert string keys to symbols
      def symbolize_keys(hash)
        hash.each_with_object({}) do |(key, value), result|
          sym_key = key.to_s.tr('-', '_').to_sym
          result[sym_key] = value
        end
      end
    end
  end
end
