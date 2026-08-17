# lib/odysseus/setup/docker_apt.rb

require 'shellwords'

module Odysseus
  module Setup
    # Installs Docker from Docker's official apt repository, following Docker's
    # own published instructions for Ubuntu.
    #
    # Every file this writes on the host is written WHOLE rather than appended,
    # so a run interrupted anywhere leaves a stale file that the next run
    # overwrites -- never a corrupt one with the repository listed twice.
    #
    # It repairs nothing it did not create: a broken dpkg state, a held lock, a
    # third-party repository that fails to refresh are all reported and raised,
    # not worked around. Guessing at someone else's apt state is how a bootstrap
    # leaves a machine worse than it found it.
    #
    # The GPG key's fingerprint is deliberately not pinned. Pinning defends
    # against a CA-level compromise of download.docker.com, but turns Docker's
    # key rotation into an outage for everyone using this command; Docker's own
    # instructions trust TLS, and so does this.
    class DockerApt
      KEYRING = '/etc/apt/keyrings/docker.asc'.freeze
      SOURCES = '/etc/apt/sources.list.d/docker.list'.freeze
      GPG_URL = 'https://download.docker.com/linux/ubuntu/gpg'.freeze
      REPO_URL = 'https://download.docker.com/linux/ubuntu'.freeze
      LOCK_FILE = '/var/lib/dpkg/lock-frontend'.freeze

      # Long enough to outlast cloud-init and unattended-upgrades on a
      # minutes-old host, which is the normal state of a machine someone is
      # running setup against; short enough that a genuinely stuck lock is an
      # error rather than a session that never returns.
      LOCK_TIMEOUT = 300

      PACKAGES = %w[
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ].freeze

      # @param ssh [Odysseus::Deployer::SSH] connection as the bootstrap identity
      # @param escalation [Odysseus::Setup::Escalation] how root is reached
      # @param codename [String] Ubuntu's VERSION_CODENAME, e.g. "noble"
      def initialize(ssh:, escalation:, codename:)
        @ssh = ssh
        @escalation = escalation
        @codename = codename.to_s.strip
      end

      # @return [nil]
      # @raise [Odysseus::SetupError] on any failure, with the apt output's
      #   first line and, for a lock timeout, the process holding it
      def install!
        if @codename.empty?
          raise Odysseus::SetupError,
                '/etc/os-release reported no VERSION_CODENAME, so the apt repository line ' \
                'cannot name a release. Refusing to guess one.'
        end

        apt('update')
        apt('install -y ca-certificates curl')
        @escalation.run('install -m 0755 -d /etc/apt/keyrings')
        # curl -o, not a redirect: the file is opened by the process sudo
        # elevated, not by the bootstrap identity's own shell.
        @escalation.run("curl -fsSL #{GPG_URL} -o #{KEYRING}")
        @escalation.run("chmod a+r #{KEYRING}")
        write_sources
        # The repository is only visible to apt after a refresh that follows
        # the sources file, so this update is not the same as the one above.
        apt('update')
        apt("install -y #{PACKAGES.join(' ')}")

        nil
      end

      private

      def arch
        @arch ||= @escalation.run('dpkg --print-architecture').to_s.strip
      end

      def sources_line
        "deb [arch=#{arch} signed-by=#{KEYRING}] #{REPO_URL} #{@codename} stable"
      end

      # `tee`, not `tee -a`: this file is replaced, not added to. The prefix
      # goes on the writer alone via Escalation#elevate -- prefixing the whole
      # pipeline would elevate printf and leave tee unprivileged, which is the
      # defect that made setup's first authorized_keys append fail under the
      # documented default identity.
      def write_sources
        writer = @escalation.elevate("tee #{Shellwords.escape(SOURCES)}")
        @ssh.execute("printf '%s\n' #{Shellwords.escape(sources_line)} | #{writer} >/dev/null")
      end

      # `env DEBIAN_FRONTEND=noninteractive` rather than a bare assignment:
      # sudoers may refuse to pass an environment variable through, and a
      # prompt cannot be answered on a non-interactive connection at all.
      def apt(args)
        @escalation.run(
          "env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=#{LOCK_TIMEOUT} #{args}"
        )
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "apt-get #{args.split.first} failed#{lock_holder_note}: " \
              "#{e.message.lines.first.to_s.strip}"
      end

      # Best-effort attribution, never a second failure: if fuser or ps is
      # missing the message simply says less.
      def lock_holder_note
        pid = @escalation.run("fuser #{LOCK_FILE} 2>/dev/null | tr -d ' '").to_s.strip
        return '' if pid.empty?

        name = @escalation.run("ps -o comm= -p #{Shellwords.escape(pid)} 2>/dev/null || true").to_s.strip
        name.empty? ? " (pid #{pid} holds #{LOCK_FILE})" : " (#{name}, pid #{pid}, holds #{LOCK_FILE})"
      rescue Odysseus::Error
        ''
      end
    end
  end
end
