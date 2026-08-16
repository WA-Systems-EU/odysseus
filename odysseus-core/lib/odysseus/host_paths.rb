# lib/odysseus/host_paths.rb

module Odysseus
  # Where odysseus keeps its state on a target host.
  #
  # Root writes /var/lib/odysseus, which is where every install has always
  # written and where existing hosts still have their deploy history. Any other
  # user cannot create that directory, so their state goes under their own
  # home. One class answers this so the deploy log, the env files and — later —
  # the deploy lock cannot disagree about where they live.
  #
  # Caddy's directory is deliberately NOT here as a method: see CADDY_DIR.
  class HostPaths
    SYSTEM_BASE = '/var/lib/odysseus'.freeze
    USER_DIRNAME = '.odysseus'.freeze
    ROOT = 'root'.freeze

    # Caddy's /data mount: issued certificates, written by the container as
    # root, shared by every service on the host. It does not follow the deploy
    # user — moving it would mean copying live certificates or re-issuing
    # against Let's Encrypt rate limits, for no benefit.
    CADDY_DIR = "#{SYSTEM_BASE}/caddy".freeze

    # @param ssh [Odysseus::Deployer::SSH] connection whose user decides the base
    def initialize(ssh)
      @ssh = ssh
      @base = nil
    end

    # @return [String] the directory all odysseus state lives under
    def base
      @base ||= @ssh.user == ROOT ? SYSTEM_BASE : File.join(home, USER_DIRNAME)
    end

    # @param service [String] the service: value from deploy.yml
    # @return [String] that service's state directory
    def service_dir(service)
      File.join(base, service)
    end

    # @return [String] where env files are written for the length of a docker run
    def env_dir
      File.join(base, 'env')
    end

    # Where a root install wrote, whoever is connected now. Used to read the
    # deploy history of a host that has since moved to a deploy user.
    # @return [String]
    def legacy_base
      SYSTEM_BASE
    end

    private

    # Asked once per connection and cached. A host that reports nothing is an
    # error rather than a path of "/.odysseus", which would be unwritable and
    # would only be noticed later, as a failed deploy.
    def home
      value = @ssh.execute('echo $HOME').to_s.strip
      raise Odysseus::DeployError, "Could not determine the home directory of #{@ssh.user}" if value.empty?

      value
    end
  end
end
