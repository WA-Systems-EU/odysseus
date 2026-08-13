# lib/odysseus/host_versions.rb

module Odysseus
  # What one host knows about one service's versions: what is serving now, what
  # it could serve (images present), and what it has served (its deploy log).
  #
  # Hosts are authoritative for rollback. A developer's checkout and the git
  # notes history can both drift from what a host can actually run — a rebuilt
  # host, a pruned image, a change made by hand — so the target is chosen from
  # this, never from the repository.
  HostVersions = Data.define(:host, :current, :available, :history) do
    # Read one host's state. Caller owns the connection and closes it.
    #
    # @param host [String] host name, for reporting
    # @param ssh [Odysseus::Deployer::SSH] open connection to that host
    # @param service [String] the service name from deploy.yml
    # @param image [String] the repository from deploy.yml, without a tag
    # @return [HostVersions]
    def self.read(host:, ssh:, service:, image:)
      docker = Odysseus::Docker::Client.new(ssh)

      new(
        host: host,
        current: current_version(docker, service),
        available: docker.image_tags(image),
        history: Odysseus::DeployLog.new(ssh: ssh, service: service).entries
      )
    end

    # The version label of the first running container. During a deploy two can
    # briefly overlap; either answers "what is serving", and the planner only
    # uses this to avoid offering a version that is already up.
    def self.current_version(docker, service)
      docker.list(service: service)
            .filter_map { |container| Odysseus::Docker::Labels.version_of(container) }
            .first
    end

    private_class_method :current_version

    # @param version [String]
    # @return [Boolean] whether this host has an image tagged that way
    def available?(version)
      available.include?(version)
    end
  end
end
