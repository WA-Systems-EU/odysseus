# spec/odysseus/retention_planner_spec.rb
#
# The planner takes plain values and returns a decision, so there is nothing to
# double. Every rule is expressed as data in, plan out.

require 'spec_helper'

RSpec.describe Odysseus::RetentionPlanner do
  def entry_defaults
    { role: 'web', ref: 'main', deployer: 'dev@example.com', kind: 'deployed', from: nil }
  end

  def entry(version:, at:, **overrides)
    Odysseus::DeployLog::Entry.new(**entry_defaults, version: version, at: at, **overrides)
  end

  # Oldest first, as DeployLog#entries returns them.
  def history_of(*versions)
    versions.each_with_index.map do |version, index|
      entry(version: version, at: format('2026-08-%02dT09:00:00Z', index + 1))
    end
  end

  def plan(history:, available:, in_use: [], retain: 2)
    described_class.new(history: history, available: available, in_use: in_use, retain: retain).plan
  end

  it 'removes versions older than the newest retained ones' do
    result = plan(history: history_of('v1', 'v2', 'v3', 'v4'), available: %w[v1 v2 v3 v4])

    expect(result.remove).to eq(%w[v1 v2])
    expect(result.keep).to eq(%w[v4 v3])
  end

  it 'removes oldest first, so a partial failure leaves the newest behind' do
    result = plan(history: history_of('v1', 'v2', 'v3', 'v4'), available: %w[v1 v2 v3 v4])

    expect(result.remove).to eq(%w[v1 v2])
  end

  it 'removes nothing when the log is within the retain window' do
    expect(plan(history: history_of('v1', 'v2'), available: %w[v1 v2]).remove).to be_empty
  end

  it 'removes nothing when there is no deploy log' do
    expect(plan(history: [], available: %w[v1 v2 v3]).remove).to be_empty
  end

  # The log authorises removal. An image nobody logged might have arrived by
  # hand or from another tool, and deleting it is not this feature's business.
  it 'never removes a version the log does not mention' do
    result = plan(history: history_of('v1', 'v2', 'v3'), available: %w[v1 v2 v3 stray])

    expect(result.remove).not_to include('stray')
  end

  it 'skips a version whose image is already gone' do
    result = plan(history: history_of('v1', 'v2', 'v3', 'v4'), available: %w[v2 v3 v4])

    expect(result.remove).to eq(%w[v2])
  end

  # A container on this host still references it. docker would refuse the
  # removal anyway; refusing here means we do not even try, and the reason is
  # visible in the plan.
  it 'never removes a version a container still references' do
    result = plan(history: history_of('v1', 'v2', 'v3', 'v4'),
                  available: %w[v1 v2 v3 v4], in_use: %w[v1])

    expect(result.remove).to eq(%w[v2])
  end

  # latest is a moving pointer and pre-0.4.2 deploys were built from it, so
  # something may still reference it. cleanup --prune-images is the manual sweep.
  it 'never removes latest' do
    history = history_of('latest', 'v2', 'v3', 'v4')
    result = plan(history: history, available: %w[latest v2 v3 v4])

    expect(result.remove).to eq(%w[v2])
    expect(result.remove).not_to include('latest')
  end

  it 'ranks by deploy time, not by log line order' do
    history = [entry(version: 'v_old', at: '2026-08-01T09:00:00Z'),
               entry(version: 'v_new', at: '2026-08-09T09:00:00Z'),
               entry(version: 'v_mid', at: '2026-08-05T09:00:00Z')]

    result = plan(history: history, available: %w[v_old v_mid v_new], retain: 1)

    expect(result.keep).to eq(%w[v_new])
    expect(result.remove).to eq(%w[v_old v_mid])
  end

  # A version deployed, rolled away from, then deployed again is as recent as
  # its newest deploy — the roll-back-twice case.
  it 'treats a redeployed version as recent as its newest deploy' do
    history = [entry(version: 'v1', at: '2026-08-01T09:00:00Z'),
               entry(version: 'v2', at: '2026-08-02T09:00:00Z'),
               entry(version: 'v3', at: '2026-08-03T09:00:00Z'),
               entry(version: 'v1', at: '2026-08-04T09:00:00Z')]

    result = plan(history: history, available: %w[v1 v2 v3], retain: 2)

    expect(result.keep).to eq(%w[v1 v3])
    expect(result.remove).to eq(%w[v2])
  end

  # Without de-duplication, two entries for the same version each consume a
  # keep slot, so the older-but-distinct version below them is pushed into
  # remove even though it is within the retain window. That is the failure
  # mode a missing .uniq produces: something wanted gets deleted.
  it 'counts a version redeployed with nothing else between as one slot, not two' do
    history = [entry(version: 'v2', at: '2026-08-01T09:00:00Z'),
               entry(version: 'v1', at: '2026-08-02T09:00:00Z'),
               entry(version: 'v1', at: '2026-08-03T09:00:00Z')]

    result = plan(history: history, available: %w[v1 v2], retain: 2)

    expect(result.keep).to eq(%w[v1 v2])
    expect(result.remove).to be_empty
  end

  it 'keeps every logged version when retain exceeds the log' do
    result = plan(history: history_of('v1', 'v2'), available: %w[v1 v2], retain: 10)

    expect(result.remove).to be_empty
    expect(result.keep).to eq(%w[v2 v1])
  end

  # retain: 1 is legal per the spec. It means the previous version becomes
  # eligible immediately, so a rollback will have no candidate — documented,
  # not prevented.
  it 'retains only the newest when retain is 1' do
    result = plan(history: history_of('v1', 'v2'), available: %w[v1 v2], retain: 1)

    expect(result.keep).to eq(%w[v2])
    expect(result.remove).to eq(%w[v1])
  end
end
