# lib/odysseus/host_paths.rb

module Odysseus
  # Where odysseus keeps its state on a target host.
  #
  # Root writes /var/lib/odysseus, which is where every install has always
  # written and where existing hosts still have their deploy history. Any other
  # user cannot create that directory, so their state goes under their own
  # home. One class answers this so the deploy log, the env files, Caddy's
  # data directory and — later — the deploy lock cannot disagree about where
  # they live.
  class HostPaths
    SYSTEM_BASE = '/var/lib/odysseus'.freeze
    USER_DIRNAME = '.odysseus'.freeze
    ROOT = 'root'.freeze

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

    # Caddy's /data mount: issued certificates, written by the container as
    # root. For a root connection this resolves to exactly the path every
    # install has always used, so existing certificates are found unmoved. A
    # non-root connection gets a directory it can actually create — the
    # earlier design left this fixed at the root path to protect those
    # certificates, but that protection only ever applied to root: deriving it
    # like every other path here protects root identically while letting a
    # non-root deploy user create its own directory instead of failing at
    # `mkdir`.
    #
    # Caddy is one container shared by every service on a host, so this only
    # works cleanly with the one-deploy-user-per-host shape this class already
    # assumes: two different deploy users on the same host would disagree
    # about where Caddy's data lives, and whichever one first starts the
    # container wins, since #ensure_running never recreates one already
    # running.
    # @return [String]
    def caddy_dir
      File.join(base, 'caddy')
    end

    # Caddy's /config mount: the autosave of its running configuration.
    #
    # The official image sets XDG_CONFIG_HOME=/config and XDG_DATA_HOME=/data,
    # and Caddy writes $XDG_CONFIG_HOME/caddy/autosave.json on every admin API
    # change. Mounting only #caddy_dir therefore persisted certificates and
    # discarded the routes, which is why a removed or restarted Caddy came back
    # serving nothing until every service on the host redeployed. Kept separate
    # from #caddy_dir rather than nested inside it because the container owns
    # the layout of both, and /data already has a meaning to Caddy.
    # @return [String]
    def caddy_config_dir
      File.join(base, 'caddy-config')
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
