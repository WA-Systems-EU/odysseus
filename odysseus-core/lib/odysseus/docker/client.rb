# lib/odysseus/docker/client.rb

require 'json'
require 'securerandom'
require 'shellwords'

module Odysseus
  module Docker
    class Client
      HEALTHCHECK_POLL_INTERVAL = 2 # seconds

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
        env_file = env_file_path(name, options[:env])
        write_env_file(env_file, options[:env])

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

      # Check if a container exists, running or stopped
      # @param container_id [String] container ID or name
      # @return [Boolean]
      def container_exists?(container_id)
        output = @ssh.execute(
          "docker inspect --format '{{.Id}}' #{container_id} 2>/dev/null || echo ''"
        )
        !output.strip.empty?
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

      # Tags of the images present locally for a repository.
      #
      # docker orders these newest-created first, which is the fallback
      # ordering a rollback uses on a host with no deploy log. Untagged
      # (dangling) images report a tag of '<none>' and are dropped: they cannot
      # be named in a docker run, so they are never rollback targets.
      #
      # @param image [String] repository name, without a tag
      # @return [Array<String>] tags present on this host
      def image_tags(image)
        output = @ssh.execute(
          "docker images #{Shellwords.escape(image)} --format '{{.Tag}}' 2>/dev/null || true"
        )

        output.lines.map(&:strip).reject { |tag| tag.empty? || tag == '<none>' }
      end

      # Remove one image by reference.
      #
      # Lets SSHCommandError through deliberately: docker refuses to remove an
      # image a container still references, and the caller prunes one image at a
      # time so a refusal is a logged skip rather than a failed deploy.
      #
      # @param image [String] repository:tag
      # @return [String] docker's output
      def remove_image(image)
        @ssh.execute("docker image rm #{Shellwords.escape(image)}")
      end

      # The versions any container on this host still references.
      #
      # Includes stopped containers (`all: true`): a stopped container still
      # references its image, whether it stopped from a crash, a reboot, or by
      # hand, and deleting that image would remove something an operator may
      # still need. Used to protect those versions from retention.
      #
      # @param service_labels [Array<String>] odysseus.service values to check
      # @return [Array<String>] distinct odysseus.version labels found
      def versions_in_use(service_labels)
        service_labels.flat_map { |label| list(service: label, all: true) }
                      .filter_map { |container| Odysseus::Docker::Labels.version_of(container) }
                      .uniq
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
      #
      # The environment travels in a 0600 env file, exactly as a deployed
      # container's does: `rails db:migrate` needs the app's DATABASE_URL, and
      # putting it on the command line would show it in the host's process list
      # and break any value containing a space.
      #
      # @param image [String] image to use
      # @param command [String] command to execute, as a shell command line
      # @param options [Hash] container options (env, volumes, network, etc.)
      # @return [String] command output
      def run_once(image:, command:, options: {})
        with_env_file(options[:env]) do |env_file|
          parts = ['docker run --rm']

          # Environment variables (see #write_env_file — never inlined here)
          parts << "--env-file #{Shellwords.escape(env_file)}" if env_file

          # Volume mounts
          options[:volumes]&.each { |v| parts << "-v #{v}" }

          # Network
          parts << "--network #{options[:network]}" if options[:network]

          # Interactive/TTY
          parts << '-i' if options[:interactive]
          parts << '-t' if options[:tty]

          parts << Shellwords.escape(image)
          # Not escaped: the command is a command line, and `rake db:migrate`
          # has to reach docker as two arguments. build_run_command treats
          # options[:cmd] the same way.
          parts << command

          @ssh.execute(parts.join(' '))
        end
      end

      # Hold an env file open on the host for the duration of a block.
      #
      # For runs Odysseus does not execute itself: `app shell` and `app console`
      # need an interactive TTY, so the CLI builds its own `ssh -t ... docker
      # run` and passes the yielded path as --env-file. The file goes away
      # afterwards whether the block returned or raised, and remove_env_file
      # never masks the block's own failure.
      #
      # Yields nil, having written nothing, when there is no environment, so
      # the caller has one code path either way.
      #
      # @param env [Hash, nil] environment variables
      # @yieldparam path [String, nil] path to the env file on the host
      # @return [Object] whatever the block returned
      def with_env_file(env)
        path = env_file_path(one_off_env_name, env)
        write_env_file(path, env)
        yield path
      ensure
        remove_env_file(path)
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

      # Where this connection's env files go. Derived rather than constant
      # because a deploy user cannot write — or chmod — the system directory.
      def host_paths
        @host_paths ||= Odysseus::HostPaths.new(@ssh)
      end

      # Where a container's env file goes, or nil when there is nothing to
      # write. Settled before the write rather than returned by it: scp creates
      # the remote file and then streams into it, so an upload that dies partway
      # has already left part of a file of secrets on the host, and a caller
      # that learned the path from the write's return value has nothing to
      # remove — the file stays under a name nobody is going to look for.
      #
      # @return [String, nil] path to the env file, nil when there is nothing to write
      def env_file_path(name, env)
        return nil if env.nil? || env.empty?

        "#{host_paths.env_dir}/#{name}.env"
      end

      # Write the container's environment to a private file on the host.
      #
      # The directory is made 0700 before anything is written into it. The file
      # itself is uploaded 0600, so this is a second guard rather than the only
      # one — but it is the guard that has to hold for a file left behind by a
      # session that died, and `mkdir -p` on its own leaves the directory 0755.
      def write_env_file(path, env)
        return unless path

        dir = host_paths.env_dir
        @ssh.execute("mkdir -p #{Shellwords.escape(dir)} && chmod 700 #{Shellwords.escape(dir)}")
        @ssh.upload_string(format_env_file(env), path, mode: 0o600)
      end

      # The name a one-off run's env file is written under.
      #
      # write_env_file names the file after the container, and a one-off has no
      # container name. '@' is not a character Docker allows in one
      # ([a-zA-Z0-9][a-zA-Z0-9_.-]*), so no deployed container's env file can
      # ever live at this path — overwriting a running container's env file, or
      # deleting it on the way out, would be a live incident. The random suffix
      # keeps two one-off runs on the same host from sharing a file.
      def one_off_env_name
        "one-off@#{SecureRandom.hex(8)}"
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

      # Remove the env file, reconnecting once if the connection it was written
      # over has died in the meantime.
      #
      # This runs from an ensure, and on the interactive paths the connection
      # has been held open — idle, and with nothing pumping it — for as long as
      # the user's session lasted. An idle NAT or firewall timeout, sshd's
      # ClientAlive limit or a Tailscale relay change all leave it dead by the
      # time the session ends, and a dead connection raises IOError,
      # Net::SSH::Disconnect, Errno::EPIPE or Errno::ECONNRESET — none of them
      # an Odysseus::SSHError, which is all this used to rescue. The cleanup's
      # own failure then escaped the ensure and replaced whatever the block was
      # already raising, so `app shell`'s exit status arrived as a backtrace.
      #
      # Closing the session is what makes the second attempt a new one: SSH
      # connects lazily and only when it has no live session. If that fails too
      # the file is left behind — 0600 in a 0700 directory — and nothing is
      # raised: the caller came for the block's outcome, not this one's.
      def remove_env_file(path)
        return unless path

        @ssh.execute("rm -f #{Shellwords.escape(path)}")
      rescue StandardError
        remove_env_file_on_a_new_connection(path)
      end

      def remove_env_file_on_a_new_connection(path)
        @ssh.close
        @ssh.execute("rm -f #{Shellwords.escape(path)}")
      rescue StandardError
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
        parts << "--env-file #{Shellwords.escape(env_file)}" if env_file

        # Memory limits
        parts << "--memory #{options[:memory]}" if options[:memory]
        parts << "--memory-reservation #{options[:memory_reservation]}" if options[:memory_reservation]

        # CPU limits
        parts << "--cpus #{options[:cpus]}" if options[:cpus]
        parts << "--cpu-shares #{options[:cpu_shares]}" if options[:cpu_shares]

        # Health check (use image's HEALTHCHECK by default)
        if options[:healthcheck]
          hc = options[:healthcheck]
          # Escaped, not hand-quoted. A cmd containing a single quote --
          # `--execute='SELECT 1'`, which is how you write a one-shot query
          # for most database clients -- closed the quote early, and the
          # remainder word-split into docker's argument list: the tail landed
          # where the image name goes, and docker reported it could not find
          # the image '1:latest'. Shellwords makes it one word whatever it
          # contains; docker runs it through a shell at the other end, so the
          # inner quoting still means what it says.
          parts << "--health-cmd #{Shellwords.escape(hc[:cmd])}" if hc[:cmd]
          parts << "--health-interval #{hc[:interval]}s" if hc[:interval]
          parts << "--health-timeout #{hc[:timeout]}s" if hc[:timeout]
          parts << "--health-retries #{hc[:retries]}" if hc[:retries]
        end

        # Network
        parts << "--network #{options[:network]}" if options[:network]

        # Volume mounts. Escaped for the same reason as the healthcheck above:
        # a host path with a space in it is otherwise two arguments.
        options[:volumes]&.each { |v| parts << "-v #{Shellwords.escape(v)}" }

        # Restart policy
        parts << "--restart #{options[:restart] || 'unless-stopped'}"

        # Image
        parts << image

        # Command (if provided). Deliberately NOT escaped, unlike everything
        # above: `start-single-node --insecure` has to reach the container as
        # three arguments, and escaping it would hand docker one literal
        # string containing spaces. Do not "fix" this to match its neighbours.
        parts << options[:cmd] if options[:cmd]

        parts.join(' ')
      end
    end
  end
end
