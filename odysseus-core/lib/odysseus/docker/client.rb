# lib/odysseus/docker/client.rb

require 'json'
require 'shellwords'

module Odysseus
  module Docker
    class Client
      HEALTHCHECK_POLL_INTERVAL = 2 # seconds

      # Env files are written here just long enough for docker run to read them.
      ENV_FILE_DIR = '/var/lib/odysseus/env'.freeze

      # @param ssh [Odysseus::Deployer::SSH] SSH connection to server
      def initialize(ssh)
        @ssh = ssh
      end

      # Run a new container
      #
      # Environment variables travel in a 0600 env file rather than on the
      # command line, so secrets stay out of the host's process list and values
      # containing spaces or shell metacharacters survive intact. Docker copies
      # them into the container config at create time, so the file is removed
      # again as soon as the container exists.
      #
      # @param name [String] container name
      # @param image [String] image:tag
      # @param options [Hash] container options
      # @return [String] container ID
      def run(name:, image:, options: {})
        env_file = write_env_file(name, options[:env])

        cmd = build_run_command(name: name, image: image, options: options, env_file: env_file)
        output = @ssh.execute(cmd)
        # Container ID is the last line (64-char hex), ignore any warnings
        lines = output.strip.split("\n")
        container_id = lines.last&.strip

        # Validate it looks like a container ID
        raise Odysseus::DeployError, "Failed to start container: #{output}" unless container_id&.match?(/\A[a-f0-9]{64}\z/)

        container_id
      ensure
        remove_env_file(env_file)
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
        attempts = [timeout / HEALTHCHECK_POLL_INTERVAL, 1].max

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
      def logs(container_id, follow: false, tail: 100, since: nil, timestamps: false, &)
        parts = ['docker logs']
        parts << '--follow' if follow
        parts << "--tail #{tail}" if tail
        parts << "--since #{since}" if since
        parts << '--timestamps' if timestamps
        parts << container_id

        cmd = parts.join(' ')

        if block_given?
          @ssh.stream(cmd, &)
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

      # Check if a Docker named volume exists
      # @param name [String] volume name
      # @return [Boolean]
      def volume_exists?(name)
        output = @ssh.execute("docker volume inspect #{name} 2>/dev/null && echo 'yes' || echo 'no'")
        output.strip.end_with?('yes')
      end

      # Ensure a Docker network exists, creating it if missing
      # @param name [String] network name
      # @param labels [Hash] labels to apply when creating
      def ensure_network(name, labels: {})
        label_flags = labels.map { |k, v| "--label #{k}=#{v}" }.join(' ')
        @ssh.execute("docker network inspect #{name} >/dev/null 2>&1 || docker network create #{label_flags} #{name}".strip)
      end

      # Get disk usage info
      # @return [String] docker system df output
      def disk_usage
        @ssh.execute('docker system df')
      end

      private

      # Write the container's environment to a private file on the host.
      # @return [String, nil] path to the env file, nil when there is nothing to write
      def write_env_file(name, env)
        return nil if env.nil? || env.empty?

        path = "#{ENV_FILE_DIR}/#{name}.env"
        @ssh.execute("mkdir -p #{ENV_FILE_DIR} && chmod 700 #{ENV_FILE_DIR}")
        @ssh.upload_string(format_env_file(env), path, mode: 0o600)
        path
      end

      # docker --env-file takes one KEY=VALUE per line and cannot represent a
      # value containing a newline, so refuse rather than truncate a secret.
      def format_env_file(env)
        lines = env.map do |key, value|
          value = value.to_s
          if value.include?("\n")
            raise Odysseus::DeployError,
                  "Environment variable #{key} contains a newline, which a Docker env file cannot represent"
          end

          "#{key}=#{value}"
        end

        "#{lines.join("\n")}\n"
      end

      def remove_env_file(path)
        return unless path

        @ssh.execute("rm -f #{path}")
      rescue Odysseus::SSHError
        # Best effort: the file is only readable by its owner and is rewritten
        # on the next deploy. Never mask the deploy's own failure.
        nil
      end

      def build_run_command(name:, image:, options:, env_file: nil)
        parts = ['docker run -d']

        # Container name
        parts << "--name #{name}"

        # Labels for tracking. Values are quoted: they carry refs and timestamps
        # supplied by the app's repository, not just internal identifiers.
        parts << "--label #{Shellwords.escape("odysseus.service=#{options[:service] || name}")}"
        parts << "--label #{Shellwords.escape("odysseus.version=#{options[:version]}")}" if options[:version]

        # Additional custom labels
        options[:labels]&.each do |key, value|
          parts << "--label #{Shellwords.escape("#{key}=#{value}")}"
        end

        # Port mappings
        options[:ports]&.each { |p| parts << "-p #{p}" }

        # Environment variables (see #write_env_file — never inlined here)
        parts << "--env-file #{env_file}" if env_file

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
        options[:volumes]&.each { |v| parts << "-v #{v}" }

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
