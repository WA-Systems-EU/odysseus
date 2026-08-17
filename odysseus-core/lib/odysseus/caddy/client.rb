# lib/odysseus/caddy/client.rb

require 'json'
require 'shellwords'

module Odysseus
  module Caddy
    class Client
      ADMIN_API_PORT = 2019
      CONTAINER_NAME = 'odysseus-caddy'.freeze
      CADDY_IMAGE = 'caddy:2-alpine'.freeze

      # @param ssh [Odysseus::Deployer::SSH] SSH connection to server
      # @param docker [Odysseus::Docker::Client] Docker client
      def initialize(ssh:, docker:)
        @ssh = ssh
        @docker = docker
      end

      # Ensure Caddy is running
      #
      # There are three states, not two: running, absent, and stopped-but-
      # present. Docker refuses `docker run --name odysseus-caddy` while a
      # container by that name already exists, so a stopped Caddy would
      # otherwise fail every deploy after it, forever.
      #
      # A stopped container is removed rather than `docker start`ed. It
      # carries whatever configuration it was *created* with, including its
      # volume mount — and this branch changed Caddy's data directory from a
      # fixed system path to one derived from the deploy user (see
      # Odysseus::HostPaths#caddy_dir). `docker start` would silently
      # resurrect a container mounting the old path while everything else
      # believes it moved. Recreating always applies current configuration.
      # Nothing is lost: certificates live in the mounted volume, and routes
      # are re-added by the deploy that follows.
      #
      # @return [Boolean] true if caddy is running
      def ensure_running
        return true if running?

        @docker.remove(CONTAINER_NAME) if @docker.container_exists?(CONTAINER_NAME)

        start_caddy
        running?
      end

      # Check if Caddy container is running
      # @return [Boolean]
      def running?
        @docker.running?(CONTAINER_NAME)
      end

      # Start Caddy container
      def start_caddy
        # Create network if not exists (with label to protect from prune)
        @ssh.execute('docker network create --label odysseus.managed=true odysseus 2>/dev/null || true')

        # Create data directory for certificates
        @ssh.execute("mkdir -p #{Shellwords.escape(host_paths.caddy_dir)}")

        # Run Caddy with admin API enabled and persistent storage for certs
        #
        # The mkdir above and this mount must name the same directory, or
        # Caddy starts against an empty one and silently has no certificates.
        # Docker::Client interpolates `-v` values into its command line
        # unescaped, so the directory is escaped here rather than there.
        @docker.run(
          name: CONTAINER_NAME,
          image: CADDY_IMAGE,
          options: {
            service: 'odysseus-proxy',
            ports: ['80:80', '443:443', "#{ADMIN_API_PORT}:#{ADMIN_API_PORT}"],
            network: 'odysseus',
            restart: 'unless-stopped',
            volumes: ["#{Shellwords.escape(host_paths.caddy_dir)}:/data"],
            env: {
              'CADDY_ADMIN' => "0.0.0.0:#{ADMIN_API_PORT}"
            },
            labels: {
              'odysseus.managed' => 'true'
            }
          }
        )

        # Wait for Caddy to be ready
        sleep 2
      end

      # Add an upstream server to a route
      # @param service [String] service name (used as route identifier)
      # @param hosts [Array<String>] domain hosts for this service
      # @param upstream [String] upstream address (container:port)
      # @param healthcheck [Hash] healthcheck config (optional)
      # @param ssl [Boolean] enable automatic HTTPS (default: true)
      # @param ssl_email [String] email for Let's Encrypt registration
      def add_upstream(service:, hosts:, upstream:, healthcheck: nil, ssl: true, ssl_email: nil)
        # Enable TLS for these hosts if ssl is enabled
        enable_tls_for_hosts(hosts, email: ssl_email) if ssl

        # Check if route already exists for this service
        routes = api_request('GET', '/config/apps/http/servers/srv0/routes') || []
        existing_idx = routes.find_index { |r| r['@id'] == "route-#{service}" }

        if existing_idx
          # Update hosts if they changed
          current_hosts = routes[existing_idx].dig('match', 0, 'host') || []
          if current_hosts.sort != hosts.sort
            api_request('PATCH', "/config/apps/http/servers/srv0/routes/#{existing_idx}/match/0/host", hosts)
          end

          # Update existing route's upstreams
          current_upstreams = routes[existing_idx].dig('handle', 0, 'upstreams') || []
          unless current_upstreams.any? { |u| u['dial'] == upstream }
            current_upstreams << { 'dial' => upstream }
            api_request('PATCH', "/config/apps/http/servers/srv0/routes/#{existing_idx}/handle/0/upstreams",
                        current_upstreams)
          end
        else
          # Create new route - prepend at index 0 so it matches before default routes
          config = build_route_config(
            service: service,
            hosts: hosts,
            upstreams: [upstream],
            healthcheck: healthcheck
          )
          api_request('PUT', '/config/apps/http/servers/srv0/routes/0', config)
        end
      end

      # Remove an upstream from a service (or entire route if upstream is nil)
      # @param service [String] service name
      # @param upstream [String, nil] upstream to remove, or nil to remove entire route
      def remove_upstream(service:, upstream:)
        # Get current config
        routes = api_request('GET', '/config/apps/http/servers/srv0/routes')
        return unless routes

        # Find route for this service and remove the upstream
        routes.each_with_index do |route, idx|
          next unless route['@id'] == "route-#{service}"

          # If no specific upstream, remove the entire route
          if upstream.nil?
            api_request('DELETE', "/config/apps/http/servers/srv0/routes/#{idx}")
            break
          end

          upstreams = route.dig('handle', 0, 'upstreams') || []
          upstreams.reject! { |u| u['dial'] == upstream }

          if upstreams.empty?
            # Remove entire route if no upstreams left
            api_request('DELETE', "/config/apps/http/servers/srv0/routes/#{idx}")
          else
            # Update route with remaining upstreams
            api_request('PATCH', "/config/apps/http/servers/srv0/routes/#{idx}/handle/0/upstreams", upstreams)
          end

          break
        end
      end

      # Drain connections from an upstream (mark as down)
      # @param service [String] service name
      # @param upstream [String] upstream to drain
      def drain_upstream(service:, upstream:)
        # Caddy doesn't have built-in drain, so we set health to down
        # This will stop new connections from being sent to this upstream
        # The upstream will be removed after existing connections close

        # For now, we just remove it - Caddy will gracefully close existing connections
        remove_upstream(service: service, upstream: upstream)
      end

      # Remove stale upstreams that point to stopped/non-existent containers
      # @param service [String] service name
      # @return [Array<String>] list of removed upstreams
      def cleanup_stale_upstreams(service:)
        routes = api_request('GET', '/config/apps/http/servers/srv0/routes') || []
        route_idx = routes.find_index { |r| r['@id'] == "route-#{service}" }
        return [] unless route_idx

        upstreams = routes[route_idx].dig('handle', 0, 'upstreams') || []
        removed = []

        upstreams.each do |upstream|
          dial = upstream['dial']
          # Extract container name from upstream (format: container_name:port)
          container_name = dial.split(':').first
          next if container_name.nil? || container_name.empty?

          # Check if container is running
          unless @docker.running?(container_name)
            remove_upstream(service: service, upstream: dial)
            removed << dial
          end
        end

        removed
      end

      # Get current Caddy config
      # @return [Hash] current config
      def config
        api_request('GET', '/config/')
      end

      # List all configured services/routes
      # @return [Array<Hash>] list of services with their config
      def list_services
        routes = api_request('GET', '/config/apps/http/servers/srv0/routes') || []

        routes.map do |route|
          id = route['@id'] || 'unknown'
          service_name = id.sub(/^route-/, '')
          hosts = route.dig('match', 0, 'host') || []
          upstreams = route.dig('handle', 0, 'upstreams') || []

          {
            service: service_name,
            hosts: hosts,
            upstreams: upstreams.map { |u| u['dial'] },
            has_healthcheck: !route.dig('handle', 0, 'health_checks').nil?
          }
        end
      end

      # Get TLS/SSL status for domains
      # @return [Hash] TLS configuration info
      def tls_status
        tls_config = api_request('GET', '/config/apps/tls') || {}
        policies = tls_config.dig('automation', 'policies') || []

        {
          enabled: !policies.empty?,
          policies: policies.map do |policy|
            {
              subjects: policy['subjects'] || [],
              issuer: policy.dig('issuers', 0, 'module') || 'unknown',
              email: policy.dig('issuers', 0, 'email')
            }
          end
        }
      end

      # Get server listen addresses
      # @return [Array<String>] listen addresses
      def listen_addresses
        servers = api_request('GET', '/config/apps/http/servers') || {}
        servers.dig('srv0', 'listen') || []
      end

      # Print formatted status (for CLI use)
      # @return [Hash] full status summary
      def status
        {
          running: running?,
          listen: listen_addresses,
          services: list_services,
          tls: tls_status
        }
      end

      # Enable TLS/HTTPS for hosts
      # @param hosts [Array<String>] domain hosts
      # @param email [String] email for Let's Encrypt
      def enable_tls_for_hosts(hosts, email: nil)
        # nil means Caddy has no tls app yet, whether it answered with an error or
        # a null body for the missing path. That distinction picks the verb below.
        existing_tls = api_request('GET', '/config/apps/tls')
        existing_automation = existing_tls&.dig('automation') || {}
        existing_policies = existing_automation['policies'] || []

        # Collect all existing subjects
        all_subjects = existing_policies.flat_map { |p| p['subjects'] || [] }

        # Add new hosts (avoid duplicates)
        hosts.each do |host|
          all_subjects << host unless all_subjects.include?(host)
        end

        # Build issuer config
        issuer = { 'module' => 'acme' }
        issuer['email'] = email if email

        # One policy covering every domain, merged onto whatever else the tls app
        # holds: writing only our automation block would drop sibling settings
        # such as explicit certificate loaders or on_demand limits that other
        # services on this host may depend on.
        tls_config = (existing_tls || {}).merge(
          'automation' => existing_automation.merge(
            'policies' => [{ 'subjects' => all_subjects, 'issuers' => [issuer] }]
          )
        )

        # Caddy's PUT creates and answers 409 if the key is already there; PATCH
        # replaces and fails if it is not. Neither one is an upsert on its own.
        if existing_tls.nil?
          api_request('PUT', '/config/apps/tls', tls_config)
        else
          api_request('PATCH', '/config/apps/tls', tls_config)
        end

        # Ensure HTTPS server exists and listens on 443
        ensure_https_server
      end

      private

      def host_paths
        @host_paths ||= Odysseus::HostPaths.new(@ssh)
      end

      def ensure_https_server
        # Check if we have an HTTPS server configured
        servers = api_request('GET', '/config/apps/http/servers') || {}

        return if servers['srv0']&.dig('listen')&.include?(':443')

        # Add :443 to listen addresses
        current_listen = servers.dig('srv0', 'listen') || [':80']
        return if current_listen.include?(':443')

        current_listen << ':443'
        api_request('PATCH', '/config/apps/http/servers/srv0/listen', current_listen)
      end

      def build_route_config(service:, hosts:, upstreams:, healthcheck: nil)
        route = {
          '@id' => "route-#{service}",
          'match' => [{ 'host' => hosts }],
          'handle' => [
            {
              'handler' => 'reverse_proxy',
              'upstreams' => upstreams.map { |u| { 'dial' => u } }
            }
          ]
        }

        # Add health checks if configured
        if healthcheck
          active_check = {
            'uri' => healthcheck[:path] || '/health',
            'interval' => "#{healthcheck[:interval] || 10}s",
            'timeout' => "#{healthcheck[:timeout] || 5}s"
          }

          # Add expected status code if specified (e.g., 200, 301, or 2 for 2xx)
          if healthcheck[:expect_status]
            status = healthcheck[:expect_status].to_s
            # Caddy expects just the first digit for ranges like "2xx"
            expect_value = status.end_with?('xx') ? status[0].to_i : status.to_i
            active_check['expect_status'] = expect_value
          end

          route['handle'][0]['health_checks'] = { 'active' => active_check }
        end

        route
      end

      # Call Caddy's admin API over SSH.
      #
      # curl exits 0 for HTTP errors, so the status code is appended to the
      # response with -w and split back off here. A rejected write leaves the
      # proxy in a state the caller must know about, so it raises; a failed read
      # returns nil, because Caddy answers 500 for config paths that simply do
      # not exist yet (no tls app on a freshly booted proxy, for instance).
      #
      # @raise [Odysseus::ProxyApiError] if a mutating request returns HTTP >= 400
      def api_request(method, path, body = nil)
        cmd = "curl -s -w '\\n%{http_code}' -X #{method} "
        cmd += "-H 'Content-Type: application/json' "
        cmd += "-d '#{body.to_json}' " if body
        cmd += "http://localhost:#{ADMIN_API_PORT}#{path}"

        response_body, status = split_status(@ssh.execute(cmd))

        if status && status >= 400
          return nil if method == 'GET'

          raise Odysseus::ProxyApiError, api_error_message(method, path, status, response_body)
        end

        return nil if response_body.strip.empty?

        JSON.parse(response_body)
      rescue JSON::ParserError
        response_body
      end

      # Split curl's trailing '%{http_code}' line off the response body.
      # Returns a nil status when no status line is present.
      def split_status(output)
        text = output.to_s.sub(/\s+\z/, '')
        newline_idx = text.rindex("\n")
        trailer = newline_idx ? text[(newline_idx + 1)..] : text

        return [output.to_s, nil] unless trailer&.match?(/\A\d{3}\z/)

        [newline_idx ? text[0...newline_idx] : '', trailer.to_i]
      end

      def api_error_message(method, path, status, response_body)
        message = "Caddy admin API #{method} #{path} failed with HTTP #{status}"
        details = response_body.to_s.strip
        message += ": #{details}" unless details.empty?
        message
      end
    end
  end
end
