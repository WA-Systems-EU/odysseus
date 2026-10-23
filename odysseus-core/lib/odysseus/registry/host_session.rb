# lib/odysseus/registry/host_session.rb

require 'shellwords'

module Odysseus
  module Registry
    # A registry login on one host, confined to a directory that is removed
    # again.
    #
    # Not `docker login` followed by `docker logout`, for three reasons. The
    # credential never enters ~/.docker/config.json. A deploy that dies between
    # login and logout leaves nothing, where the logout approach leaves exactly
    # what it was meant to clean up. And `docker logout` against the default
    # config would remove credentials the host already had for its own
    # purposes, which a deploy has no business doing.
    #
    # Scoped to one SSH connection, which in Executor#run_deploy means one
    # role on one host: a session cannot outlive the connection it logged in
    # over.
    class HostSession
      DIR_TEMPLATE = 'odysseus-registry.XXXXXXXX'.freeze

      # @param ssh [Odysseus::Deployer::SSH]
      # @param credentials [Odysseus::Registry::Credentials]
      # @yieldparam config_dir [String, nil] nil when there is nothing to log
      #   in with, so callers have one code path either way
      # @return [Object] whatever the block returned
      # @raise [Odysseus::DeployError] if the login is rejected
      def self.open(ssh:, credentials:, &block)
        return block.call(nil) unless credentials.complete?

        new(ssh: ssh, credentials: credentials).run(&block)
      end

      def initialize(ssh:, credentials:)
        @ssh = ssh
        @credentials = credentials
      end

      def run
        dir = create_dir
        begin
          login(dir)
          yield(dir)
        ensure
          remove(dir)
        end
      end

      private

      # Mode 700 because the file written inside holds the credential, and a
      # host may have other users on it.
      def create_dir
        # $_ would hold mktemp's last ARGUMENT, not its output, so the
        # directory has to be captured in a shell variable and echoed back.
        out = @ssh.execute("d=$(mktemp -d -t #{DIR_TEMPLATE}) && chmod 700 \"$d\" && echo \"$d\"")
        dir = out.to_s.strip.lines.last.to_s.strip
        raise Odysseus::DeployError, 'Could not create a directory for the registry credentials' if dir.empty?

        dir
      end

      # DOCKER_CONFIG is exported in its own statement, chained with `&&`,
      # rather than prefixed directly onto `docker login` (`DOCKER_CONFIG=dir
      # docker login`) or passed as `--config`: either of those puts a token
      # between the pipe and `docker login`, and CommandRedaction::STDIN_PIPE
      # requires `docker login` (or `--password-stdin`) immediately after the
      # pipe, with nothing -- not even an env assignment -- in between. The
      # `export ... &&` form keeps `echo '...' | docker login ...` adjacent,
      # so the redactor matches, while DOCKER_CONFIG still reaches `docker
      # login` because both run in the same shell invocation.
      #
      # The password is wrapped in single quotes explicitly -- not via
      # Shellwords.escape, which leaves an alphanumeric string bare -- because
      # STDIN_PIPE only matches an echoed value quoted with a literal `'` or
      # `"`. A password containing a single quote is handled the POSIX way:
      # close the quote, emit an escaped quote, reopen it.
      def login(dir)
        @ssh.execute(
          "export DOCKER_CONFIG=#{Shellwords.escape(dir)} && " \
          "echo #{shell_single_quote(@credentials.password)} | docker login " \
          "#{Shellwords.escape(@credentials.server)} -u #{Shellwords.escape(@credentials.username)} " \
          '--password-stdin'
        )
      rescue Odysseus::Error => e
        raise Odysseus::DeployError, "Registry login failed for #{@credentials.server}: #{e.message}"
      end

      # Single-quotes a string for POSIX shells, escaping any literal single
      # quote it contains. Inside single quotes nothing is special except `'`
      # itself, so a `'` is closed out, an escaped quote is emitted, and the
      # quote is reopened: `it's` becomes `'it'\''s'`.
      def shell_single_quote(value)
        "'#{value.to_s.gsub("'", "'\\\\''")}'"
      end

      # Never fails the deploy, but never silent either: what was left behind
      # is a credential on a host.
      def remove(dir)
        return if dir.nil? || dir.empty?

        @ssh.execute("rm -rf #{Shellwords.escape(dir)}")
      rescue StandardError => e
        warn "Could not remove the registry credentials at #{dir}: #{e.message}"
      end
    end
  end
end
