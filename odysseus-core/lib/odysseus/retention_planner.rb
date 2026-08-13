# lib/odysseus/retention_planner.rb

module Odysseus
  # Chooses which of a service's image tags to delete from one host.
  #
  # Pure: handed what the host reports, returns a decision. That matters more
  # here than anywhere else in odysseus, because the decision deletes data on a
  # production host — so the rules are testable without a connection, and three
  # independent things have to agree before anything is removed: the retain
  # window, the set of versions containers still reference, and (at the caller)
  # docker's own refusal to remove an image in use.
  class RetentionPlanner
    # Never removed automatically: a moving pointer, and pre-0.4.2 deploys were
    # built from it, so something may still reference it.
    PROTECTED_TAGS = ['latest'].freeze

    # @param history [Array<Odysseus::DeployLog::Entry>] oldest first
    # @param available [Array<String>] tags present on the host
    # @param in_use [Array<String>] versions containers still reference
    # @param retain [Integer] distinct versions to keep
    def initialize(history:, available:, in_use:, retain:)
      @history = history
      @available = available
      @in_use = in_use
      @retain = retain
    end

    # @return [Odysseus::RetentionPlan]
    def plan
      RetentionPlan.new(remove: removable, keep: keep)
    end

    private

    # Logged versions, newest deploy first, de-duplicated keeping the newest
    # occurrence. Timestamps are fixed-width UTC ISO 8601, so they sort
    # lexicographically. Same ordering RollbackPlanner ranks candidates by.
    def ranked
      @ranked ||= @history.sort_by(&:at).reverse.map(&:version).uniq
    end

    def keep
      ranked.take(@retain)
    end

    # Oldest first: if the fifth removal fails, the four already gone were the
    # least likely to be wanted.
    def removable
      (ranked - keep).reverse.select { |version| removable?(version) }
    end

    def removable?(version)
      @available.include?(version) &&
        !@in_use.include?(version) &&
        !PROTECTED_TAGS.include?(version)
    end
  end
end
