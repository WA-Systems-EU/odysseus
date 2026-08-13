# spec/odysseus/rollback_planner_spec.rb
#
# The planner takes plain values and returns a decision, so there is nothing to
# double here. Every rule below is expressed as data in, plan out.

require 'spec_helper'

RSpec.describe Odysseus::RollbackPlanner do
  def entry_defaults
    { role: 'web', ref: 'main', deployer: 'dev@example.com', kind: 'deployed', from: nil }
  end

  def entry(version:, at:, **overrides)
    Odysseus::DeployLog::Entry.new(**entry_defaults, version: version, at: at, **overrides)
  end

  def host(name, current:, available:, history: [])
    Odysseus::HostVersions.new(host: name, current: current, available: available, history: history)
  end

  # Two deploys: v1 then v2. v2 is serving, both images are present. v1 was
  # logged twice (a re-deploy of the same version from a different ref), so
  # ref recovery must pick the newest of the two rather than either one.
  let(:history) do
    [
      entry(version: 'v1', at: '2026-08-09T09:00:00Z', ref: 'legacy'),
      entry(version: 'v1', at: '2026-08-10T09:00:00Z'),
      entry(version: 'v2', at: '2026-08-12T09:00:00Z')
    ]
  end

  let(:one_host) { [host('host1', current: 'v2', available: %w[v2 v1], history: history)] }

  describe '#plan with no version given' do
    it 'targets the most recently deployed version that is not serving' do
      expect(described_class.new(one_host).plan.version).to eq('v1')
    end

    it 'records what each host is being rolled back from' do
      plan = described_class.new(one_host).plan

      expect(plan.replacing).to eq('host1' => 'v2')
      expect(plan.from_for('host1')).to eq('v2')
    end

    it 'recovers the commit ref of the target from the log' do
      expect(described_class.new(one_host).plan.ref).to eq('main')
    end

    # DeployLog writes '-' for a field it had no value for. Read back as a ref
    # it would be recorded as the literal commit "-".
    it 'treats a dash ref in the log as no ref' do
      log = [entry(version: 'v1', at: '2026-08-10T09:00:00Z', ref: '-'),
             entry(version: 'v2', at: '2026-08-12T09:00:00Z')]
      surveys = [host('host1', current: 'v2', available: %w[v2 v1], history: log)]

      expect(described_class.new(surveys).plan.ref).to be_nil
    end

    it 'skips a logged version whose image has been removed from the host' do
      log = history + [entry(version: 'v3', at: '2026-08-13T09:00:00Z')]
      surveys = [host('host1', current: 'v3', available: %w[v3 v1], history: log)]

      expect(described_class.new(surveys).plan.version).to eq('v1')
    end

    it 'never targets a version that is already serving somewhere' do
      surveys = [
        host('host1', current: 'v2', available: %w[v2 v1], history: history),
        host('host2', current: 'v1', available: %w[v2 v1], history: history)
      ]

      expect { described_class.new(surveys).plan }
        .to raise_error(Odysseus::RollbackError, /No version to roll back to/)
    end

    # DeployLog#entries reads the file top to bottom and #append writes with
    # `>>`, so real logs arrive oldest first. This fixture matches that, with
    # two non-serving candidates, so a planner that forgets to sort (and
    # picks the log's first entry) or forgets to reverse after sorting (and
    # picks the oldest) both land on the wrong version.
    it 'orders by deploy time, not by log line order' do
      log = [entry(version: 'v0', at: '2026-08-01T09:00:00Z'),
             entry(version: 'v1', at: '2026-08-02T09:00:00Z'),
             entry(version: 'v2', at: '2026-08-03T09:00:00Z')]
      surveys = [host('host1', current: 'v2', available: %w[v2 v1 v0], history: log)]

      expect(described_class.new(surveys).plan.version).to eq('v1')
    end

    # uniq keeps a version's newest occurrence, not its first. A version that
    # was deployed, superseded, and then redeployed is "more recent" than a
    # version deployed once in between, because its latest deploy is newest.
    it 'treats a redeployed version as recent as its newest deploy, not its first' do
      log = [entry(version: 'v1', at: '2026-08-01T09:00:00Z'),
             entry(version: 'v2', at: '2026-08-02T09:00:00Z'),
             entry(version: 'v1', at: '2026-08-03T09:00:00Z')]
      surveys = [host('host1', current: 'v3', available: %w[v3 v2 v1], history: log)]

      expect(described_class.new(surveys).plan.version).to eq('v1')
    end

    it 'requires the target to be present on every host' do
      surveys = [
        host('host1', current: 'v2', available: %w[v2 v1], history: history),
        host('host2', current: 'v2', available: %w[v2], history: history)
      ]

      expect { described_class.new(surveys).plan }
        .to raise_error(Odysseus::RollbackError, /No version to roll back to/)
    end

    it 'explains what the hosts are running when there is no candidate' do
      surveys = [host('host1', current: 'v2', available: %w[v2], history: [])]

      expect { described_class.new(surveys).plan }
        .to raise_error(Odysseus::RollbackError, /host1 is running v2/)
    end

    it 'reports a host running nothing rather than printing nil' do
      surveys = [host('host1', current: nil, available: [], history: [])]

      expect { described_class.new(surveys).plan }
        .to raise_error(Odysseus::RollbackError, /host1 is running nothing/)
    end
  end

  describe '#plan with no deploy log on any host' do
    it 'falls back to image order and marks the plan approximate' do
      surveys = [host('host1', current: 'v2', available: %w[v2 v1], history: [])]

      plan = described_class.new(surveys).plan

      expect(plan.version).to eq('v1')
      expect(plan.approximate).to be true
    end

    it 'is not approximate when a log was available' do
      expect(described_class.new(one_host).plan.approximate).to be false
    end

    it 'has no ref to recover' do
      surveys = [host('host1', current: 'v2', available: %w[v2 v1], history: [])]

      expect(described_class.new(surveys).plan.ref).to be_nil
    end
  end

  describe '#plan with an explicit version' do
    it 'uses the version given' do
      surveys = [host('host1', current: 'v2', available: %w[v2 v1 v0], history: history)]

      expect(described_class.new(surveys).plan(version: 'v0').version).to eq('v0')
    end

    # The pre-flight: a half-rolled-back fleet is worse than a refused command,
    # so one host without the image stops all of them.
    it 'refuses when one host of three lacks the image, and names that host' do
      surveys = [
        host('host1', current: 'v2', available: %w[v2 v1], history: history),
        host('host2', current: 'v2', available: %w[v2], history: history),
        host('host3', current: 'v2', available: %w[v2 v1], history: history)
      ]

      expect { described_class.new(surveys).plan(version: 'v1') }
        .to raise_error(Odysseus::RollbackError, /host2/)
    end

    it 'says nothing was changed when it refuses' do
      surveys = [host('host1', current: 'v2', available: %w[v2], history: history)]

      expect { described_class.new(surveys).plan(version: 'v1') }
        .to raise_error(Odysseus::RollbackError, /Nothing was changed/)
    end

    it 'does not name a host that has the image' do
      surveys = [
        host('host1', current: 'v2', available: %w[v2 v1], history: history),
        host('host2', current: 'v2', available: %w[v2], history: history)
      ]

      expect { described_class.new(surveys).plan(version: 'v1') }
        .to raise_error(Odysseus::RollbackError, /missing on host2/)
    end

    # Re-deploying what is already up is a no-op, not an error. Refusing would
    # block the legitimate "put it back the way it was" after a manual change.
    it 'allows the version that is already serving' do
      expect(described_class.new(one_host).plan(version: 'v2').version).to eq('v2')
    end

    # Task 5 writes a from= field per host out of this map. A host silently
    # dropped because it happens to be running nothing would lose its audit
    # record, so the map must carry an explicit nil rather than omit the key.
    it 'keeps a host that is running nothing in the replacing map' do
      surveys = [
        host('host1', current: nil, available: %w[v1], history: []),
        host('host2', current: 'v2', available: %w[v2 v1], history: [])
      ]

      plan = described_class.new(surveys).plan(version: 'v1')

      expect(plan.replacing).to eq('host1' => nil, 'host2' => 'v2')
      expect(plan.from_for('host1')).to be_nil
    end
  end

  describe '#plan with no hosts' do
    it 'refuses rather than returning a plan nothing can act on' do
      expect { described_class.new([]) }
        .to raise_error(Odysseus::RollbackError, /No hosts/)
    end
  end
end
