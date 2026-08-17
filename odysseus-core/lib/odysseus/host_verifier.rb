# lib/odysseus/host_verifier.rb

require 'shellwords'

module Odysseus
  # Read-only diagnosis of whether one host is ready for odysseus to deploy to
  # it AS THE USER THE CONFIG NAMES.
  #
  # That last part is the point. Verifying as root would pass on a host the
  # deploy user cannot use, which is the failure this exists to catch — a deploy
  # that dies at the first container start because a directory is not writable.
  #
  # Nothing here writes to the host. A check that would need to write in order
  # to learn something reports that it cannot tell instead.
  #
  # Caddy's data directory is deliberately absent from these checks: it does not
  # exist until the first deploy starts Caddy, so a correctly configured host
  # that has not deployed yet would be reported broken.
  class HostVerifier
    # Named explicitly rather than computed, so supporting a new LTS is a
    # deliberate edit with a tested host behind it, not something that becomes
    # true on a date.
    SUPPORTED_UBUNTU = %w[24.04 26.04].freeze
    ROOT = 'root'.freeze

    # @param check [Symbol] which check this is
    # @param status [Symbol] :ok, :warn or :fail
    # @param detail [String] one line a reader can act on
    Result = Data.define(:check, :status, :detail)

    def initialize(ssh:, config:)
      @ssh = ssh
      @config = config
    end

    # @return [Array<Result>] one per check, in a stable order
    def verify
      [distro, docker, docker_group, state_dir, deploy_log]
    end

    private

    def root?
      @ssh.user == ROOT
    end

    def host_paths
      @host_paths ||= Odysseus::HostPaths.new(@ssh)
    end

    def distro
      os = read_os_release
      id = os['ID']
      version = os['VERSION_ID']

      if id == 'ubuntu' && SUPPORTED_UBUNTU.include?(version)
        Result.new(check: :distro, status: :ok, detail: "ubuntu #{version}")
      else
        # A warning, not a failure: deploys work on any host with Docker. Only
        # `odysseus setup`'s installer is apt-specific.
        Result.new(
          check: :distro, status: :warn,
          detail: "#{id || 'unknown'} #{version}".strip +
                  " — deploys work here, but `odysseus setup` supports only ubuntu #{SUPPORTED_UBUNTU.join(', ')}"
        )
      end
    end

    def docker
      output = @ssh.execute('docker info 2>&1 || true').to_s
      version = output[/^Server Version:\s*(\S+)/, 1]

      if version
        Result.new(check: :docker, status: :ok, detail: "docker #{version}")
      else
        Result.new(
          check: :docker, status: :fail,
          detail: "the docker daemon did not answer as #{@ssh.user}: #{output.lines.first.to_s.strip}"
        )
      end
    end

    def docker_group
      # root does not need the group, and saying it is missing would be a false
      # alarm on every root install — still the default.
      return Result.new(check: :docker_group, status: :ok, detail: 'not needed for root') if root?

      groups = @ssh.execute("id -nG #{Shellwords.escape(@ssh.user)} 2>/dev/null || true").to_s.split

      if groups.include?('docker')
        Result.new(check: :docker_group, status: :ok, detail: "#{@ssh.user} is in the docker group")
      else
        Result.new(
          check: :docker_group, status: :fail,
          detail: "#{@ssh.user} is not in the docker group (has: #{groups.join(' ')})"
        )
      end
    end

    def state_dir
      dir = host_paths.base
      # Check the nearest existing ancestor: the directory itself may legitimately
      # not exist yet on a host that has never deployed, and creating it to find
      # out is exactly what this command must not do.
      probe = Shellwords.escape(dir)
      output = @ssh.execute(
        "d=#{probe}; while [ ! -e \"$d\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " \
        'if test -w "$d"; then echo writable; else echo "not writable:$d"; fi'
      ).to_s.strip

      if output == 'writable'
        Result.new(check: :state_dir, status: :ok, detail: "#{dir} is writable")
      else
        Result.new(
          check: :state_dir, status: :fail,
          detail: "#{dir} is not writable by #{@ssh.user} (#{output.split(':').last} is not)"
        )
      end
    end

    def deploy_log
      path = File.join(host_paths.service_dir(@config[:service]), Odysseus::DeployLog::FILENAME)
      legacy = File.join(host_paths.legacy_base, @config[:service], Odysseus::DeployLog::FILENAME)

      return Result.new(check: :deploy_log, status: :ok, detail: path) if root? || legacy == path

      present = @ssh.execute("test -e #{Shellwords.escape(legacy)} && echo present || echo absent").to_s.strip

      if present == 'present'
        # Losing this is silent — rollback just offers fewer versions — so it is
        # worth a warning rather than a note.
        Result.new(
          check: :deploy_log, status: :warn,
          detail: "#{path}; root-era history still at #{legacy}, readable but not writable by #{@ssh.user}"
        )
      else
        Result.new(check: :deploy_log, status: :ok, detail: path)
      end
    end

    def read_os_release
      raw = @ssh.execute('cat /etc/os-release 2>/dev/null || true').to_s

      raw.lines.each_with_object({}) do |line, acc|
        key, value = line.strip.split('=', 2)
        next if key.nil? || value.nil?

        acc[key] = value.delete('"')
      end
    end
  end
end
