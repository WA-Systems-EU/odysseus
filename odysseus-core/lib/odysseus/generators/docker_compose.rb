# lib/odysseus/generators/docker_compose.rb

module Odysseus
  module Generators
    class DockerCompose
      # @param config [Hash] parsed deploy config from Config::Parser
      def initialize(config)
        @config = config
      end

      # Generate docker-compose.yml content
      # @return [String] YAML content
      def generate
        compose = {
          version: '3.8',
          services: generate_services,
          volumes: generate_volumes
        }

        compose.compact.to_yaml
      end

      private

      def generate_services
        services = {}

        @config[:servers].each do |role, server_config|
          services[@config[:service].to_sym] = {
            image: "#{@config[:image]}:latest",
            command: server_config[:cmd],
            ports: generate_ports,
            environment: generate_environment,
            restart: 'unless-stopped',
            deploy: {
              resources: {
                limits: generate_resource_limits(server_config[:options]),
                reservations: generate_resource_reservations(server_config[:options])
              }
            }
          }.compact
        end

        services
      end

      def generate_ports
        return nil unless @config[:proxy]

        ["#{@config[:proxy][:app_port]}:#{@config[:proxy][:app_port]}"]
      end

      def generate_environment
        env = {}

        # Add clear env vars
        @config[:env][:clear]&.each do |key, value|
          env[key.to_s] = value.to_s
        end

        # Add placeholders for secret vars
        @config[:env][:secret]&.each do |secret_key|
          env[secret_key] = "${#{secret_key}}"
        end

        env.empty? ? nil : env
      end

      def generate_volumes
        {} # Placeholder for volume config
      end

      def generate_resource_limits(options)
        limits = {}
        limits['memory'] = options[:memory] if options[:memory]
        limits.empty? ? nil : limits
      end

      def generate_resource_reservations(options)
        reservations = {}
        reservations['memory'] = options[:memory_reservation] if options[:memory_reservation]
        reservations.empty? ? nil : reservations
      end
    end
  end
end
