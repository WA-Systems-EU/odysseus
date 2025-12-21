# lib/odysseus/orchestrator/web_deploy.rb

module Odysseus
  module Orchestrator
    class WebDeploy
      # @param ssh [Odysseus::Deployer::SSH] SSH connection
      # @param config [Hash] parsed deploy config
      # @param logger [Object] logger (optional)
      def initialize(ssh:, config:, logger: nil)
        @ssh = ssh
        @config = config
        @logger = logger || default_logger
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

        log "Starting deploy of #{service} with #{image}"

        # Step 1: Ensure Caddy is running
        log "Ensuring Caddy proxy is running..."
        ensure_caddy!

        # Step 2: Find existing containers
        log "Checking for existing containers..."
        old_containers = @docker.list(service: service)
        log "Found #{old_containers.size} existing container(s)"

        # Step 3: Start new container
        log "Starting new container..."
        new_container_id = start_new_container(image: image, role: role)
        log "Started container: #{new_container_id[0..11]}"

        # Step 4: Wait for healthy
        log "Waiting for container to be healthy..."
        unless wait_for_healthy(new_container_id)
          handle_failed_deploy(new_container_id, old_containers)
          raise Odysseus::DeployError, "Container failed health checks"
        end
        log "Container is healthy!"

        # Step 5: Add new container to Caddy
        log "Adding container to Caddy..."
        add_to_caddy(new_container_id)

        # Step 6: Remove old containers from Caddy and stop them
        old_containers.each do |old|
          log "Draining old container: #{old['ID'][0..11]}..."
          drain_and_remove(old['ID'])
        end

        # Step 7: Cleanup old stopped containers
        log "Cleaning up old containers..."
        @docker.cleanup_old_containers(service: service, keep: 2)

        log "Deploy complete!"

        {
          success: true,
          container_id: new_container_id,
          service: service,
          image: image
        }
      rescue StandardError => e
        log "Deploy failed: #{e.message}", :error
        raise
      end

      private

      def ensure_caddy!
        unless @caddy.ensure_running
          raise Odysseus::DeployError, "Failed to start Caddy proxy"
        end
      end

      def start_new_container(image:, role:)
        service = @config[:service]
        timestamp = Time.now.strftime('%Y%m%d%H%M%S')
        container_name = "#{service}-#{timestamp}"

        server_config = @config[:servers][role] || {}
        options = server_config[:options] || {}
        proxy_config = @config[:proxy] || {}

        @docker.run(
          name: container_name,
          image: image,
          options: {
            service: service,
            version: timestamp,
            ports: internal_port_mapping(proxy_config[:app_port]),
            env: build_environment,
            memory: options[:memory],
            memory_reservation: options[:memory_reservation],
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

        # Secret env vars (from server environment)
        @config[:env][:secret]&.each do |key|
          # Get value from server's environment
          value = @ssh.execute("echo $#{key}").strip
          env[key] = value unless value.empty?
        end

        env
      end

      def build_healthcheck(hc_config)
        return nil unless hc_config && hc_config[:path]

        {
          cmd: "curl -sf http://localhost:#{@config[:proxy][:app_port]}#{hc_config[:path]} || exit 1",
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
        log "Rolling back failed deploy...", :warn

        # Remove the failed new container
        @docker.stop(new_container_id)
        @docker.remove(new_container_id, force: true)

        # Old containers should still be running and in Caddy
        log "Rollback complete - old containers still serving traffic"
      end

      def default_logger
        @default_logger ||= Object.new.tap do |l|
          def l.info(msg); puts msg; end
          def l.warn(msg); puts "[WARN] #{msg}"; end
          def l.error(msg); puts "[ERROR] #{msg}"; end
        end
      end

      def log(message, level = :info)
        @logger.send(level, message)
      end
    end
  end
end
