# lib/odysseus/orchestrator/job_deploy.rb

module Odysseus
  module Orchestrator
    class JobDeploy
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
      end

      # Execute deploy for a job/worker service
      # @param image_tag [String] image tag to deploy
      # @param role [Symbol] server role (e.g., :jobs, :worker)
      # @return [Hash] deploy result
      def deploy(image_tag:, role:)
        service = @config[:service]
        role_name = "#{service}-#{role}"
        image = "#{@config[:image]}:#{image_tag}"

        log "Starting deploy of #{role_name} with #{image}"

        # Step 1: Find existing containers for this role
        log "Checking for existing containers..."
        old_containers = @docker.list(service: role_name)
        log "Found #{old_containers.size} existing container(s)"

        # Step 2: Start new container
        log "Starting new container..."
        new_container_id = start_new_container(image: image, role: role)
        log "Started container: #{new_container_id[0..11]}"

        # Step 3: Wait for healthy (if healthcheck configured)
        server_config = @config[:servers][role] || {}
        if server_config[:healthcheck]
          log "Waiting for container to be healthy..."
          unless wait_for_healthy(new_container_id)
            handle_failed_deploy(new_container_id)
            raise Odysseus::DeployError, "Container failed health checks"
          end
          log "Container is healthy!"
        else
          # No healthcheck - just wait a few seconds for startup
          log "No healthcheck configured, waiting for startup..."
          sleep 5
          unless @docker.running?(new_container_id)
            handle_failed_deploy(new_container_id)
            raise Odysseus::DeployError, "Container failed to start"
          end
        end

        # Step 4: Stop old containers gracefully
        old_containers.each do |old|
          log "Stopping old container: #{old['ID'][0..11]}..."
          graceful_stop(old['ID'])
        end

        # Step 5: Cleanup old stopped containers
        log "Cleaning up old containers..."
        @docker.cleanup_old_containers(service: role_name, keep: 2)

        {
          success: true,
          container_id: new_container_id,
          service: role_name,
          image: image
        }
      rescue StandardError => e
        log "Deploy failed: #{e.message}", :error
        raise
      end

      private

      def start_new_container(image:, role:)
        service = @config[:service]
        role_name = "#{service}-#{role}"
        timestamp = Time.now.strftime('%Y%m%d%H%M%S')
        container_name = "#{role_name}-#{timestamp}"

        server_config = @config[:servers][role] || {}
        options = server_config[:options] || {}

        @docker.run(
          name: container_name,
          image: image,
          options: {
            service: role_name,
            version: timestamp,
            env: build_environment,
            memory: options[:memory],
            memory_reservation: options[:memory_reservation],
            cpus: options[:cpus],
            cpu_shares: options[:cpu_shares],
            network: 'odysseus',
            healthcheck: build_healthcheck(server_config[:healthcheck]),
            cmd: server_config[:cmd]
          }
        )
      end

      def build_environment
        env = {}

        # Clear env vars (hardcoded values)
        @config[:env][:clear]&.each do |key, value|
          env[key.to_s] = value.to_s
        end

        # Secret env vars (from encrypted file or server environment)
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

      def build_healthcheck(hc_config)
        return nil unless hc_config

        {
          cmd: hc_config[:cmd],
          interval: hc_config[:interval] || 30,
          timeout: hc_config[:timeout] || 10,
          retries: hc_config[:retries] || 3
        }
      end

      def wait_for_healthy(container_id, timeout: 120)
        @docker.wait_healthy(container_id, timeout: timeout)
      end

      def graceful_stop(container_id)
        # Give workers time to finish current job (30 second timeout)
        @docker.stop(container_id, timeout: 30)
        @docker.remove(container_id)
      end

      def handle_failed_deploy(new_container_id)
        log "Rolling back failed deploy...", :warn
        @docker.stop(new_container_id)
        @docker.remove(new_container_id, force: true)
        log "Rollback complete"
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
