# lib/odysseus/ssh_key.rb

require 'base64'

module Odysseus
  # Reads what can be known about a private key file without decrypting it.
  #
  # This exists for one message. odysseus connects with `non_interactive: true`
  # -- a passphrase prompt on a deploy connection can never be answered, so
  # prompting would hang rather than help. net-ssh reports the resulting
  # key-loading failure to a logger rather than raising it
  # (`key_manager.rb:319`), so with no logger configured the reason is
  # discarded and authentication simply fails. The user is then told to check
  # keys that are perfectly correct. Knowing which key is locked is what turns
  # that into an answerable question.
  module SSHKey
    OPENSSH_HEADER = '-----BEGIN OPENSSH PRIVATE KEY-----'.freeze
    OPENSSH_MAGIC = "openssh-key-v1\0".freeze
    PEM_ENCRYPTED = /^Proc-Type:\s*4,ENCRYPTED/
    NO_CIPHER = 'none'.freeze

    class << self
      # @param path [String] path to a private key file
      # @return [Boolean] true only when the file is a private key that is
      #   passphrase-protected. False for anything unreadable, absent, public,
      #   or not a key: those are different failures with different messages,
      #   and claiming a passphrase problem for them would send the reader
      #   somewhere just as wrong as "check your SSH keys".
      def encrypted?(path)
        data = read(path)
        return false unless data

        data.include?(OPENSSH_HEADER) ? openssh_encrypted?(data) : PEM_ENCRYPTED.match?(data)
      end

      private

      def read(path)
        return nil unless File.file?(path)

        File.read(path)
      rescue SystemCallError, IOError
        nil
      end

      # An OpenSSH-format key states its cipher in the binary body rather than
      # in a header: the magic "openssh-key-v1\0", then a 4-byte big-endian
      # length and that many bytes of cipher name, which is "none" when the key
      # is not encrypted. Read rather than decrypted, so no passphrase is
      # needed to answer the question.
      def openssh_encrypted?(data)
        body = data[/#{Regexp.escape(OPENSSH_HEADER)}\n(.*?)\n-----END/m, 1]
        return false unless body

        raw = Base64.decode64(body)
        return false unless raw.start_with?(OPENSSH_MAGIC)

        rest = raw.byteslice(OPENSSH_MAGIC.bytesize..) || ''
        return false if rest.bytesize < 4

        length = rest.byteslice(0, 4).unpack1('N')
        cipher = rest.byteslice(4, length)

        !cipher.nil? && cipher != NO_CIPHER
      end
    end
  end
end
