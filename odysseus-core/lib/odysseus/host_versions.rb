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
    # @param roles [Array<Symbol>] the roles this host serves, in config order.
    #   current scans them in this order and stops at the first that is
    #   serving, so a host whose web role is down but whose jobs role is up
    #   still reports something rather than nil.
    # @return [HostVersions]
    def self.read(host:, ssh:, service:, image:, roles:)
      docker = Odysseus::Docker::Client.new(ssh)

      new(
        host: host,
        current: current_version(docker, service, roles),
        available: docker.image_tags(image),
        history: Odysseus::DeployLog.new(ssh: ssh, service: service).entries
      )
    end

    # The version label of the first running container of the first role, in
    # role order, that is actually serving. WebDeploy and JobDeploy label
    # their containers differently (see Docker::Labels.service_for), so each
    # role must be queried under its own label or a non-web role reports
    # nothing running.
    def self.current_version(docker, service, roles)
      roles.each do |role|
        label = Odysseus::Docker::Labels.service_for(service: service, role: role)
        version = docker.list(service: label)
                        .filter_map { |container| Odysseus::Docker::Labels.version_of(container) }
                        .first
        return version if version
      end

      nil
    end

    private_class_method :current_version

    # @param version [String]
    # @return [Boolean] whether this host has an image tagged that way
    def available?(version)
      available.include?(version)
    end
  end
end
