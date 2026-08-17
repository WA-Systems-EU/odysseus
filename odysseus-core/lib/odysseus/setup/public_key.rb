# lib/odysseus/setup/public_key.rb

require 'open3'
require 'shellwords'

module Odysseus
  module Setup
    # The public keys `odysseus setup` installs for the user it creates,
    # resolved entirely on THIS machine before the host is touched.
    #
    # Getting this wrong produces the worst outcome the command has: a created
    # user nobody can log in as. So it runs first, and it raises rather than
    # returning an empty list — there is no sensible way to continue.
    module PublicKey
      # @param keys [Array<String>] ssh.keys entries (private key paths)
      # @param explicit [Array<String>] paths given with --key, which win
      # @return [Array<String>] authorized_keys lines, newline-free
      # @raise [Odysseus::SetupError] when nothing can be resolved
      def self.resolve(keys:, explicit: [])
        looked_at = []

        lines = (explicit.any? ? explicit : Array(keys)).flat_map do |path|
          expanded = File.expand_path(path)
          looked_at << expanded
          from_path(expanded, explicit: explicit.any?)
        end.compact.uniq

        return lines if lines.any?

        raise Odysseus::SetupError,
              'Found no public key to install, so the user would be created with no way ' \
              "to log in. Looked at: #{looked_at.join(', ')}. Pass --key with a path to a " \
              'public key, or check ssh.keys in deploy.yml.'
      end

      # An explicit --key path is a public key itself; an ssh.keys entry is a
      # private key whose public half may sit beside it or may have to be
      # derived, which is common where keys were copied rather than generated.
      def self.from_path(path, explicit:)
        return read_line(path) if explicit
        return read_line("#{path}.pub") if File.file?("#{path}.pub")

        derive(path)
      end

      def self.read_line(path)
        return nil unless File.file?(path)

        line = File.read(path).strip
        line.empty? ? nil : line
      end

      # `ssh-keygen -y` prints the public half of a private key. It fails
      # loudly on an encrypted key, which is the right outcome: odysseus cannot
      # answer a passphrase prompt any more than it can answer sudo's.
      def self.derive(private_key_path)
        return nil unless File.file?(private_key_path)

        out, _err, status = Open3.capture3('ssh-keygen', '-y', '-f', private_key_path)
        return nil unless status.success?

        line = out.strip
        line.empty? ? nil : line
      end

      private_class_method :from_path, :read_line, :derive
    end
  end
end
