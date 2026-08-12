# lib/odysseus/orchestrator/web_deploy.rb

require_relative '../core/volume_namespacer'

module Odysseus
  module Orchestrator
    class WebDeploy
      include Odysseus::Core::VolumeNamespacer

      # Probed when a proxy is configured without an explicit healthcheck block.
      DEFAULT_HEALTHCHECK_PATH = '/'.freeze

      # @param ssh [Odysseus::Deployer::SSH] SSH connection
      # @param config [Hash] parsed deploy config
      # @param logger [Object] logger (optional)
      # @param secrets_loader [Odysseus::Secrets::Loader] secrets loader (optional)
      def initialize(ssh:, config:, logger: nil, secrets_loader: nil)
        @ssh = ssh
        @config = config
        @logger = logger || default_logger
        @secrets_loader = secrets_loader
        @docker = Odysseus::Docker::Client.new(ssh)
        @caddy = Odysseus::Caddy::Client.new(ssh: ssh, docker: @docker)
      end

      # Execute full deploy for a web service
      # @param image_tag [String] image tag to deploy
      # @param role [Symbol] server role (default: :web)
      # @return [Hash] deploy result
      def deploy(image_tag:, role: :web)
        service = @config[:service]
        image = "#{@config[:image]}:#{image_tag}"

        log "Deploying #{service} (role: #{role})"
        log "  Image: #{image}"

        # A web role is proxied by Caddy, which needs a port to route to. Without
        # one the container gets no health command and the deploy would sit in
        # health checks until it timed out, so say so up front.
        unless app_port
          raise Odysseus::ConfigError,
                "proxy.app_port is required to deploy the '#{role}' role — " \
                'set it to the port your app listens on inside the container'
        end

        # Step 1: Ensure Caddy is running
        log 'Ensuring Caddy proxy is running...'
        if @caddy.running?
          log '  Caddy already running'
        else
          ensure_caddy!
          log '  Caddy started'
        end

        # Step 2: Find existing containers
        old_containers = @docker.list(service: service)
        log "  Found #{old_containers.size} existing container(s)"

        # Step 3: Start new container
        log 'Starting new container...'
        new_container_id = start_new_container(image: image, role: role)
        log "  Container started: #{new_container_id[0..11]}"

        # Step 4: Wait for healthy
        healthcheck_desc = describe_healthcheck(@config[:proxy]&.dig(:healthcheck))
        log "Waiting for health check... #{healthcheck_desc}"
        unless wait_for_healthy(new_container_id)
          log_health_failure(new_container_id)
          handle_failed_deploy(new_container_id, old_containers)
          raise Odysseus::DeployError, 'Container failed health checks'
        end
        log '  Health check passed'

        # Step 5: Add new container to Caddy
        proxy_hosts = @config[:proxy][:hosts]&.join(', ')
        log "Adding to Caddy proxy (hosts: #{proxy_hosts})..."
        add_to_caddy(new_container_id)
        log '  Caddy routing configured'

        # Step 6: Remove old containers from Caddy and stop them
        old_containers.each do |old|
          log "Draining old container #{old['ID'][0..11]}..."
          drain_and_remove(old['ID'])
          log '  Old container removed'
        end

        # Step 7: Cleanup old stopped containers
        cleaned = @docker.cleanup_old_containers(service: service, keep: 2)
        log "  Cleaned up #{cleaned.size} old container(s)" if cleaned.any?

        # Step 8: Cleanup stale Caddy upstreams (in case any were missed)
        removed_upstreams = @caddy.cleanup_stale_upstreams(service: service)
        log "  Removed #{removed_upstreams.size} stale upstream(s)" if removed_upstreams.any?

        log "Deploy complete for #{service}"

        {
          success: true,
          container_id: new_container_id,
          service: service,
          image: image
        }
      rescue StandardError => e
        log "Deploy FAILED: #{e.message}", :error
        raise
      end

      private

      def ensure_caddy!
        return if @caddy.ensure_running

        raise Odysseus::DeployError, 'Failed to start Caddy proxy'
      end

      def start_new_container(image:, role:)
        service = @config[:service]
        timestamp = Time.now.strftime('%Y%m%d%H%M%S')
        container_name = "#{service}-#{timestamp}"

        server_config = @config[:servers][role] || {}
        options = server_config[:options] || {}
        proxy_config = @config[:proxy] || {}

        env = build_environment
        log "  Environment: #{env.size} variable(s) injected"

        volumes = namespace_volumes(server_config[:volumes], service: service)
        log "  Volumes: #{volumes.join(', ')}" if volumes&.any?

        if options[:memory] || options[:cpus]
          log "  Resources: memory=#{options[:memory] || 'default'}, cpus=#{options[:cpus] || 'default'}"
        end

        @docker.run(
          name: container_name,
          image: image,
          options: {
            service: service,
            version: timestamp,
            ports: internal_port_mapping(proxy_config[:app_port]),
            env: env,
            volumes: volumes,
            memory: options[:memory],
            memory_reservation: options[:memory_reservation],
            cpus: options[:cpus],
            cpu_shares: options[:cpu_shares],
            network: 'odysseus',
            healthcheck: build_healthcheck(proxy_config[:healthcheck]),
            cmd: server_config[:cmd]
          }
        )
      end

      def internal_port_mapping(app_port)
        # Don't expose to host, only internal network
        # Caddy will route traffic to container
        return nil unless app_port

        # For internal network, we don't need host port mapping
        # Container exposes the port on the Docker network
        nil
      end

      def build_environment
        env = {}

        # Clear env vars (hardcoded values)
        @config[:env][:clear]&.each do |key, value|
          env[key.to_s] = value.to_s
        end

        # Secret env vars - first try encrypted file, then server environment
        @config[:env][:secret]&.each do |key|
          # Try encrypted secrets file first
          if @secrets_loader&.configured?
            value = @secrets_loader.get(key)
            if value
              env[key.to_s] = value.to_s
              next
            end
          end

          # Fall back to server's environment
          value = @ssh.execute("echo $#{key}").strip
          env[key.to_s] = value unless value.empty?
        end

        env
      end

      # Build the container-level health check Docker polls.
      #
      # The deploy gates on Docker reporting the container healthy, so a web
      # container always needs a health command — without one the status stays
      # 'none' forever and every deploy times out. When no healthcheck block is
      # configured we probe the app port at DEFAULT_HEALTHCHECK_PATH, matching
      # the default Config::Parser applies to an empty healthcheck block.
      def build_healthcheck(hc_config)
        port = app_port
        return nil unless port

        path = (hc_config && hc_config[:path]) || DEFAULT_HEALTHCHECK_PATH
        expect_status = hc_config && hc_config[:expect_status]

        # Build curl command based on expected status
        cmd = if expect_status
                # Check for specific status code or range (e.g., 301, "2xx", "3xx")
                status_str = expect_status.to_s
                if status_str.end_with?('xx')
                  # Range like "2xx" or "3xx" - check first digit
                  first_digit = status_str[0]
                  "curl -s -o /dev/null -w '%{http_code}' http://localhost:#{port}#{path} | grep -q '^#{first_digit}' || exit 1"
                else
                  # Specific status code like 200 or 301
                  "curl -s -o /dev/null -w '%{http_code}' http://localhost:#{port}#{path} | grep -q '^#{expect_status}$' || exit 1"
                end
              else
                # Default: accept 2xx (use -f flag which fails on 4xx/5xx)
                "curl -sf http://localhost:#{port}#{path} || exit 1"
              end

        {
          cmd: cmd,
          interval: hc_config[:interval] || 10,
          timeout: hc_config[:timeout] || 5,
          retries: 3
        }
      end

      def wait_for_healthy(container_id, timeout: 60)
        @docker.wait_healthy(container_id, timeout: timeout)
      end

      def add_to_caddy(container_id)
        # Get container name for DNS resolution in Docker network
        container_info = @ssh.execute("docker inspect --format '{{.Name}}' #{container_id}").strip
        container_name = container_info.delete_prefix('/')

        port = @config[:proxy][:app_port]
        upstream = "#{container_name}:#{port}"
        proxy_config = @config[:proxy]

        @caddy.add_upstream(
          service: @config[:service],
          hosts: proxy_config[:hosts],
          upstream: upstream,
          healthcheck: proxy_config[:healthcheck],
          ssl: proxy_config[:ssl],
          ssl_email: proxy_config[:ssl_email]
        )
      end

      def drain_and_remove(container_id)
        container_info = @ssh.execute("docker inspect --format '{{.Name}}' #{container_id}").strip
        container_name = container_info.delete_prefix('/')
        port = @config[:proxy][:app_port]

        # Remove from Caddy (drains connections)
        @caddy.drain_upstream(
          service: @config[:service],
          upstream: "#{container_name}:#{port}"
        )

        # Give some time for connections to drain
        sleep 5

        # Stop and remove the old container
        @docker.stop(container_id)
        @docker.remove(container_id)
      end

      def handle_failed_deploy(new_container_id, old_containers)
        log 'Rolling back failed deploy...', :warn

        # Remove the failed new container
        @docker.stop(new_container_id)
        @docker.remove(new_container_id, force: true)

        # Old containers should still be running and in Caddy
        if old_containers.any?
          log "Rollback complete — #{old_containers.size} old container(s) still serving traffic"
        else
          log 'Rollback complete — no previous containers to fall back to', :warn
        end
      end

      def log_health_failure(container_id)
        log "Health check FAILED for container #{container_id[0..11]}", :error

        # Fetch recent container logs to help diagnose the failure
        begin
          recent_logs = @docker.logs(container_id, tail: 30)
          unless recent_logs.strip.empty?
            log '  Container logs (last 30 lines):', :error
            recent_logs.each_line { |line| log "    #{line.rstrip}", :error }
          end
        rescue StandardError => e
          log "  Could not fetch container logs: #{e.message}", :warn
        end

        # Show the health check status
        begin
          status = @docker.health_status(container_id)
          log "  Health status: #{status}", :error
        rescue StandardError
          # ignore
        end
      end

      def describe_healthcheck(hc_config)
        port = app_port
        path = (hc_config && hc_config[:path]) || DEFAULT_HEALTHCHECK_PATH
        interval = (hc_config && hc_config[:interval]) || 10

        "(GET http://localhost:#{port}#{path}, interval: #{interval}s)"
      end

      # Port the app listens on inside the container, nil when no proxy is configured.
      def app_port
        @config[:proxy] && @config[:proxy][:app_port]
      end

      def default_logger
        @default_logger ||= Object.new.tap do |l|
          def l.info(msg) = puts(msg)
          def l.warn(msg) = puts("[WARN] #{msg}")
          def l.error(msg) = puts("[ERROR] #{msg}")
        end
      end

      def log(message, level = :info)
        @logger.send(level, message)
      end
    end
  end
end
