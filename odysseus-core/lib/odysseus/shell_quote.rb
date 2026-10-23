# lib/odysseus/shell_quote.rb

module Odysseus
  # POSIX single-quoting for a value that is interpolated into a shell
  # command string, rather than passed as a separate argv entry.
  #
  # Not Shellwords.escape: that leaves an alphanumeric string bare (no quotes
  # at all), and CommandRedaction::STDIN_PIPE only matches a value quoted with
  # a literal `'` or `"`. Registry logins (Registry::HostSession,
  # Builder::Client) both echo a password into `docker login
  # --password-stdin`, so both need the same quoting -- shared here instead of
  # duplicated, so a fix to one cannot silently diverge from the other.
  module ShellQuote
    # @param value [String, nil]
    # @return [String] `value` wrapped in single quotes, with any single quote
    #   it contains closed out, escaped, and reopened: `it's` becomes
    #   `'it'\''s'`. Inside single quotes nothing else is special.
    def self.single_quote(value)
      "'#{value.to_s.gsub("'", "'\\\\''")}'"
    end
  end
end
