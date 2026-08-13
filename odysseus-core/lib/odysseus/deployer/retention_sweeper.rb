# lib/odysseus/deployer/retention_sweeper.rb

module Odysseus
  module Deployer
    # Removes a service's images that no host needs any more, split out of
    # Executor for the same reason DependencyManager was: it is a distinct
    # concern, sharing only the config and a way to open a connection.
    #
    # Best effort throughout. This runs after a deploy has already succeeded and
    # switched traffic, so nothing here may raise into the caller: every removal
    # is attempted on its own, and a host that cannot be read at all is skipped
    # with a warning.
    class RetentionSweeper
      # @param config [Hash] parsed deploy.yml
      # @param connector [#call] returns an open SSH connection for a host
      # @param logger [Object] responds to #info and #warn
      def initialize(config:, connector:, logger:)
        @config = config
        @connector = connector
        @logger = logger
      end

      # @param host_roles [Hash{String => Array<Symbol>}] hosts and the roles each serves
      # @return [Hash{String => Array<String>}] versions removed, keyed by host
      def sweep(host_roles)
        host_roles.to_h { |host, roles| [host, sweep_host(host, roles)] }
      end

      private

      def sweep_host(host, roles)
        ssh = @connector.call(host)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          plan = retention_plan(ssh, docker, host, roles)
          return [] if plan.nil?

          @logger.info("  Keeping #{plan.keep.join(', ')} on #{host}")
          plan.remove.select { |version| prune_image(docker, host, version) }
        rescue StandardError => e
          @logger.warn("Could not prune images on #{host}: #{e.message}")
          []
        ensure
          ssh.close
        end
      end

      # nil when the host has no deploy log to authorise removals. Falling back
      # to image creation time would risk deleting a version someone still
      # wants: creation time is *build* time, and images can reach a host out of
      # order.
      def retention_plan(ssh, docker, host, roles)
        history = Odysseus::DeployLog.new(ssh: ssh, service: @config[:service]).entries

        if history.empty?
          @logger.info("  No deploy log on #{host} yet, so nothing is pruned")
          return nil
        end

        Odysseus::RetentionPlanner.new(
          history: history,
          available: docker.image_tags(@config[:image]),
          in_use: docker.versions_in_use(container_labels(roles)),
          retain: @config[:retain_versions]
        ).plan
      end

      # The odysseus.service label values this host's containers carry — one per
      # role. Built with Labels.service_for so reading them back cannot disagree
      # with how WebDeploy and JobDeploy write them.
      def container_labels(roles)
        roles.map { |role| Odysseus::Docker::Labels.service_for(service: @config[:service], role: role) }
      end

      # True when the image is gone. Named prune_image, not remove_image, so it
      # cannot be misread as Docker::Client#remove_image, which it calls.
      #
      # Rescues StandardError rather than Odysseus::Error: docker refuses to
      # remove an image a container still references, and SSH#execute can also
      # raise Net::SSH::Disconnect, IOError or Net::SSH::ChannelOpenFailed
      # untranslated.
      def prune_image(docker, host, version)
        image = "#{@config[:image]}:#{version}"
        docker.remove_image(image)
        @logger.info("  Pruned #{image} on #{host}")
        true
      rescue StandardError => e
        @logger.info("  Kept #{image} on #{host}: #{e.message}")
        false
      end
    end
  end
end
