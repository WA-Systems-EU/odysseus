# lib/odysseus/deployer/ssh.rb

require 'net/ssh'
require 'net/scp'

module Odysseus
  module Deployer
    class SSH
      # @param host [String] hostname or IP
      # @param user [String] SSH username (default: root)
      # @param port [Integer] SSH port (default: 22)
      # @param keys [Array<String>] SSH key paths
      # @param use_tailscale [Boolean] if true, assume Tailscale hostname
      # @param verbose [Boolean] log commands being executed
      def initialize(host:, user: 'root', port: 22, keys: [], use_tailscale: true, verbose: false)
        @host = host
        @user = user
        @port = port
        @keys = keys.map { |k| File.expand_path(k) }
        @use_tailscale = use_tailscale
        @verbose = verbose
        @session = nil
      end

      # Execute remote command
      # @param command [String] command to execute
      # @return [String] command output
      # @raise [Odysseus::SSHError] if command fails
      def execute(command)
        puts "  > #{command}" if @verbose
        with_connection do |session|
          output = ""
          session.open_channel do |channel|
            channel.exec(command) do |ch, success|
              raise Odysseus::SSHCommandError, "Failed to execute: #{command}" unless success

              channel.on_data { |_, data| output += data }
              channel.on_extended_data { |_, _, data| output += data }
            end
          end
          session.loop
          output
        end
      end

      # Upload file to remote server
      # @param local_path [String] local file path
      # @param remote_path [String] remote file path
      def upload(local_path, remote_path)
        with_connection do |session|
          session.scp.upload!(local_path, remote_path, recursive: true)
        end
      end

      # Download file from remote server
      # @param remote_path [String] remote file path
      # @param local_path [String] local file path
      def download(remote_path, local_path)
        with_connection do |session|
          session.scp.download!(remote_path, local_path, recursive: true)
        end
      end

      # Upload string content to remote file
      # @param content [String] content to write
      # @param remote_path [String] remote file path
      def upload_string(content, remote_path)
        with_connection do |session|
          session.scp.upload!(StringIO.new(content), remote_path)
        end
      end

      # Stream command output (for long-running commands like logs --follow)
      # @param command [String] command to execute
      # @yield [String] yields each line of output
      def stream(command, &block)
        with_connection do |session|
          session.open_channel do |channel|
            channel.exec(command) do |ch, success|
              raise Odysseus::SSHCommandError, "Failed to execute: #{command}" unless success

              channel.on_data do |_, data|
                data.each_line { |line| block.call(line) }
              end

              channel.on_extended_data do |_, _, data|
                data.each_line { |line| block.call(line) }
              end
            end
          end
          session.loop
        end
      end

      # Check if connected
      # @return [Boolean]
      def connected?
        @session&.closed? == false
      end

      # Close connection
      def close
        @session&.close
      end

      private

      def with_connection
        connect unless connected?
        yield(@session)
      rescue Errno::ECONNREFUSED => e
        raise Odysseus::SSHConnectionError, "Connection refused to #{@host}. Is the server running and accepting SSH connections?"
      rescue SocketError => e
        raise Odysseus::SSHConnectionError, "Could not resolve hostname '#{@host}'. Check your DNS or /etc/hosts."
      rescue Net::SSH::AuthenticationFailed => e
        raise Odysseus::SSHConnectionError, "SSH authentication failed for #{@user}@#{@host}. Check your SSH keys."
      rescue Errno::ETIMEDOUT, Net::SSH::ConnectionTimeout, Errno::EHOSTUNREACH => e
        error_msg = "Connection to #{@host} timed out."
        if @use_tailscale
          error_msg += "\n\nThis looks like a Tailscale hostname. Please check:\n"
          error_msg += "  1. Tailscale is running: tailscale status\n"
          error_msg += "  2. You're authenticated: tailscale login\n"
          error_msg += "  3. The host is online: tailscale ping #{@host}"
        end
        raise Odysseus::SSHConnectionError, error_msg
      end

      def connect
        puts "Connecting to #{@user}@#{@host}:#{@port}..." if @verbose
        options = {
          port: @port,
          non_interactive: true,
          verify_host_key: :never,
          timeout: 10  # Connection timeout in seconds
        }
        options[:keys] = @keys if @keys.any?

        @session = Net::SSH.start(@host, @user, options)
        puts "Connected to #{@host}" if @verbose
      end
    end
  end
end
