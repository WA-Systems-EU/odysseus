# lib/odysseus/builder/client.rb

require 'open3'
require 'shellwords'

module Odysseus
  module Builder
    class Client
      # A push moves a whole image over SSH, so this is generous -- it exists
      # to end a hang, not to police a slow link.
      PUSSH_TIMEOUT = 1800 # seconds

      # @param config [Hash] builder config from deploy.yml
      # @param ssh_config [Hash] SSH config (user, keys)
      # @param logger [Object] logger
      # @param verbose [Boolean] show commands being executed
      def initialize(config:, ssh_config: {}, logger: nil, verbose: false)
        @config = normalize_config(config)
        @ssh_config = ssh_config
        @logger = logger || default_logger
        @verbose = verbose
      end

      # Build Docker image
      # @param context_path [String] path to build context (directory with Dockerfile)
      # @param image [String] full image name with tag (e.g., "registry/app:v1.0.0")
      # @return [Hash] build result with :success, :image, :strategy
      def build(context_path:, image:)
        @logger.info("Building image: #{image}")

        case strategy
        when :local
          build_local(context_path: context_path, image: image)
        when :remote
          build_remote(context_path: context_path, image: image)
        else
          raise BuildError, "Unknown build strategy: #{strategy}"
        end
      end

      # Build and push to registry
      # @param context_path [String] path to build context
      # @param image [String] full image name with tag
      # @param credentials [Odysseus::Registry::Credentials, nil] the
      #   resolved registry credential -- the same instance the caller uses
      #   for the deploy host's own login, not a config hash read back for
      #   its raw :password key
      # @return [Hash] build and push result
      def build_and_push(context_path:, image:, credentials: nil)
        result = build(context_path: context_path, image: image)
        return result unless result[:success]

        if @config[:push] || credentials
          push_result = push(image: image, credentials: credentials)
          result.merge(pushed: push_result[:success], push_output: push_result[:output])
        else
          result.merge(pushed: false)
        end
      end

      # Push image to registry
      # @param image [String] full image name with tag
      # @param credentials [Odysseus::Registry::Credentials, nil] the
      #   resolved registry credential
      # @return [Hash] push result
      def push(image:, credentials: nil)
        @logger.info("Pushing image to registry: #{image}")

        executor = build_executor

        # #complete? is what Registry::HostSession also gates a login on: a
        # credential with a password but no username raises there (see
        # Registry::Credentials#complete?), and one with no password at all
        # is valid public-image mode, not something to attempt a login with.
        if credentials&.complete?
          login_cmd = build_login_command(credentials)
          executor.call(login_cmd)
        end

        output = executor.call("docker push #{image}")
        { success: true, output: output }
      rescue SSHCommandError, BuildError => e
        @logger.error("Push failed: #{e.message}")
        { success: false, error: e.message }
      end

      # Push image directly to remote host via SSH (using docker pussh/unregistry)
      # @param image [String] full image name with tag
      # @param host [String] target host to push to
      # @param user [String] SSH user (default: from ssh_config)
      # @return [Hash] pussh result
      def pussh(image:, host:, user: nil)
        ssh_user = user || @ssh_config[:user] || 'root'
        target = "#{ssh_user}@#{host}"

        @logger.info("Pushing image via SSH to #{target}: #{image}")

        # docker pussh uses: docker pussh IMAGE [USER@]HOST
        cmd = "docker pussh #{image} #{target}"
        @logger.debug(cmd) if @logger.respond_to?(:debug)

        output = execute_local_command(cmd, timeout: PUSSH_TIMEOUT)
        { success: true, output: output, host: host }
      rescue BuildError => e
        message = push_failure_message(e, host)
        @logger.error("Pussh failed: #{message}")
        { success: false, error: message, host: host }
      end

      # A push that timed out almost never failed because of docker. It failed
      # because the host could not be reached, and the commonest reason here is
      # Tailscale -- which SSH#with_connection already explains for the deploy
      # connection, but `docker pussh` shells out to the system ssh and reaches
      # none of that handling.
      def push_failure_message(error, host)
        return error.message unless error.message.include?('timed out')

        "#{error.message}\n\n" \
          "The push could not reach #{host}. Worth checking:\n  " \
          "1. Tailscale is running: tailscale status\n  " \
          "2. You're authenticated: tailscale login\n  " \
          "3. The host is online: tailscale ping #{host}\n  " \
          "4. SSH works on its own: ssh #{host} true"
      end

      # Push image to multiple hosts via SSH
      # @param image [String] full image name with tag
      # @param hosts [Array<String>] list of target hosts
      # @param user [String] SSH user (default: from ssh_config)
      # @return [Hash] results for each host
      def pussh_to_hosts(image:, hosts:, user: nil)
        results = {}

        hosts.each do |host|
          @logger.info("Pushing to #{host}...")
          results[host] = pussh(image: image, host: host, user: user)
        end

        {
          success: results.values.all? { |r| r[:success] },
          results: results
        }
      end

      # Check if image exists (locally or on build host)
      # @param image [String] full image name with tag
      # @return [Boolean]
      def image_exists?(image)
        executor = build_executor
        output = executor.call("docker images -q #{image} 2>/dev/null || echo ''")
        !output.strip.empty?
      rescue StandardError
        false
      end

      # Get configured build strategy
      # @return [Symbol] :local or :remote
      def strategy
        @config[:strategy]
      end

      # Get configured build host (for remote strategy)
      # @return [String, nil]
      def build_host
        @config[:host]
      end

      private

      def normalize_config(config)
        {
          strategy: (config[:strategy] || config['strategy'] || 'local').to_sym,
          host: config[:host] || config['host'],
          dockerfile: config[:dockerfile] || config['dockerfile'] || 'Dockerfile',
          context: config[:context] || config['context'] || '.',
          arch: config[:arch] || config['arch'],
          platforms: config[:platforms] || config['platforms'] || [],
          build_args: config[:build_args] || config['build_args'] || {},
          cache: if config.key?(:cache)
                   config[:cache]
                 else
                   (config.key?('cache') ? config['cache'] : true)
                 end,
          push: config[:push] || config['push'] || false,
          multiarch: config[:multiarch] || config['multiarch'] || false
        }
      end

      def build_local(context_path:, image:)
        @logger.info('Building locally...')

        cmd = build_docker_command(context_path: context_path, image: image)
        @logger.debug(cmd) if @logger.respond_to?(:debug)

        # For local builds, execute directly
        output = execute_local(cmd, context_path)

        { success: true, image: image, strategy: :local, output: output }
      rescue StandardError => e
        @logger.error("Local build failed: #{e.message}")
        { success: false, strategy: :local, error: e.message }
      end

      def build_remote(context_path:, image:)
        @logger.info("Building on remote host: #{@config[:host]}")

        raise BuildError, "Remote build strategy requires 'host' to be configured" unless @config[:host]

        ssh = connect_to_build_host

        begin
          # Create remote build directory
          remote_dir = "/tmp/odysseus-build-#{Time.now.to_i}"
          ssh.execute("mkdir -p #{remote_dir}")

          # Upload build context
          @logger.info('Uploading build context...')
          ssh.upload(context_path, remote_dir)

          # Determine the actual context directory on remote
          context_name = File.basename(context_path)
          remote_context = "#{remote_dir}/#{context_name}"

          # Build on remote
          cmd = build_docker_command(context_path: remote_context, image: image)
          @logger.debug(cmd) if @logger.respond_to?(:debug)

          output = ssh.execute(cmd)

          # Cleanup remote directory
          ssh.execute("rm -rf #{remote_dir}")

          { success: true, image: image, strategy: :remote, output: output }
        rescue SSHCommandError => e
          @logger.error("Remote build failed: #{e.message}")
          { success: false, strategy: :remote, error: e.message }
        ensure
          ssh.close
        end
      end

      def build_docker_command(context_path:, image:)
        parts = []

        if @config[:multiarch] && @config[:platforms].any?
          # Use buildx for multi-platform builds
          parts << 'docker buildx build'
          parts << "--platform #{@config[:platforms].join(',')}"
          parts << '--push' if @config[:push]
        else
          parts << 'docker build'
          # Single architecture build
          parts << "--platform linux/#{@config[:arch]}" if @config[:arch]
        end

        parts << "-t #{image}"
        parts << "-f #{context_path}/#{@config[:dockerfile]}"
        parts << '--no-cache' unless @config[:cache]

        # Add build args
        @config[:build_args].each do |key, value|
          parts << "--build-arg #{key}=#{value}"
        end

        parts << context_path

        parts.join(' ')
      end

      # Shape matters here as much as content: CommandRedaction::STDIN_PIPE
      # requires `echo '<value>'` (a literal `'` or `"` quote) piped directly
      # into `docker login`/`--password-stdin`, with nothing in between. The
      # password is quoted via Odysseus::ShellQuote rather than interpolated
      # between bare single quotes -- Registry::HostSession solved the same
      # problem (a password containing a `'` otherwise breaks the command)
      # and this reuses that fix instead of a second, divergent one.
      def build_login_command(credentials)
        "echo #{Odysseus::ShellQuote.single_quote(credentials.password)} | docker login " \
          "#{Shellwords.escape(credentials.server)} -u #{Shellwords.escape(credentials.username)} " \
          '--password-stdin'
      end

      def execute_local(cmd, working_dir)
        # Execute command locally using system
        Dir.chdir(working_dir) do
          output = `#{cmd} 2>&1`
          raise BuildError, "Build command failed: #{output}" unless $?.success?

          output
        end
      end

      def build_executor
        case strategy
        when :local
          # Return a proc that executes locally
          ->(cmd) { execute_local_command(cmd) }
        when :remote
          # Return a proc that executes via SSH
          ssh = connect_to_build_host
          ->(cmd) { ssh.execute(cmd) }
        end
      end

      # Runs a local command, streaming its output and refusing to wait forever.
      #
      # This was `` `#{cmd} 2>&1` ``, and all three of its properties were
      # wrong for `docker pussh`. Backticks capture everything into a string,
      # so a push printed nothing until it returned and a healthy one looked
      # exactly like a stuck one. There was no timeout. And stdin stayed
      # attached to the parent, so a child that asked a question waited on an
      # answer that could never be typed into output nobody could see -- the
      # reported symptom was a push that hung with no message at all.
      #
      # stdin is /dev/null so that any prompt reaches EOF and the command fails
      # promptly instead of hanging. Prompting is not something odysseus can
      # usefully do here anyway: SSH#connect is non-interactive for the same
      # reason.
      #
      # @param timeout [Integer, nil] seconds before the command is killed
      # @raise [Odysseus::BuildError] on failure, or on timeout
      def execute_local_command(cmd, timeout: nil)
        output = +''

        # pgroup: true is not optional. Without it the child shares this
        # process's group, and terminate's kill(-pgid) would signal odysseus
        # itself -- which it duly did the first time this was run.
        Open3.popen2e(cmd, pgroup: true) do |stdin, out, wait_thread|
          # Closed immediately, not redirected: popen2e makes its own stdin
          # pipe and ignores an `in:` option. Closing it is what gives a child
          # that asks a question an EOF instead of an indefinite wait.
          stdin.close
          reader = Thread.new do
            out.each_line do |line|
              output << line
              @logger.info(line.chomp)
            end
          rescue IOError
            nil # the stream is closed under us when a timeout kills the child
          end

          unless timeout.nil? || wait_thread.join(timeout)
            terminate(wait_thread.pid)
            reader.join(1)
            raise BuildError, "Command timed out after #{timeout}s: #{cmd}\n#{output}"
          end

          wait_thread.join
          reader.join
          raise BuildError, "Command failed: #{output}" unless wait_thread.value.success?
        end

        output
      end

      # The child is usually a shell, so signal the whole process group -- else
      # `sh -c 'docker pussh ...'` dies and leaves the push running.
      def terminate(pid)
        Process.kill('TERM', -Process.getpgid(pid))
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def connect_to_build_host
        Odysseus::Deployer::SSH.new(
          host: @config[:host],
          user: @ssh_config[:user] || 'root',
          keys: @ssh_config[:keys] || [],
          verbose: @verbose
        )
      end

      def default_logger
        Object.new.tap do |l|
          l.define_singleton_method(:info) { |msg| puts msg }
          l.define_singleton_method(:warn) { |msg| puts "[WARN] #{msg}" }
          l.define_singleton_method(:error) { |msg| puts "[ERROR] #{msg}" }
          l.define_singleton_method(:debug) { |msg| puts "  > #{Odysseus::CommandRedaction.redact(msg)}" if @verbose }
        end
      end
    end
  end
end
