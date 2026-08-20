# lib/odysseus/command_redaction.rb

module Odysseus
  # Hides secrets in a command string before it is printed.
  #
  # This runs on the way to the terminal only -- the command executed is always
  # the real one. It lives in core rather than in the CLI's UI because the layer
  # that echoes commands under --debug/-v is SSH#execute, and it echoes every
  # command, not the handful the CLI wraps in its own redacting IO.
  #
  # The case that prompted it: registry login builds
  # `echo '<password>' | docker login <server> -u <user> --password-stdin`
  # (builder/client.rb). --password-stdin exists to keep a password off the
  # argv, and interpolating it into `echo '...'` puts it straight back into the
  # command string -- with no -p and no --password, so every pattern written to
  # catch those misses it entirely.
  module CommandRedaction
    PLACEHOLDER = '[REDACTED]'.freeze

    # Anything piped into a command that reads a secret from stdin. Matched by
    # what the pipe FEEDS rather than by the flag, since the flag's whole point
    # is that the secret is not one of its arguments.
    STDIN_PIPE = /(echo\s+)(['"]).*?\2(\s*\|\s*\S*(?:docker\s+login|--password-stdin))/m
    SHORT_FLAG = /(\s-p\s+)\S+/
    LONG_FLAG = /(--password[= ])\S+/
    ASSIGNMENT = /((?:KEY|TOKEN|SECRET|PASSWORD|MASTER_KEY|API_KEY|CREDENTIALS)\s*=\s*)\S+/i

    # @param command [String] the command as it would be sent
    # @return [String] the command as it is safe to print
    def self.redact(command)
      command.to_s
             .gsub(STDIN_PIPE) { "#{Regexp.last_match(1)}'#{PLACEHOLDER}'#{Regexp.last_match(3)}" }
             .gsub(SHORT_FLAG, "\\1#{PLACEHOLDER}")
             .gsub(LONG_FLAG, "\\1#{PLACEHOLDER}")
             .gsub(ASSIGNMENT, "\\1#{PLACEHOLDER}")
    end
  end
end
