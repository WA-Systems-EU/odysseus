# lib/odysseus/core/deploy_versioning.rb

module Odysseus
  module Core
    # The identity a deployed container carries: which version it is, which
    # commit it came from, and when it was deployed.
    #
    # Shared rather than duplicated because `status`, `rollback` and image
    # retention all read these labels, so an orchestrator that invents its own
    # scheme becomes invisible to them. odysseus-sail-rolling did exactly that
    # — it stamped odysseus.version with a timestamp, which meant retention's
    # in-use guard could never match a version from the deploy log.
    #
    # The including class must expose @config.
    module DeployVersioning
      # The version this deploy identifies. Falls back to the tag in the image
      # reference so a caller passing --image still gets a self-describing name.
      def deploy_version_tag(image)
        resolved = @config[:deploy_version]
        return resolved.version if resolved

        image.to_s.split(':').last
      end

      # deployed_at replaces the timestamp odysseus.version used to hold;
      # git_ref is only known when the version came from a commit.
      def version_labels
        labels = { 'odysseus.deployed_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
        resolved = @config[:deploy_version]
        labels['odysseus.git_ref'] = resolved.ref if resolved&.ref
        labels
      end
    end
  end
end
