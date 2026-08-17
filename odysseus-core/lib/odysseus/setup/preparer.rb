# lib/odysseus/setup/preparer.rb

require 'shellwords'

module Odysseus
  module Setup
    # Prepares a fresh host so odysseus can deploy to it as a non-root user.
    #
    # Runs over the connection made as the bootstrap identity (--as, root or
    # otherwise) and escalates through `escalation` for anything that touches
    # host state. Each step checks before it acts, so a second run against an
    # already-prepared host changes nothing and every step reports :ok — the
    # first run, mid-preparation, is the one that should say :changed.
    #
    # Docker is checked for, never installed: a plan later than this one adds
    # that. A host without it is refused rather than half-prepared.
    class Preparer
      SUPPORTED_UBUNTU = %w[24.04 26.04].freeze
      HOME_BASE = '/home'.freeze

      # @param step [Symbol] which step this is
      # @param status [Symbol] :ok, :changed, :warn or :fail
      # @param detail [String] one line a reader can act on
      Result = Data.define(:step, :status, :detail)

      # @param ssh [Odysseus::Deployer::SSH] connection as the bootstrap identity
      # @param config [Hash] parsed deploy.yml; only ssh.user is read here
      # @param escalation [Odysseus::Setup::Escalation] how root is reached
      # @param keys [Array<String>] resolved authorized_keys lines (see
      #   Odysseus::Setup::PublicKey.resolve, which the caller has already run)
      def initialize(ssh:, config:, escalation:, keys:)
        @ssh = ssh
        @config = config
        @escalation = escalation
        @keys = keys
        @user = config.dig(:ssh, :user)
      end

      # @return [Array<Result>] one per step that ran, in a stable order.
      #   A :fail halts the sequence — nothing after a failed gate is safe to
      #   attempt, whether that's an unsupported distro or a missing daemon.
      def prepare
        results = [escalation_step]
        return results if results.last.status == :fail

        %i[distro docker user group keys state_dir self_test].each do |step|
          result = send(:"#{step}_step")
          results << result
          break if result.status == :fail
        end

        results
      end

      private

      def escalation_step
        @escalation.probe!
        detail = @escalation.sudo? ? 'passwordless sudo confirmed' : 'connected as root'
        Result.new(step: :escalation, status: :ok, detail: detail)
      rescue Odysseus::SetupError => e
        Result.new(step: :escalation, status: :fail, detail: e.message)
      end

      # No escalation: /etc/os-release is world-readable, and the gate itself
      # must hold even on a host escalation cannot yet be proven on.
      def distro_step
        os = read_os_release
        id = os['ID']
        version = os['VERSION_ID']

        if id == 'ubuntu' && SUPPORTED_UBUNTU.include?(version)
          Result.new(step: :distro, status: :ok, detail: "ubuntu #{version}")
        else
          Result.new(
            step: :distro, status: :fail,
            detail: "#{id || 'unknown'} #{version} — odysseus setup only knows " \
                    "ubuntu #{SUPPORTED_UBUNTU.join(' or ')}"
          )
        end
      end

      def docker_step
        output = @escalation.run("docker info --format '{{.ServerVersion}}' 2>&1 || true").to_s.strip

        if output.match?(/\A\d+\./)
          Result.new(step: :docker, status: :ok, detail: "docker #{output}")
        else
          Result.new(
            step: :docker, status: :fail,
            detail: "docker is required and does not appear to be installed: #{output.lines.first.to_s.strip}"
          )
        end
      end

      def user_step
        if user_exists?
          verify_home_ownership
        else
          @escalation.run("useradd --create-home --shell /bin/bash #{shell_user}")
          Result.new(step: :user, status: :changed, detail: "created #{@user}, home #{home_dir}")
        end
      end

      def user_exists?
        !@escalation.run("id -u #{shell_user} 2>/dev/null || true").to_s.strip.empty?
      end

      # Repairs ownership, and only ownership: this never touches the shell,
      # the password, or anything else about a user odysseus did not create.
      def verify_home_ownership
        owner, group = @escalation.run("stat -c '%U %G' #{Shellwords.escape(home_dir)} 2>/dev/null || true").to_s.split

        if owner == @user && group == @user
          Result.new(step: :user, status: :ok, detail: "#{@user} exists, home owned correctly")
        else
          @escalation.run("chown #{shell_user}:#{shell_user} #{Shellwords.escape(home_dir)}")
          Result.new(step: :user, status: :changed, detail: "repaired ownership of #{home_dir} (was #{owner} #{group})")
        end
      end

      def group_step
        groups = @escalation.run("id -nG #{shell_user} 2>/dev/null || true").to_s.split

        if groups.include?('docker')
          Result.new(step: :group, status: :ok, detail: "#{@user} is in the docker group")
        else
          @escalation.run("usermod -aG docker #{shell_user}")
          Result.new(step: :group, status: :changed, detail: "added #{@user} to the docker group")
        end
      end

      # Never overwrites: a second operator's key installed by an earlier run
      # must survive this one. Only the keys actually missing are appended,
      # and the directory is only touched (mkdir/chmod/chown) when something
      # needs to change — a healthy re-run issues none of those commands.
      def keys_step
        missing = @keys.reject { |line| key_present?(line) }
        return Result.new(step: :keys, status: :ok, detail: "#{@keys.size} key(s) already present") if missing.empty?

        @escalation.run("mkdir -p #{Shellwords.escape(ssh_dir)}")
        @escalation.run("touch #{Shellwords.escape(authorized_keys)}")
        missing.each { |line| @escalation.run("echo #{Shellwords.escape(line)} >>#{Shellwords.escape(authorized_keys)}") }
        # 700/600 are reapplied every time a key is appended, so a directory
        # left loose by anything else is corrected as a side effect — sshd
        # ignores both silently, with no error worth finding.
        @escalation.run("chmod 700 #{Shellwords.escape(ssh_dir)}")
        @escalation.run("chmod 600 #{Shellwords.escape(authorized_keys)}")
        @escalation.run("chown -R #{shell_user}:#{shell_user} #{Shellwords.escape(ssh_dir)}")

        Result.new(step: :keys, status: :changed, detail: "added #{missing.size} key(s)")
      end

      def key_present?(line)
        cmd = "grep -qxF #{Shellwords.escape(line)} #{Shellwords.escape(authorized_keys)} 2>/dev/null && echo present || echo absent"
        @escalation.run(cmd).to_s.strip == 'present'
      end

      def state_dir_step
        dir = state_dir
        exists = dir_present?(dir)
        owner = exists ? @escalation.run("stat -c '%U' #{Shellwords.escape(dir)} 2>/dev/null || true").to_s.strip.split.first : nil

        if exists && owner == @user
          Result.new(step: :state_dir, status: :ok, detail: "#{dir} exists")
        else
          @escalation.run("mkdir -p #{Shellwords.escape(dir)}")
          @escalation.run("chown #{shell_user}:#{shell_user} #{Shellwords.escape(dir)}")
          Result.new(step: :state_dir, status: :changed, detail: "created #{dir}")
        end
      end

      # A genuinely fresh connection, authenticated as the deploy user rather
      # than the bootstrap identity -- reusing @ssh would only prove @user's
      # own access, over a session that may predate the docker-group change
      # (usermod -aG only takes effect for new logins) and against a home
      # directory @ssh's identity typically cannot even read into. no sudo
      # here either way: this is the proof the host is usable with no help
      # from escalation, which is the whole safety argument for the command.
      # Because it never writes anything, a failure here leaves the bootstrap
      # path -- and everything already prepared -- untouched and the host
      # still reachable. A failure to even log in is reported by name rather
      # than left to propagate, since that is the bricked-host case this step
      # exists to catch before odysseus hands the host back.
      def self_test_step
        dir = state_dir
        fresh = Odysseus::Deployer::SSH.new(
          host: @ssh.host,
          user: @user,
          port: @ssh.port,
          keys: @config.dig(:ssh, :keys) || [],
          use_tailscale: false
        )

        begin
          docker_output = fresh.execute("docker info --format '{{.ServerVersion}}' 2>&1 || true").to_s.strip
          docker_ok = docker_output.match?(/\A\d+\./)
          writable = fresh.execute(
            "test -d #{Shellwords.escape(dir)} && test -w #{Shellwords.escape(dir)} && echo present || echo absent"
          ).to_s.strip == 'present'

          if docker_ok && writable
            Result.new(step: :self_test, status: :ok, detail: "docker and #{dir} reachable as #{@user}")
          else
            problems = []
            problems << 'docker did not answer' unless docker_ok
            problems << "#{dir} is not writable" unless writable
            Result.new(step: :self_test, status: :fail, detail: problems.join('; '))
          end
        rescue Odysseus::Error => e
          Result.new(
            step: :self_test, status: :fail,
            detail: "could not log in as #{@user}: #{e.message.lines.first.to_s.strip}"
          )
        ensure
          fresh.close
        end
      end

      def dir_present?(dir)
        @escalation.run("test -d #{Shellwords.escape(dir)} && echo present || echo absent").to_s.strip == 'present'
      end

      def read_os_release
        raw = @ssh.execute('cat /etc/os-release 2>/dev/null || true').to_s

        raw.lines.each_with_object({}) do |line, acc|
          key, value = line.strip.split('=', 2)
          next if key.nil? || value.nil?

          acc[key] = value.delete('"')
        end
      end

      # Ubuntu's useradd defaults HOME=/home, and the distro gate already
      # confines this class to ubuntu — so this holds for every user this
      # class either creates or verifies.
      def home_dir
        File.join(HOME_BASE, @user)
      end

      def ssh_dir
        File.join(home_dir, '.ssh')
      end

      def authorized_keys
        File.join(ssh_dir, 'authorized_keys')
      end

      def state_dir
        File.join(home_dir, Odysseus::HostPaths::USER_DIRNAME)
      end

      def shell_user
        Shellwords.escape(@user)
      end
    end
  end
end
