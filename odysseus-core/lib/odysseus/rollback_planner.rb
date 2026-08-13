# lib/odysseus/rollback_planner.rb

module Odysseus
  # Chooses the version a rollback will deploy, from what the hosts report.
  #
  # Pure by design: it is handed surveys and returns a plan or raises. No SSH,
  # no config, no git — so every rule below is testable with plain values, and
  # the fleet pre-flight cannot be accidentally bypassed by a caller that
  # already holds a connection.
  class RollbackPlanner
    # @param surveys [Array<Odysseus::HostVersions>] one per host, all roles
    # @raise [Odysseus::RollbackError] when there are no hosts to act on
    def initialize(surveys)
      raise Odysseus::RollbackError, 'No hosts are configured, so there is nothing to roll back' if surveys.empty?

      @surveys = surveys
    end

    # @param version [String, nil] explicit target, or nil for the previous one
    # @return [Odysseus::RollbackPlan]
    # @raise [Odysseus::RollbackError] when no target can be rolled back to
    def plan(version: nil)
      target = version || previous_version
      raise Odysseus::RollbackError, no_candidate_message if target.nil?

      ensure_present_everywhere!(target)

      RollbackPlan.new(
        version: target,
        ref: ref_for(target),
        approximate: logged_versions.empty?,
        replacing: @surveys.to_h { |survey| [survey.host, survey.current] }
      )
    end

    private

    # The newest version every host can run and none is already running.
    def previous_version
      candidates.find { |version| present_everywhere?(version) && !serving_anywhere?(version) }
    end

    # Versions to consider, best first.
    #
    # The deploy log is preferred because image creation time is *build* time:
    # images can reach a host out of order, and a rebuilt host can hold images
    # it never served. With no log anywhere, docker's newest-first image order
    # is the only signal available, and the plan is marked approximate.
    def candidates
      return logged_versions unless logged_versions.empty?

      # No deploy log exists anywhere to name a specific version, so this is
      # the fallback path. 'latest' is a moving pointer, not a version — the
      # image tagged 'latest' today need not be the one that was running
      # yesterday — so naming it as a rollback target is exactly the
      # ambiguity this whole design exists to remove. Only excluded here: a
      # version the log actually recorded is real and stays a candidate even
      # if, unusually, it is literally tagged 'latest'.
      @surveys.first.available.reject { |version| version == 'latest' }
    end

    # Every logged version across all hosts, newest deploy first, de-duplicated.
    # DeployLog timestamps are fixed-width UTC ISO 8601, so they sort
    # lexicographically; uniq keeps the newest occurrence of each version.
    def logged_versions
      @logged_versions ||= entries.sort_by(&:at).reverse.map(&:version).uniq
    end

    def entries
      @entries ||= @surveys.flat_map(&:history)
    end

    def present_everywhere?(version)
      @surveys.all? { |survey| survey.available?(version) }
    end

    def serving_anywhere?(version)
      @surveys.any? { |survey| survey.current == version }
    end

    # The commit the target was built from, per the most recent log entry that
    # mentions it. DeployLog writes '-' for a field it had no value for, which
    # must read back as absent rather than as a commit called '-'.
    def ref_for(target)
      ref = entries.select { |entry| entry.version == target }.max_by(&:at)&.ref
      ref unless ref.nil? || ref == '-'
    end

    def ensure_present_everywhere!(target)
      missing = @surveys.reject { |survey| survey.available?(target) }.map(&:host)
      return if missing.empty?

      raise Odysseus::RollbackError,
            "Image #{target} is missing on #{missing.join(', ')}, so rolling back would leave the " \
            'fleet on mixed versions. Nothing was changed. Run `odysseus rollback --list` to see ' \
            'what each host has.'
    end

    def no_candidate_message
      running = @surveys.map { |survey| "#{survey.host} is running #{survey.current || 'nothing'}" }

      "No version to roll back to (#{running.join('; ')}). A rollback needs a version that every " \
        'host has an image for and that is not already serving. Run `odysseus rollback --list` to ' \
        'see each host, or name a version explicitly.'
    end
  end
end
