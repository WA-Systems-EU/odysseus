# lib/odysseus/generators/caddy.rb

module Odysseus
  module Generators
    class Caddy
      # @param config [Hash] parsed deploy config from Config::Parser
      def initialize(config)
        @config = config
      end

      # Generate Caddyfile content
      # @return [String] Caddyfile content
      def generate
        return '' unless @config[:proxy]

        lines = []

        # Generate server blocks for each host
        @config[:proxy][:hosts].each do |host|
          lines << generate_server_block(host)
        end

        lines.join("\n\n")
      end

      private

      def generate_server_block(host)
        block = []
        block << host.to_s
        block << "{"
        block << generate_reverse_proxy
        block << generate_healthcheck if @config[:proxy][:healthcheck]
        block << "}"

        block.join("\n  ")
      end

      def generate_reverse_proxy
        service_host = @config[:service]
        port = @config[:proxy][:app_port]
        timeout = @config[:proxy][:response_timeout]

        [
          "reverse_proxy #{service_host}:#{port} {",
          "  timeout #{timeout}s",
          "}"
        ].join("\n  ")
      end

      def generate_healthcheck
        hc = @config[:proxy][:healthcheck]
        return '' unless hc

        [
          "health_uri #{hc[:path]}",
          "health_interval #{hc[:interval]}s",
          "health_timeout #{hc[:timeout]}s"
        ].join("\n  ")
      end
    end
  end
end
