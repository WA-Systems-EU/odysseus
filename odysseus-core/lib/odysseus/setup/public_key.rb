# lib/odysseus/setup/public_key.rb

require 'open3'

module Odysseus
  module Setup
    # The public keys `odysseus setup` installs for the user it creates,
    # resolved entirely on THIS machine before the host is touched.
    #
    # Getting this wrong produces the worst outcome the command has: a created
    # user nobody can log in as. So it runs first, and it raises rather than
    # returning an empty list — there is no sensible way to continue.
    module PublicKey
      # A recognised SSH public-key line: key type, whitespace, base64 body,
      # optional comment (which may itself contain spaces). Anything that
      # doesn't match -- a private key's PEM body, a mangled file, plain
      # garbage -- must never survive to become an authorized_keys entry on a
      # real host.
      LINE_PATTERN = %r{
        \A
        (?: ssh-rsa | ssh-dss | ssh-ed25519
          | ecdsa-sha2-\S+
          | sk-ecdsa-sha2-\S+@openssh\.com
          | sk-ssh-ed25519@openssh\.com )
        [ \t]+
        [A-Za-z0-9+/]+=*
        (?: [ \t]+ \S .* )?
        \z
      }x

      # @param keys [Array<String>] ssh.keys entries (private key paths)
      # @param explicit [Array<String>] paths given with --key, which win
      # @return [Array<String>] authorized_keys lines, newline-free
      # @raise [Odysseus::SetupError] when nothing can be resolved
      def self.resolve(keys:, explicit: [])
        looked_at = []
        from_explicit = explicit.any?

        lines = (from_explicit ? explicit : Array(keys)).flat_map do |path|
          expanded = File.expand_path(path)
          looked_at << expanded
          found = from_path(expanded, explicit: from_explicit)

          # A --key path the operator named is not optional. Falling back to
          # another one, or to ssh.keys, would install a different key than
          # the one they asked for -- worse than refusing, because they would
          # believe the named key was authorised when it was not.
          if from_explicit && found.empty?
            raise Odysseus::SetupError,
                  "#{expanded} does not contain a valid SSH public key. --key must point " \
                  'at a public key (usually the file ending in .pub), not a private key.'
          end

          found
        end.uniq

        return lines if lines.any?

        raise Odysseus::SetupError,
              'Found no public key to install, so the user would be created with no way ' \
              "to log in. Looked at: #{looked_at.join(', ')}. Pass --key with a path to a " \
              'public key, or check ssh.keys in deploy.yml.'
      end

      # An explicit --key path must be a public key itself; an ssh.keys entry
      # is a private key whose public half is read from its .pub sibling, or,
      # when that sibling is missing, empty, or has nothing valid in it,
      # derived -- common where keys were copied rather than generated.
      def self.from_path(path, explicit:)
        return valid_lines(path) if explicit

        sibling_lines = valid_lines("#{path}.pub")
        return sibling_lines if sibling_lines.any?

        derive(path)
      end

      # @return [Array<String>] the valid public-key lines in the file, in
      #   order; blank or invalid lines are dropped rather than passed through
      def self.valid_lines(path)
        return [] unless File.file?(path)

        File.readlines(path).filter_map do |raw|
          line = raw.strip
          line if !line.empty? && LINE_PATTERN.match?(line)
        end
      end

      # `ssh-keygen -y` prints the public half of a private key. It fails
      # loudly on an encrypted key, which is the right outcome: odysseus cannot
      # answer a passphrase prompt any more than it can answer sudo's.
      def self.derive(private_key_path)
        return [] unless File.file?(private_key_path)

        out, _err, status = Open3.capture3('ssh-keygen', '-y', '-f', private_key_path)
        return [] unless status.success?

        line = out.strip
        LINE_PATTERN.match?(line) ? [line] : []
      end

      private_class_method :from_path, :valid_lines, :derive
    end
  end
end
