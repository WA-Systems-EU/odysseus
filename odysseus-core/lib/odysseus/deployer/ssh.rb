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
      def initialize(host:, user: 'root', port: 22, keys: [], use_tailscale: true)
        @host = host
        @user = user
        @port = port
        @keys = keys.map { |k| File.expand_path(k) }
        @use_tailscale = use_tailscale
        @session = nil
      end

      # Execute remote command
      # @param command [String] command to execute
      # @return [String] command output
      # @raise [Odysseus::SSHError] if command fails
      def execute(command)
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
      rescue Net::SSH::ConnectionFailed => e
        raise Odysseus::SSHConnectionError, "SSH connection failed: #{e.message}"
      end

      def connect
        @session = Net::SSH.start(
          @host,
          @user,
          port: @port,
          keys: @keys.any? ? @keys : nil,
          password_auth: false,
          verify_host_key: :never # For testing; use :accept_new_or_existing in production
        )
      end
    end
  end
end
