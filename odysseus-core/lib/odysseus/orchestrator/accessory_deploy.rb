# lib/odysseus/orchestrator/accessory_deploy.rb

module Odysseus
  module Orchestrator
    class AccessoryDeploy
      # @param ssh [Odysseus::Deployer::SSH] SSH connection
      # @param config [Hash] parsed deploy config
      # @param secrets_loader [Odysseus::Secrets::Loader] secrets loader (optional)
      # @param logger [Object] logger (optional)
      def initialize(ssh:, config:, secrets_loader: nil, logger: nil)
        @ssh = ssh
        @config = config
        @secrets_loader = secrets_loader
        @logger = logger || default_logger
        @docker = Odysseus::Docker::Client.new(ssh)
        @caddy = Odysseus::Caddy::Client.new(ssh: ssh, docker: @docker)
      end

      # Deploy/ensure an accessory is running
      # @param name [Symbol] accessory name
      # @return [Hash] deploy result
      def deploy(name:)
        accessory_config = @config[:accessories][name]
        raise Odysseus::ConfigError, "Accessory '#{name}' not found in config" unless accessory_config

        service_name = accessory_name(name)
        image = accessory_config[:image]

        log "Deploying accessory: #{service_name}"

        # Check if accessory is already running
        existing = @docker.list(service: service_name)
        if existing.any? { |c| c['State'] == 'running' }
          log "Accessory #{service_name} is already running"
          return { success: true, already_running: true, service: service_name }
        end

        # Start the accessory
        log "Starting #{service_name}..."
        container_id = start_accessory(name: name, config: accessory_config)
        log "Started container: #{container_id[0..11]}"

        # Wait for healthy if healthcheck configured
        if accessory_config[:healthcheck]
          log "Waiting for container to be healthy..."
          unless @docker.wait_healthy(container_id, timeout: 120)
            @docker.stop(container_id)
            @docker.remove(container_id, force: true)
            raise Odysseus::DeployError, "Accessory failed health checks"
          end
          log "Container is healthy!"
        else
          sleep 3
          unless @docker.running?(container_id)
            raise Odysseus::DeployError, "Accessory failed to start"
          end
        end

        # Add to Caddy if proxy config is present
        if accessory_config[:proxy]
          log "Configuring proxy..."
          add_to_caddy(name: name, container_id: container_id, config: accessory_config)
        end

        log "Accessory #{service_name} deployed!"

        {
          success: true,
          container_id: container_id,
          service: service_name,
          image: image
        }
      rescue StandardError => e
        log "Accessory deploy failed: #{e.message}", :error
        raise
      end

      # Stop and remove an accessory
      # @param name [Symbol] accessory name
      def remove(name:)
        accessory_config = @config[:accessories][name]
        raise Odysseus::ConfigError, "Accessory '#{name}' not found in config" unless accessory_config

        service_name = accessory_name(name)
        log "Removing accessory: #{service_name}"

        # Remove from Caddy if proxy configured
        if accessory_config[:proxy]
          containers = @docker.list(service: service_name)
          containers.each do |c|
            container_name = c['Names'].delete_prefix('/')
            port = accessory_config[:proxy][:app_port]
            @caddy.drain_upstream(service: service_name, upstream: "#{container_name}:#{port}")
          end
        end

        # Stop and remove containers
        containers = @docker.list(service: service_name, all: true)
        containers.each do |c|
          @docker.stop(c['ID']) if c['State'] == 'running'
          @docker.remove(c['ID'], force: true)
        end

        log "Accessory #{service_name} removed!"
        { success: true, service: service_name }
      end

      # Restart an accessory (remove and redeploy)
      # @param name [Symbol] accessory name
      def restart(name:)
        remove(name: name)
        deploy(name: name)
      end

      # Upgrade an accessory to a new image version (preserves volumes)
      # @param name [Symbol] accessory name
      # @return [Hash] upgrade result
      def upgrade(name:)
        accessory_config = @config[:accessories][name]
        raise Odysseus::ConfigError, "Accessory '#{name}' not found in config" unless accessory_config

        service_name = accessory_name(name)
        image = accessory_config[:image]

        log "Upgrading accessory: #{service_name} to #{image}"

        # Pull the new image first (before stopping anything)
        log "Pulling new image: #{image}..."
        @docker.pull(image)
        log "Image pulled successfully"

        # Check for existing container
        existing = @docker.list(service: service_name, all: true)
        old_container = existing.first

        # Remove from Caddy if proxy configured (before stopping)
        if accessory_config[:proxy] && old_container && old_container['State'] == 'running'
          container_name = old_container['Names'].delete_prefix('/')
          port = accessory_config[:proxy][:app_port]
          log "Removing from proxy..."
          @caddy.drain_upstream(service: service_name, upstream: "#{container_name}:#{port}")
        end

        # Stop and remove old container if exists
        if old_container
          log "Stopping old container: #{old_container['ID'][0..11]}..."
          @docker.stop(old_container['ID'], timeout: 30) if old_container['State'] == 'running'
          @docker.remove(old_container['ID'], force: true)
          log "Old container removed"
        end

        # Start the accessory with the new image (volumes are preserved on host)
        log "Starting new container with #{image}..."
        container_id = start_accessory(name: name, config: accessory_config)
        log "Started container: #{container_id[0..11]}"

        # Wait for healthy if healthcheck configured
        if accessory_config[:healthcheck]
          log "Waiting for container to be healthy..."
          unless @docker.wait_healthy(container_id, timeout: 120)
            @docker.stop(container_id)
            @docker.remove(container_id, force: true)
            raise Odysseus::DeployError, "Accessory failed health checks after upgrade"
          end
          log "Container is healthy!"
        else
          sleep 3
          unless @docker.running?(container_id)
            raise Odysseus::DeployError, "Accessory failed to start after upgrade"
          end
        end

        # Add to Caddy if proxy config is present
        if accessory_config[:proxy]
          log "Configuring proxy..."
          add_to_caddy(name: name, container_id: container_id, config: accessory_config)
        end

        log "Accessory #{service_name} upgraded to #{image}!"

        {
          success: true,
          container_id: container_id,
          service: service_name,
          image: image,
          upgraded: true
        }
      rescue StandardError => e
        log "Accessory upgrade failed: #{e.message}", :error
        raise
      end

      # List status of all accessories
      # @return [Array<Hash>] accessory statuses
      def list_status
        return [] unless @config[:accessories]

        @config[:accessories].map do |name, config|
          service_name = accessory_name(name)
          containers = @docker.list(service: service_name, all: true)
          running = containers.find { |c| c['State'] == 'running' }

          {
            name: name,
            service: service_name,
            image: config[:image],
            running: !running.nil?,
            container_id: running&.dig('ID'),
            has_proxy: !config[:proxy].nil?
          }
        end
      end

      private

      def accessory_name(name)
        "#{@config[:service]}-#{name}"
      end

      def start_accessory(name:, config:)
        service_name = accessory_name(name)

        @docker.run(
          name: service_name,
          image: config[:image],
          options: {
            service: service_name,
            env: build_environment(config[:env]),
            ports: config[:ports],
            volumes: config[:volumes],
            network: 'odysseus',
            restart: 'unless-stopped',
            healthcheck: build_healthcheck(config[:healthcheck]),
            cmd: config[:cmd]
          }
        )
      end

      def build_environment(env_config)
        return {} unless env_config

        env = {}

        # Clear env vars (hardcoded values)
        env_config[:clear]&.each do |key, value|
          env[key.to_s] = value.to_s
        end

        # Secret env vars - first try encrypted file, then server environment
        env_config[:secret]&.each do |key|
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

      def build_healthcheck(hc_config)
        return nil unless hc_config

        {
          cmd: hc_config[:cmd],
          interval: hc_config[:interval] || 30,
          timeout: hc_config[:timeout] || 10,
          retries: hc_config[:retries] || 3
        }
      end

      def add_to_caddy(name:, container_id:, config:)
        container_info = @ssh.execute("docker inspect --format '{{.Name}}' #{container_id}").strip
        container_name = container_info.delete_prefix('/')

        proxy_config = config[:proxy]
        port = proxy_config[:app_port]
        upstream = "#{container_name}:#{port}"

        @caddy.add_upstream(
          service: accessory_name(name),
          hosts: proxy_config[:hosts],
          upstream: upstream,
          ssl: proxy_config[:ssl],
          ssl_email: proxy_config[:ssl_email]
        )
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
