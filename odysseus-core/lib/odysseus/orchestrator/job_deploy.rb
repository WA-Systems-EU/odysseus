# lib/odysseus/orchestrator/job_deploy.rb

require_relative '../core/volume_namespacer'

module Odysseus
  module Orchestrator
    class JobDeploy
      include Odysseus::Core::VolumeNamespacer
      include Odysseus::Core::DeployVersioning

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

        log "Deploying #{role_name}"
        log "  Image: #{image}"

        server_config = @config[:servers][role] || {}
        log "  Command: #{server_config[:cmd]}" if server_config[:cmd]

        # Step 1: Find existing containers for this role
        old_containers = @docker.list(service: role_name)
        log "  Found #{old_containers.size} existing container(s)"

        # Step 2: Start new container
        log 'Starting new container...'
        new_container_id = start_new_container(image: image, role: role)
        log "  Container started: #{new_container_id[0..11]}"

        # Step 3: Wait for healthy (if healthcheck configured)
        if server_config[:healthcheck]
          hc = server_config[:healthcheck]
          log "Waiting for health check... (cmd: #{hc[:cmd]}, interval: #{hc[:interval]}s)"
          unless wait_for_healthy(new_container_id)
            log_health_failure(new_container_id)
            handle_failed_deploy(new_container_id)
            raise Odysseus::DeployError, 'Container failed health checks'
          end
          log '  Health check passed'
        else
          log 'No health check configured, waiting 5s for startup...'
          sleep 5
          unless @docker.running?(new_container_id)
            log_health_failure(new_container_id)
            handle_failed_deploy(new_container_id)
            raise Odysseus::DeployError, 'Container failed to start'
          end
          log '  Container is running'
        end

        # Step 4: Stop old containers gracefully
        old_containers.each do |old|
          log "Stopping old container #{old['ID'][0..11]} (30s grace period)..."
          graceful_stop(old['ID'])
          log '  Old container removed'
        end

        # Step 5: Cleanup old stopped containers
        cleaned = @docker.cleanup_old_containers(service: role_name, keep: 2)
        log "  Cleaned up #{cleaned.size} old container(s)" if cleaned.any?

        log "Deploy complete for #{role_name}"

        {
          success: true,
          container_id: new_container_id,
          service: role_name,
          image: image
        }
      rescue StandardError => e
        log "Deploy FAILED: #{e.message}", :error
        raise
      end

      private

      def start_new_container(image:, role:)
        service = @config[:service]
        role_name = "#{service}-#{role}"
        timestamp = Time.now.utc.strftime('%Y%m%d%H%M%S')
        container_name = "#{role_name}-#{deploy_version_tag(image)}-#{timestamp}"

        server_config = @config[:servers][role] || {}
        options = server_config[:options] || {}

        # A jobs-only deploy may be the first thing ever run on this host, so
        # the network can't be assumed to exist (a web role gets it as a side
        # effect of ensure_caddy!, and DependencyDeploy has its own copy).
        ensure_network!

        env = build_environment
        log "  Environment: #{env.size} variable(s) injected"

        volumes = namespace_volumes(server_config[:volumes], service: role_name)
        log "  Volumes: #{volumes.join(', ')}" if volumes&.any?

        if options[:memory] || options[:cpus]
          log "  Resources: memory=#{options[:memory] || 'default'}, cpus=#{options[:cpus] || 'default'}"
        end

        @docker.run(
          name: container_name,
          image: image,
          options: {
            service: role_name,
            version: deploy_version_tag(image),
            labels: version_labels,
            env: env,
            volumes: volumes,
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

      def ensure_network!
        log 'Ensuring Docker network exists...'
        @docker.ensure_network('odysseus', labels: { 'odysseus.managed' => 'true' })
      end

      # Same environment a web container gets — see Core::Environment.
      def build_environment
        Odysseus::Core::Environment.new(config: @config, secrets_loader: @secrets_loader, ssh: @ssh).build
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
        log 'Rolling back failed deploy...', :warn
        @docker.stop(new_container_id)
        @docker.remove(new_container_id, force: true)
        log 'Rollback complete — failed container removed'
      end

      def log_health_failure(container_id)
        log "Health check FAILED for container #{container_id[0..11]}", :error

        begin
          recent_logs = @docker.logs(container_id, tail: 30)
          unless recent_logs.strip.empty?
            log '  Container logs (last 30 lines):', :error
            recent_logs.each_line { |line| log "    #{line.rstrip}", :error }
          end
        rescue StandardError => e
          log "  Could not fetch container logs: #{e.message}", :warn
        end

        begin
          status = @docker.health_status(container_id)
          log "  Health status: #{status}", :error
        rescue StandardError
          # ignore
        end
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
