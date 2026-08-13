# lib/odysseus/rollback_plan.rb

module Odysseus
  # The decision a rollback acts on, settled before any host is touched.
  #
  # version    the tag every host will run
  # ref        the commit that tag was built from, recovered from the host's
  #            deploy log; nil when no log recorded it
  # approximate true when no host had a deploy log and the ordering came from
  #            image creation time, which is build time rather than deploy time
  # replacing  host name => the version it is currently running (nil if none),
  #            so each host's log records what it actually came from
  RollbackPlan = Data.define(:version, :ref, :approximate, :replacing) do
    # @param host [String]
    # @return [String, nil] the version this host is rolling back from
    def from_for(host)
      replacing[host]
    end
  end
end
