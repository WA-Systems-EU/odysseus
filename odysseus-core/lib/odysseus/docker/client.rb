# lib/odysseus/docker/client.rb

require 'json'

module Odysseus
  module Docker
    class Client
      HEALTHCHECK_POLL_INTERVAL = 2 # seconds
      HEALTHCHECK_MAX_ATTEMPTS = 30 # ~60 seconds max wait

      # @param ssh [Odysseus::Deployer::SSH] SSH connection to server
      def initialize(ssh)
        @ssh = ssh
      end

      # Run a new container
      # @param name [String] container name
      # @param image [String] image:tag
      # @param options [Hash] container options
      # @return [String] container ID
      def run(name:, image:, options: {})
        cmd = build_run_command(name: name, image: image, options: options)
        output = @ssh.execute(cmd)
        # Container ID is the last line (64-char hex), ignore any warnings
        lines = output.strip.split("\n")
        container_id = lines.last&.strip

        # Validate it looks like a container ID
        unless container_id&.match?(/\A[a-f0-9]{64}\z/)
          raise Odysseus::DeployError, "Failed to start container: #{output}"
        end

        container_id
      end

      # Stop a container
      # @param container_id [String] container ID or name
      # @param timeout [Integer] seconds to wait before killing
      def stop(container_id, timeout: 10)
        @ssh.execute("docker stop --time #{timeout} #{container_id}")
      end

      # Remove a container
      # @param container_id [String] container ID or name
      # @param force [Boolean] force remove running container
      def remove(container_id, force: false)
        force_flag = force ? '-f' : ''
        @ssh.execute("docker rm #{force_flag} #{container_id}".strip)
      end

      # List containers for a service
      # @param service [String] service name (label filter)
      # @param all [Boolean] include stopped containers
      # @return [Array<Hash>] container info
      def list(service:, all: false)
        all_flag = all ? '-a' : ''
        format = '{{json .}}'
        output = @ssh.execute(
          "docker ps #{all_flag} --filter label=odysseus.service=#{service} --format '#{format}'"
        )

        output.lines.map { |line| JSON.parse(line.strip) }
      end

      # Get container health status
      # @param container_id [String] container ID or name
      # @return [String] health status (healthy, unhealthy, starting, none)
      def health_status(container_id)
        output = @ssh.execute(
          "docker inspect --format '{{.State.Health.Status}}' #{container_id} 2>/dev/null || echo 'none'"
        )
        output.strip
      end

      # Wait for container to become healthy
      # @param container_id [String] container ID or name
      # @param timeout [Integer] max seconds to wait
      # @return [Boolean] true if healthy, false if timeout
      def wait_healthy(container_id, timeout: 60)
        attempts = [timeout / HEALTHCHECK_POLL_INTERVAL, HEALTHCHECK_MAX_ATTEMPTS].min

        attempts.times do
          status = health_status(container_id)
          return true if status == 'healthy'
          return false if status == 'unhealthy'

          sleep HEALTHCHECK_POLL_INTERVAL
        end

        false
      end

      # Check if container is running
      # @param container_id [String] container ID or name
      # @return [Boolean]
      def running?(container_id)
        output = @ssh.execute(
          "docker inspect --format '{{.State.Running}}' #{container_id} 2>/dev/null || echo 'false'"
        )
        output.strip == 'true'
      end

      # Get container IP address
      # @param container_id [String] container ID or name
      # @param network [String] network name (default: bridge)
      # @return [String, nil] IP address or nil
      def container_ip(container_id, network: 'bridge')
        output = @ssh.execute(
          "docker inspect --format '{{.NetworkSettings.Networks.#{network}.IPAddress}}' #{container_id} 2>/dev/null || echo ''"
        )
        ip = output.strip
        ip.empty? ? nil : ip
      end

      # Pull an image
      # @param image [String] image:tag
      def pull(image)
        @ssh.execute("docker pull #{image}")
      end

      # Check if image exists locally
      # @param image [String] image:tag
      # @return [Boolean]
      def image_exists?(image)
        output = @ssh.execute("docker images -q #{image} 2>/dev/null || echo ''")
        !output.strip.empty?
      end

      # Get logs from a container
      # @param container_id [String] container ID or name
      # @param follow [Boolean] follow log output (streaming)
      # @param tail [Integer, String] number of lines to show from end, or 'all'
      # @param since [String] show logs since timestamp (e.g., '10m', '2h', '2024-01-01')
      # @param timestamps [Boolean] show timestamps
      # @return [String] log output (or yields lines if block given)
      def logs(container_id, follow: false, tail: 100, since: nil, timestamps: false, &block)
        parts = ['docker logs']
        parts << '--follow' if follow
        parts << "--tail #{tail}" if tail
        parts << "--since #{since}" if since
        parts << '--timestamps' if timestamps
        parts << container_id

        cmd = parts.join(' ')

        if block_given?
          @ssh.stream(cmd, &block)
        else
          @ssh.execute(cmd)
        end
      end

      # Execute a command in a running container
      # @param container_id [String] container ID or name
      # @param command [String] command to execute
      # @param interactive [Boolean] keep STDIN open
      # @param tty [Boolean] allocate a TTY
      # @return [String] command output
      def exec(container_id, command, interactive: false, tty: false)
        parts = ['docker exec']
        parts << '-i' if interactive
        parts << '-t' if tty
        parts << container_id
        parts << command

        @ssh.execute(parts.join(' '))
      end

      # Run a one-off command in a new container (doesn't persist)
      # @param image [String] image to use
      # @param command [String] command to execute
      # @param options [Hash] container options (env, volumes, network, etc.)
      # @return [String] command output
      def run_once(image:, command:, options: {})
        parts = ['docker run --rm']

        # Environment variables
        options[:env]&.each do |key, value|
          parts << "-e #{key}=#{value}"
        end

        # Volume mounts
        options[:volumes]&.each { |v| parts << "-v #{v}" }

        # Network
        parts << "--network #{options[:network]}" if options[:network]

        # Interactive/TTY
        parts << '-i' if options[:interactive]
        parts << '-t' if options[:tty]

        parts << image
        parts << command

        @ssh.execute(parts.join(' '))
      end

      # Cleanup old stopped containers, keeping only the last N
      # @param service [String] service name
      # @param keep [Integer] number of stopped containers to keep
      # @return [Array<String>] IDs of removed containers
      def cleanup_old_containers(service:, keep: 2)
        stopped = list(service: service, all: true).select do |c|
          c['State'] == 'exited'
        end

        # Sort by created time (newest first) and remove old ones
        sorted = stopped.sort_by { |c| c['CreatedAt'] }.reverse
        to_remove = sorted.drop(keep)

        to_remove.each do |container|
          remove(container['ID'])
        end

        to_remove.map { |c| c['ID'] }
      end

      # Prune unused Docker resources (excludes odysseus-managed resources)
      # @param containers [Boolean] remove stopped containers (excludes odysseus-caddy)
      # @param images [Boolean] remove dangling images
      # @param volumes [Boolean] remove unused volumes (DANGEROUS - data loss!)
      # @param networks [Boolean] remove unused networks (excludes odysseus network)
      # @return [Hash] prune results
      def prune(containers: true, images: true, volumes: false, networks: false)
        results = {}

        if containers
          # Prune containers but exclude odysseus-caddy
          # Use filter to exclude containers with odysseus label
          output = @ssh.execute(
            'docker container prune -f --filter "label!=odysseus.managed=true" 2>&1'
          )
          results[:containers] = output
        end

        if images
          output = @ssh.execute('docker image prune -f 2>&1')
          results[:images] = output
        end

        if volumes
          output = @ssh.execute('docker volume prune -f 2>&1')
          results[:volumes] = output
        end

        if networks
          # Prune networks but exclude odysseus network
          output = @ssh.execute(
            'docker network prune -f --filter "label!=odysseus.managed=true" 2>&1'
          )
          results[:networks] = output
        end

        results
      end

      # Get disk usage info
      # @return [String] docker system df output
      def disk_usage
        @ssh.execute('docker system df')
      end

      private

      def build_run_command(name:, image:, options:)
        parts = ['docker run -d']

        # Container name
        parts << "--name #{name}"

        # Labels for tracking
        parts << "--label odysseus.service=#{options[:service] || name}"
        parts << "--label odysseus.version=#{options[:version]}" if options[:version]

        # Additional custom labels
        if options[:labels]
          options[:labels].each do |key, value|
            parts << "--label #{key}=#{value}"
          end
        end

        # Port mappings
        if options[:ports]
          options[:ports].each { |p| parts << "-p #{p}" }
        end

        # Environment variables
        if options[:env]
          options[:env].each do |key, value|
            # Don't log secret values
            parts << "-e #{key}=#{value}"
          end
        end

        # Memory limits
        parts << "--memory #{options[:memory]}" if options[:memory]
        parts << "--memory-reservation #{options[:memory_reservation]}" if options[:memory_reservation]

        # CPU limits
        parts << "--cpus #{options[:cpus]}" if options[:cpus]
        parts << "--cpu-shares #{options[:cpu_shares]}" if options[:cpu_shares]

        # Health check (use image's HEALTHCHECK by default)
        if options[:healthcheck]
          hc = options[:healthcheck]
          parts << "--health-cmd '#{hc[:cmd]}'" if hc[:cmd]
          parts << "--health-interval #{hc[:interval]}s" if hc[:interval]
          parts << "--health-timeout #{hc[:timeout]}s" if hc[:timeout]
          parts << "--health-retries #{hc[:retries]}" if hc[:retries]
        end

        # Network
        parts << "--network #{options[:network]}" if options[:network]

        # Volume mounts
        if options[:volumes]
          options[:volumes].each { |v| parts << "-v #{v}" }
        end

        # Restart policy
        parts << "--restart #{options[:restart] || 'unless-stopped'}"

        # Image
        parts << image

        # Command (if provided)
        parts << options[:cmd] if options[:cmd]

        parts.join(' ')
      end
    end
  end
end
