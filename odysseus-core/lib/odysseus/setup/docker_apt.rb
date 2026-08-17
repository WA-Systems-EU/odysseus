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

      # Deliberately short of Docker's published instructions, which also
      # install docker-compose-plugin: nothing in this codebase invokes
      # `docker compose`, odysseus runs containers through `docker run` /
      # `docker create` (odysseus-core/lib/odysseus/docker/client.rb). Do not
      # add it back on the strength of Docker's docs alone -- `setup` installs
      # only what odysseus actually uses. docker-buildx-plugin stays: `docker
      # buildx build` (odysseus-core/lib/odysseus/builder/client.rb:216) runs
      # on the operator's own machine for the `:local` strategy, or on
      # `builder.host` over SSH for `:remote` -- never on a deploy target as
      # such, and setup's hosts come only from `servers.*`
      # (odysseus-core/lib/odysseus/deployer/executor.rb:300-308). So on a
      # host setup prepares, buildx is only reachable where `builder.host`
      # happens to name one of those deploy hosts with multiarch on -- a
      # coincidence plausible precisely in setup's single-host-trial niche,
      # and worth keeping regardless: a modern `docker build` without the
      # plugin falls back to Docker's deprecated legacy builder.
      PACKAGES = %w[docker-ce docker-ce-cli containerd.io docker-buildx-plugin].freeze

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
        make_keyring_dir
        fetch_keyring
        make_keyring_readable
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

      # Every non-apt host call below is wrapped the same way #apt already
      # is: a raw Odysseus::SSHCommandError from any of these used to escape
      # #install! untouched, past Preparer#run_step's `rescue
      # Odysseus::SetupError` and out of #prepare entirely -- reported by the
      # CLI's per-host `rescue StandardError` as a step named :connection,
      # discarding every step result that had already succeeded on that
      # host. Wrapping here, at the point each command actually runs, is what
      # keeps #install!'s own `@raise [Odysseus::SetupError] on any failure`
      # true.

      def make_keyring_dir
        @escalation.run('install -m 0755 -d /etc/apt/keyrings')
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "could not create /etc/apt/keyrings: #{e.message.lines.first.to_s.strip}"
      end

      # curl -o, not a redirect: the file is opened by the process sudo
      # elevated, not by the bootstrap identity's own shell.
      def fetch_keyring
        @escalation.run("curl -fsSL #{GPG_URL} -o #{KEYRING}")
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "could not download Docker's signing key from #{GPG_URL}: " \
              "#{e.message.lines.first.to_s.strip}"
      end

      def make_keyring_readable
        @escalation.run("chmod a+r #{KEYRING}")
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "could not make #{KEYRING} readable: #{e.message.lines.first.to_s.strip}"
      end

      # `tee`, not `tee -a`: this file is replaced, not added to. The prefix
      # goes on the writer alone via Escalation#elevate -- prefixing the whole
      # pipeline would elevate printf and leave tee unprivileged, which is the
      # defect that made setup's first authorized_keys append fail under the
      # documented default identity.
      def write_sources
        writer = @escalation.elevate("tee #{Shellwords.escape(SOURCES)}")
        @ssh.execute("printf '%s\n' #{Shellwords.escape(sources_line)} | #{writer} >/dev/null")
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "could not write the apt sources file #{SOURCES}: #{e.message.lines.first.to_s.strip}"
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
        # fuser can report more than one holder as space-separated PIDs on
        # one line. `tr -d ' '` would glue them into one fabricated number --
        # "1234 5678" becoming "12345678" -- so take the first token instead
        # of deleting every space.
        pid = @escalation.run("fuser #{LOCK_FILE} 2>/dev/null").to_s.strip.split.first.to_s
        return '' if pid.empty?

        name = @escalation.run("ps -o comm= -p #{Shellwords.escape(pid)} 2>/dev/null || true").to_s.strip
        name.empty? ? " (pid #{pid} holds #{LOCK_FILE})" : " (#{name}, pid #{pid}, holds #{LOCK_FILE})"
      rescue Odysseus::Error
        ''
      end
    end
  end
end
