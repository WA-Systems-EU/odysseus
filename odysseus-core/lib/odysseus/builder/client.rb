# lib/odysseus/builder/client.rb

module Odysseus
  module Builder
    class Client
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
      # @param registry [Hash] registry config (server, username, password)
      # @return [Hash] build and push result
      def build_and_push(context_path:, image:, registry: nil)
        result = build(context_path: context_path, image: image)
        return result unless result[:success]

        if @config[:push] || registry
          push_result = push(image: image, registry: registry)
          result.merge(pushed: push_result[:success], push_output: push_result[:output])
        else
          result.merge(pushed: false)
        end
      end

      # Push image to registry
      # @param image [String] full image name with tag
      # @param registry [Hash] registry config (server, username, password)
      # @return [Hash] push result
      def push(image:, registry: nil)
        @logger.info("Pushing image to registry: #{image}")

        executor = build_executor

        # Login if credentials provided
        if registry && registry[:username]
          login_cmd = build_login_command(registry)
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

        output = execute_local_command(cmd)
        { success: true, output: output, host: host }
      rescue BuildError => e
        @logger.error("Pussh failed: #{e.message}")
        { success: false, error: e.message, host: host }
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
      rescue
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
          cache: config.key?(:cache) ? config[:cache] : (config.key?('cache') ? config['cache'] : true),
          push: config[:push] || config['push'] || false,
          multiarch: config[:multiarch] || config['multiarch'] || false
        }
      end

      def build_local(context_path:, image:)
        @logger.info("Building locally...")

        cmd = build_docker_command(context_path: context_path, image: image)
        @logger.debug(cmd) if @logger.respond_to?(:debug)

        # For local builds, execute directly
        output = execute_local(cmd, context_path)

        { success: true, image: image, strategy: :local, output: output }
      rescue => e
        @logger.error("Local build failed: #{e.message}")
        { success: false, strategy: :local, error: e.message }
      end

      def build_remote(context_path:, image:)
        @logger.info("Building on remote host: #{@config[:host]}")

        unless @config[:host]
          raise BuildError, "Remote build strategy requires 'host' to be configured"
        end

        ssh = connect_to_build_host

        begin
          # Create remote build directory
          remote_dir = "/tmp/odysseus-build-#{Time.now.to_i}"
          ssh.execute("mkdir -p #{remote_dir}")

          # Upload build context
          @logger.info("Uploading build context...")
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

      def build_login_command(registry)
        server = registry[:server] || ''
        "echo '#{registry[:password]}' | docker login #{server} -u #{registry[:username]} --password-stdin"
      end

      def execute_local(cmd, working_dir)
        # Execute command locally using system
        Dir.chdir(working_dir) do
          output = `#{cmd} 2>&1`
          unless $?.success?
            raise BuildError, "Build command failed: #{output}"
          end
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

      def execute_local_command(cmd)
        output = `#{cmd} 2>&1`
        unless $?.success?
          raise BuildError, "Command failed: #{output}"
        end
        output
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
          l.define_singleton_method(:debug) { |msg| puts "  > #{msg}" if @verbose }
        end
      end
    end
  end
end
