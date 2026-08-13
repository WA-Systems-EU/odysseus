# Rollback and Fleet Pre-flight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `odysseus rollback [VERSION]` and `odysseus rollback --list`, which return every role on every host to a previously deployed version, refusing to start unless the target image is present on all of them.

**Architecture:** Rollback is not a second deploy implementation. A pure planner picks a target version from what the hosts report — running container labels, images actually present, and each host's `deploys.log` — and the existing deploy path then runs with that tag, so health gating, proxy handling and zero-downtime behaviour are shared with `deploy` rather than duplicated. The fleet pre-flight lives inside the planner, so a missing image aborts before any host is touched. Along the way, deploy-log recording moves out of the two orchestrators and into `Executor`, which is what lets a rollback record `kind=rolled-back from=<version>` without threading intent through the config hash, and which gives sail-provided strategies the same audit trail.

**Tech Stack:** Ruby 3.2+, Zeitwerk autoloading, `Data.define` value objects, RSpec with `verify_partial_doubles`, RuboCop, net-ssh.

**Spec:** `docs/specs/2026-08-12-deploy-versioning-and-rollback.md` — this plan implements phase 3 ("`rollback` and the fleet pre-flight"). Phases 4 (retention/pruning) and 5 (git notes) are separate plans.

## Global Constraints

- Ruby `>= 3.2.0`; both gems, MIT licensed.
- **No new runtime dependencies.** Rollback uses only net-ssh and the existing Docker client.
- `bundle exec rake` must pass RSpec **and** RuboCop clean in both `odysseus-core` and `odysseus-cli` before any commit.
- `CONTRIBUTING.md` requires each new spec to be checked against a deliberate mutation of the code under test — break the implementation, confirm the new example fails, restore it. A spec that passes against broken code is not done.
- Specs never reach a real server. `Odysseus::Deployer::SSH` and `Odysseus::Docker::Client` are always `instance_double`s.
- `config.warnings = true` is on: no unused variables, no method redefinitions, no shadowed locals.
- Editing `.rubocop_todo.yml` is permitted — regenerate with `bundle exec rubocop --auto-gen-config` if a genuine new Metrics offence appears. Prefer smaller methods to a new exemption, but do not contort code to avoid the file.
- `Odysseus::DeployLog` writes `-` for a blank field. Anything reading the log back must treat `'-'` as absent, not as a literal ref or deployer.
- The log's field positions are load-bearing (`deploy_log.rb:59-73`). Do not change its format in this phase.

---

## File Structure

**Create (odysseus-core):**

| File | Responsibility |
| --- | --- |
| `lib/odysseus/host_versions.rb` | `Odysseus::HostVersions` — what one host knows about one service's versions: what is serving, what images exist, what has served. Includes the reader that gathers it over SSH. |
| `lib/odysseus/rollback_plan.rb` | `Odysseus::RollbackPlan` — the decision a rollback acts on. Pure data. |
| `lib/odysseus/rollback_planner.rb` | `Odysseus::RollbackPlanner` — chooses the target and enforces the fleet pre-flight. Pure: no SSH, no config, no git. |
| `spec/odysseus/host_versions_spec.rb` | Cover for the reader, against doubled SSH. |
| `spec/odysseus/rollback_planner_spec.rb` | Cover for the selection rules. No doubles at all — the planner takes plain values. |
| `spec/fixtures/deploy-multihost.yml` | Two roles across three hosts, so pre-flight refusal is testable. |

**Modify (odysseus-core):**

| File | Change |
| --- | --- |
| `lib/odysseus/errors.rb` | Add `RollbackError < DeployError`. |
| `lib/odysseus/docker/client.rb` | Add `#image_tags(image)`. |
| `lib/odysseus/version_resolver.rb:54` | Make the private `#deployer` public, so rollback can name who did it. |
| `lib/odysseus/deployer/executor.rb` | Extract `#run_deploy`, own `#record_deploy`, add `#version_survey`, `#rollback_plan`, `#rollback_all`. |
| `lib/odysseus/orchestrator/web_deploy.rb:95,182-194` | Remove `record_deploy` — Executor owns it now. |
| `lib/odysseus/orchestrator/job_deploy.rb` | Same removal. |
| `spec/odysseus/orchestrator/web_deploy_spec.rb:265-308` | Deploy-log examples move to `executor_spec.rb`. |
| `spec/odysseus/orchestrator/job_deploy_spec.rb:166-190` | Same. |
| `spec/odysseus/deployer/executor_spec.rb` | Gains the recording examples plus rollback cover. |

**Modify (odysseus-cli):**

| File | Change |
| --- | --- |
| `lib/odysseus/cli/cli.rb` | Add `#rollback`, private `#rollback_list` and `#rollback_rows`. |
| `bin/odysseus` | Register `rollback`, add `--list`, capture the positional VERSION, extend help. |
| `spec/odysseus/cli/cli_spec.rb` | Cover both paths against a doubled executor. |

**Docs:** `odysseus-core/CHANGELOG.md`, `odysseus-cli/CHANGELOG.md`, `odysseus-cli/README.md`, `README.md`, `TODO.md`.

---

### Task 1: `Docker::Client#image_tags`

The host's answer to "which versions could I run?". Everything downstream reads this.

**Files:**
- Modify: `odysseus-core/lib/odysseus/docker/client.rb` (add after `#image_exists?`, line 139)
- Test: `odysseus-core/spec/odysseus/docker/client_spec.rb`

**Interfaces:**
- Consumes: `@ssh.execute(String) -> String` (existing).
- Produces: `Docker::Client#image_tags(image) -> Array<String>` — tags present locally for a repository, newest-created first, with dangling (`<none>`) images dropped.

- [ ] **Step 1: Write the failing tests**

Append inside the existing `RSpec.describe Odysseus::Docker::Client do` block in `spec/odysseus/docker/client_spec.rb`. It already defines `let(:mock_ssh)` and `let(:client)` at lines 7-8; reuse them, do not redefine.

```ruby
  describe '#image_tags' do
    it 'lists the tags docker reports for the repository' do
      allow(mock_ssh).to receive(:execute).and_return("abc123def456\n9f8e7d6c5b4a\nlatest\n")

      expect(client.image_tags('myapp-production')).to eq(%w[abc123def456 9f8e7d6c5b4a latest])
    end

    # A dangling image cannot be named in a docker run, so it can never be a
    # rollback target. Left in, it would be offered as one.
    it 'drops dangling images' do
      allow(mock_ssh).to receive(:execute).and_return("abc123def456\n<none>\nlatest\n")

      expect(client.image_tags('myapp-production')).to eq(%w[abc123def456 latest])
    end

    it 'returns an empty list when the host has no images for the repository' do
      allow(mock_ssh).to receive(:execute).and_return("\n")

      expect(client.image_tags('myapp-production')).to eq([])
    end

    it 'asks docker only for the tag, so the output needs no parsing' do
      expect(mock_ssh).to receive(:execute).with(a_string_including("--format '{{.Tag}}'")).and_return('')

      client.image_tags('myapp-production')
    end

    it 'escapes the repository name' do
      expect(mock_ssh).to receive(:execute).with(a_string_including('my\ app')).and_return('')

      client.image_tags('my app')
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb -e '#image_tags'`
Expected: FAIL, 5 examples, with `NoMethodError: undefined method 'image_tags'`.

- [ ] **Step 3: Write the implementation**

In `lib/odysseus/docker/client.rb`, directly after `#image_exists?`:

```ruby
      # Tags of the images present locally for a repository.
      #
      # docker orders these newest-created first, which is the fallback
      # ordering a rollback uses on a host with no deploy log. Untagged
      # (dangling) images report a tag of '<none>' and are dropped: they cannot
      # be named in a docker run, so they are never rollback targets.
      #
      # @param image [String] repository name, without a tag
      # @return [Array<String>] tags present on this host
      def image_tags(image)
        output = @ssh.execute(
          "docker images #{Shellwords.escape(image)} --format '{{.Tag}}' 2>/dev/null || true"
        )

        output.lines.map(&:strip).reject { |tag| tag.empty? || tag == '<none>' }
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb`
Expected: PASS, all examples.

- [ ] **Step 5: Mutation-check the new examples**

Required by `CONTRIBUTING.md`. One at a time, break the implementation and confirm a *specific* example fails:
1. Delete `|| tag == '<none>'` → "drops dangling images" must fail.
2. Change `'{{.Tag}}'` to `'{{.Repository}}'` → "asks docker only for the tag" must fail.
3. Remove `Shellwords.escape` → "escapes the repository name" must fail.
4. Change `.reject` to `.select` → "lists the tags" must fail.

Restore the implementation after each. If any mutation leaves the whole suite green, that example asserts nothing — fix it before continuing.

- [ ] **Step 6: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib/odysseus/docker/client.rb odysseus-core/spec/odysseus/docker/client_spec.rb
git commit -m "Report the image tags a host has for a repository"
```

---

### Task 2: `HostVersions` — what one host reports

**Files:**
- Create: `odysseus-core/lib/odysseus/host_versions.rb`
- Test: `odysseus-core/spec/odysseus/host_versions_spec.rb`

**Interfaces:**
- Consumes: `Docker::Client#list(service:) -> Array<Hash>`, `Docker::Client#image_tags(image) -> Array<String>` (Task 1), `Docker::Labels.version_of(container) -> String, nil`, `DeployLog#entries -> Array<DeployLog::Entry>`.
- Produces:
  - `Odysseus::HostVersions = Data.define(:host, :current, :available, :history)` where `host: String`, `current: String, nil`, `available: Array<String>`, `history: Array<Odysseus::DeployLog::Entry>` (oldest first, as `DeployLog#entries` returns).
  - `HostVersions.read(host:, ssh:, service:, image:) -> HostVersions`
  - `HostVersions#available?(version) -> Boolean`

Zeitwerk autoloads this — no `require` anywhere.

- [ ] **Step 1: Write the failing test**

Create `odysseus-core/spec/odysseus/host_versions_spec.rb`:

```ruby
# spec/odysseus/host_versions_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::HostVersions do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
  let(:mock_log) { instance_double(Odysseus::DeployLog) }

  let(:entry) do
    Odysseus::DeployLog::Entry.new(
      at: '2026-08-12T11:27:59Z', version: 'abc123def456', role: 'web',
      ref: 'main', deployer: 'dev@example.com', kind: 'deployed', from: nil
    )
  end

  before do
    allow(Odysseus::Docker::Client).to receive(:new).with(mock_ssh).and_return(mock_docker)
    allow(Odysseus::DeployLog).to receive(:new).and_return(mock_log)
    allow(mock_docker).to receive(:list).and_return([])
    allow(mock_docker).to receive(:image_tags).and_return([])
    allow(mock_log).to receive(:entries).and_return([])
  end

  def read
    described_class.read(host: 'host1', ssh: mock_ssh, service: 'myapp', image: 'myapp-production')
  end

  describe '.read' do
    it 'reports the version label of the running container as current' do
      allow(mock_docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.service=myapp,odysseus.version=abc123def456' }]
      )

      expect(read.current).to eq('abc123def456')
    end

    it 'reports current as nil when nothing is running' do
      expect(read.current).to be_nil
    end

    # A container deployed before 0.4.2 carries a timestamp here, not a SHA.
    # Whatever the label says is what is serving, so it is reported verbatim
    # and the planner decides whether an image exists for it.
    it 'reports a legacy timestamp label verbatim' do
      allow(mock_docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.version=20260101120000' }]
      )

      expect(read.current).to eq('20260101120000')
    end

    it 'reports the tags present for the repository as available' do
      allow(mock_docker).to receive(:image_tags).with('myapp-production')
                                               .and_return(%w[abc123def456 9f8e7d6c5b4a])

      expect(read.available).to eq(%w[abc123def456 9f8e7d6c5b4a])
    end

    it 'reads the deploy log of that service on that host' do
      expect(Odysseus::DeployLog).to receive(:new).with(ssh: mock_ssh, service: 'myapp')
                                                  .and_return(mock_log)
      allow(mock_log).to receive(:entries).and_return([entry])

      expect(read.history).to eq([entry])
    end

    it 'carries the host name through for reporting' do
      expect(read.host).to eq('host1')
    end
  end

  describe '#available?' do
    subject(:versions) do
      described_class.new(host: 'host1', current: nil, available: %w[abc123 def456], history: [])
    end

    it 'is true for a tag the host has' do
      expect(versions).to be_available('abc123')
    end

    it 'is false for a tag it does not' do
      expect(versions).not_to be_available('999999')
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/host_versions_spec.rb`
Expected: FAIL, 9 examples, with `NameError: uninitialized constant Odysseus::HostVersions`.

- [ ] **Step 3: Write the implementation**

Create `odysseus-core/lib/odysseus/host_versions.rb`:

```ruby
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/host_versions_spec.rb`
Expected: PASS, 9 examples.

- [ ] **Step 5: Mutation-check**

1. Change `.first` to `.last` in `current_version` → no example fails (only one container in every fixture). **Fix this**: add a second container to the "reports the version label" fixture with a different version and assert the first is chosen. Then the mutation must fail.
2. Swap `current:` and `available:` argument order → the current/available examples must fail.
3. Change `service: service` to `service: image` in the `DeployLog.new` call → "reads the deploy log of that service" must fail.

- [ ] **Step 6: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib/odysseus/host_versions.rb odysseus-core/spec/odysseus/host_versions_spec.rb
git commit -m "Gather what one host knows about a service's versions"
```

---

### Task 3: `RollbackPlanner` — target selection and the fleet pre-flight

The decision logic, kept free of SSH so its rules are testable with plain values. This is the task where a mistake is most expensive, so it gets the most cover.

**Files:**
- Create: `odysseus-core/lib/odysseus/rollback_plan.rb`
- Create: `odysseus-core/lib/odysseus/rollback_planner.rb`
- Modify: `odysseus-core/lib/odysseus/errors.rb`
- Test: `odysseus-core/spec/odysseus/rollback_planner_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::HostVersions` (Task 2) — `#host`, `#current`, `#available`, `#history`, `#available?`.
- Produces:
  - `Odysseus::RollbackError < Odysseus::DeployError`
  - `Odysseus::RollbackPlan = Data.define(:version, :ref, :approximate, :replacing)` where `version: String`, `ref: String, nil`, `approximate: Boolean`, `replacing: Hash{String => String, nil}` mapping host name to the version it is currently running.
  - `RollbackPlan#from_for(host) -> String, nil`
  - `RollbackPlanner.new(surveys)` — `surveys: Array<HostVersions>`; raises `RollbackError` when empty.
  - `RollbackPlanner#plan(version: nil) -> RollbackPlan`; raises `RollbackError` with an actionable message.

- [ ] **Step 1: Add the error class**

In `odysseus-core/lib/odysseus/errors.rb`, under the existing `DeployError` group:

```ruby
  class DeployError < Error; end
  class RollbackError < DeployError; end
  class SSHError < DeployError; end
```

- [ ] **Step 2: Write the failing test**

Create `odysseus-core/spec/odysseus/rollback_planner_spec.rb`:

```ruby
# spec/odysseus/rollback_planner_spec.rb
#
# The planner takes plain values and returns a decision, so there is nothing to
# double here. Every rule below is expressed as data in, plan out.

require 'spec_helper'

RSpec.describe Odysseus::RollbackPlanner do
  def entry(version:, at:, role: 'web', ref: 'main', deployer: 'dev@example.com',
            kind: 'deployed', from: nil)
    Odysseus::DeployLog::Entry.new(
      at: at, version: version, role: role, ref: ref, deployer: deployer, kind: kind, from: from
    )
  end

  def host(name, current:, available:, history: [])
    Odysseus::HostVersions.new(host: name, current: current, available: available, history: history)
  end

  # Two deploys: v1 then v2. v2 is serving, both images are present.
  let(:history) do
    [
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

    it 'orders by deploy time, not by log line order' do
      log = [entry(version: 'v1', at: '2026-08-12T09:00:00Z'),
             entry(version: 'v0', at: '2026-08-01T09:00:00Z')]
      surveys = [host('host1', current: 'v2', available: %w[v2 v1 v0], history: log)]

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
  end

  describe '#plan with no hosts' do
    it 'refuses rather than returning a plan nothing can act on' do
      expect { described_class.new([]) }
        .to raise_error(Odysseus::RollbackError, /No hosts/)
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/rollback_planner_spec.rb`
Expected: FAIL, 19 examples, `NameError: uninitialized constant Odysseus::RollbackPlanner`.

- [ ] **Step 4: Write `RollbackPlan`**

Create `odysseus-core/lib/odysseus/rollback_plan.rb`:

```ruby
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
```

- [ ] **Step 5: Write `RollbackPlanner`**

Create `odysseus-core/lib/odysseus/rollback_planner.rb`:

```ruby
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

      @surveys.first.available
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
            "No image tagged #{target} is present on #{missing.join(', ')}, so rolling back would " \
            'leave the fleet on mixed versions. Nothing was changed. Run `odysseus rollback --list` ' \
            'to see what each host has.'
    end

    def no_candidate_message
      running = @surveys.map { |survey| "#{survey.host} is running #{survey.current || 'nothing'}" }

      "No version to roll back to (#{running.join('; ')}). A rollback needs a version that every " \
        'host has an image for and that is not already serving. Run `odysseus rollback --list` to ' \
        'see each host, or name a version explicitly.'
    end
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/rollback_planner_spec.rb`
Expected: PASS, 19 examples.

- [ ] **Step 7: Mutation-check**

Each mutation must break a *named* example:
1. `.reverse` removed from `logged_versions` → "targets the most recently deployed version" fails.
2. `!serving_anywhere?(version)` → `true` → "never targets a version that is already serving" fails.
3. `present_everywhere?` `.all?` → `.any?` → "requires the target to be present on every host" fails.
4. `ref unless ref.nil? || ref == '-'` → `ref` → "treats a dash ref in the log as no ref" fails.
5. `ensure_present_everywhere!` body replaced with `return` → "refuses when one host of three lacks the image" fails.
6. `approximate:` hardcoded to `false` → "falls back to image order and marks the plan approximate" fails.
7. `.max_by(&:at)` → `.min_by(&:at)` → add a second log entry for `v1` with a different ref if no example fails, so ref recovery is pinned to the newest entry.
8. `survey.current || 'nothing'` → `survey.current` → "reports a host running nothing" fails.

- [ ] **Step 8: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib/odysseus/errors.rb odysseus-core/lib/odysseus/rollback_plan.rb \
        odysseus-core/lib/odysseus/rollback_planner.rb \
        odysseus-core/spec/odysseus/rollback_planner_spec.rb
git commit -m "Choose a rollback target from what the hosts actually have"
```

---

### Task 4: Move deploy-log recording into `Executor`

A refactor with no new user-visible behaviour, done before rollback needs it. Three reasons it belongs here rather than staying in the orchestrators:

1. A rollback must record `kind=rolled-back from=<version>`. Recording inside the orchestrator means threading deploy *intent* through the config hash — the config hash is the only channel, because the sail plugin contract fixes the constructor keywords at `ssh:, config:, logger:, secrets_loader:`. `Executor` already knows the intent natively.
2. A sail-provided strategy currently gets no audit trail at all. In `Executor`, every role is recorded regardless of which orchestrator ran it.
3. The logic is duplicated in `web_deploy.rb` and `job_deploy.rb` today.

`Executor` holds the SSH connection at exactly the right point (`deploy_role` opens it, the orchestrator returns, the `ensure` closes it), so nothing new has to be opened.

**Files:**
- Modify: `odysseus-core/lib/odysseus/deployer/executor.rb:168-187` (`deploy_role`)
- Modify: `odysseus-core/lib/odysseus/orchestrator/web_deploy.rb` (remove line 95 and the method at 176-194)
- Modify: `odysseus-core/lib/odysseus/orchestrator/job_deploy.rb` (remove the equivalent call and method)
- Modify: `odysseus-core/spec/odysseus/orchestrator/web_deploy_spec.rb:265-308` (move examples out)
- Modify: `odysseus-core/spec/odysseus/orchestrator/job_deploy_spec.rb:166-190` (move examples out)
- Test: `odysseus-core/spec/odysseus/deployer/executor_spec.rb`

**Interfaces:**
- Consumes: `DeployLog#append(version:, role:, ref:, deployer:, kind:, from:)`, `DeployVersion#version/#ref/#deployer`.
- Produces:
  - `Executor#deploy_role(host:, role:, image_tag: nil, dry_run: false)` — unchanged signature and return value.
  - private `Executor#run_deploy(host:, role:, resolved:, kind: 'deployed', from: nil) -> Hash` — connect, deploy, record, close. **Task 5 calls this.**
  - private `Executor#record_deploy(ssh:, host:, role:, resolved:, kind:, from:) -> void` — best effort, never raises.

- [ ] **Step 1: Move the existing examples to `executor_spec.rb`**

Cut these from `spec/odysseus/orchestrator/web_deploy_spec.rb` (the `let(:deploy_log)`, its `before`, and four examples at lines 265-308): "records the deploy on the host", "does not record anything when the deploy fails", "still succeeds when the log cannot be written", "still succeeds when writing the log raises a raw connection error".

Cut the equivalent block from `spec/odysseus/orchestrator/job_deploy_spec.rb` (lines 166-190).

Keep everything else in both files — the container-naming and label examples still describe the orchestrators.

Add to `spec/odysseus/deployer/executor_spec.rb`, inside the top-level describe. The suite already has `mock_ssh` and `mock_orchestrator`; check the existing `before` block at lines 11-16 and reuse it rather than redefining:

```ruby
  describe 'recording the deploy on the host' do
    let(:deploy_log) { instance_double(Odysseus::DeployLog) }
    let(:resolver) { instance_double(Odysseus::VersionResolver) }
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
    end

    before do
      allow(Odysseus::VersionResolver).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:resolve).and_return(resolved)
      allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
      allow(deploy_log).to receive(:append)
      # The top-level before stubs SSH.new and #close only; each describe block
      # stubs its own orchestrator. Without this the real WebDeploy is built and
      # #deploy reaches the Docker client.
      allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
      allow(mock_orchestrator).to receive(:deploy).and_return(success: true)
    end

    it 'records the version, role, ref and deployer for the service' do
      expect(Odysseus::DeployLog).to receive(:new).with(ssh: mock_ssh, service: 'myapp')
                                                  .and_return(deploy_log)
      expect(deploy_log).to receive(:append).with(
        version: 'abc123def456', role: :web, ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )

      executor.deploy_role(host: 'app1.example.com', role: :web)
    end

    it 'records nothing when the orchestrator raises' do
      allow(mock_orchestrator).to receive(:deploy)
        .and_raise(Odysseus::DeployError, 'Container failed health checks')
      expect(deploy_log).not_to receive(:append)

      expect { executor.deploy_role(host: 'app1.example.com', role: :web) }
        .to raise_error(Odysseus::DeployError)
    end

    it 'still reports success when the log cannot be written' do
      allow(deploy_log).to receive(:append).and_raise(Odysseus::SSHCommandError, 'read-only fs')

      expect(executor.deploy_role(host: 'app1.example.com', role: :web)).to include(success: true)
    end

    # Net::SSH::Disconnect, IOError and Net::SSH::ChannelOpenFailed all
    # propagate through SSH#execute untranslated. Traffic has already switched
    # to the new container by this point, so none of them may turn a completed
    # deploy into a reported failure.
    it 'still reports success when writing the log raises a raw connection error' do
      allow(deploy_log).to receive(:append).and_raise(IOError, 'connection reset')

      expect(executor.deploy_role(host: 'app1.example.com', role: :web)).to include(success: true)
    end

    it 'closes the connection even when recording fails' do
      allow(deploy_log).to receive(:append).and_raise(IOError, 'connection reset')
      expect(mock_ssh).to receive(:close)

      executor.deploy_role(host: 'app1.example.com', role: :web)
    end

  end
```

The claim that a sail-provided strategy now gets recorded needs a role whose
config names a strategy, which `deploy.yml` does not have — so that example
lives in Task 5, against the multi-host fixture, which does. Do not try to
write it here: with no `deploy.strategy`, `build_orchestrator` returns
`WebDeploy` and the example would silently prove nothing about sails.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/deployer/executor_spec.rb -e 'recording the deploy'`
Expected: FAIL — `DeployLog.new` is never called, because `Executor` does not record yet.

Also run the two orchestrator specs to confirm the cut examples are gone and the rest still pass:
Run: `bundle exec rspec spec/odysseus/orchestrator/`
Expected: PASS, with 4 fewer examples in `web_deploy_spec` and 1 fewer in `job_deploy_spec`.

- [ ] **Step 3: Rewrite `Executor#deploy_role`**

Replace `deploy_role` (lines 168-187) with:

```ruby
      # Deploy a single role to a specific host
      # @param host [String] target host (from config)
      # @param image_tag [String, nil] docker image tag, or nil to resolve from git
      # @param dry_run [Boolean] if true, don't actually deploy
      # @param role [Symbol] server role
      def deploy_role(host:, role:, image_tag: nil, dry_run: false)
        resolved = deploy_version(image_tag)

        if dry_run
          puts "Dry run - would deploy #{@config[:image]}:#{resolved.version} to #{host}"
          puts "Service: #{@config[:service]}"
          puts "Role: #{role}"
          puts "Proxy hosts: #{@config[:proxy][:hosts].join(', ')}" if role == WEB_ROLE
          return { success: true, dry_run: true }
        end

        run_deploy(host: host, role: role, resolved: resolved)
      end
```

Then add to the `private` section, next to `build_orchestrator`:

```ruby
      # One role on one host: connect, hand off to the orchestrator, record the
      # outcome on the host, close. Shared by deploy and rollback so both get
      # identical health gating, proxy handling and audit trail.
      #
      # @param kind [String] 'deployed' or 'rolled-back'
      # @param from [String, nil] the version being replaced, for a rollback
      def run_deploy(host:, role:, resolved:, kind: 'deployed', from: nil)
        ssh = connect_to_server(host)

        begin
          orchestrator = build_orchestrator(ssh, role, resolved)
          result = orchestrator.deploy(image_tag: resolved.version, role: role)
          record_deploy(ssh: ssh, host: host, role: role, resolved: resolved, kind: kind, from: from)
          result
        ensure
          ssh.close
        end
      end

      # The host's own record of what it is running, written only after the
      # orchestrator reports success.
      #
      # Best effort, and deliberately rescuing StandardError rather than
      # Odysseus::Error: SSH#execute can also raise Net::SSH::Disconnect,
      # IOError or Net::SSH::ChannelOpenFailed, none of which with_connection
      # translates. Traffic has already switched by this point, so any of them
      # escaping here would turn a completed deploy into a reported failure.
      def record_deploy(ssh:, host:, role:, resolved:, kind:, from:)
        Odysseus::DeployLog.new(ssh: ssh, service: @config[:service]).append(
          version: resolved.version, role: role, ref: resolved.ref,
          deployer: resolved.deployer, kind: kind, from: from
        )
      rescue StandardError => e
        build_logger.warn("Could not record the deploy on #{host}: #{e.message}")
      end
```

- [ ] **Step 4: Remove recording from both orchestrators**

In `lib/odysseus/orchestrator/web_deploy.rb`, delete the `record_deploy(role)` call (line 95) and the whole `record_deploy` method with its comment block (lines 176-194).

In `lib/odysseus/orchestrator/job_deploy.rb`, delete the equivalent call and method — grep for `record_deploy` to find both.

Leave `deploy_version_tag` and `version_labels` in place in both: the container name and labels are still the orchestrator's job.

- [ ] **Step 5: Run the full core suite**

Run: `cd odysseus-core && bundle exec rspec`
Expected: PASS. Total example count drops by 5 from the orchestrator specs and rises by 5-6 in `executor_spec`.

If `web_deploy_spec` or `job_deploy_spec` now fails on an unrelated example, it is because their `before` blocks stubbed `Odysseus::DeployLog`; that stub is now unused, and with `config.warnings = true` an unused `let` is not an error but a leftover `allow` on a no-longer-called constant is dead weight. Remove any leftovers.

- [ ] **Step 6: Mutation-check**

1. Move `record_deploy` above `orchestrator.deploy` in `run_deploy` → "records nothing when the orchestrator raises" must fail.
2. Change `rescue StandardError` to `rescue Odysseus::Error` → "still reports success when writing the log raises a raw connection error" must fail.
3. Remove the `rescue` entirely → "still reports success when the log cannot be written" must fail.
4. Hardcode `kind: 'deployed'` in the `append` call → nothing fails yet; that is expected, Task 5 pins it.

- [ ] **Step 7: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib/odysseus/deployer/executor.rb \
        odysseus-core/lib/odysseus/orchestrator/web_deploy.rb \
        odysseus-core/lib/odysseus/orchestrator/job_deploy.rb \
        odysseus-core/spec/
git commit -m "Record deploys in Executor rather than in each orchestrator

Puts recording where the deploy intent is known, so a rollback can record
what it rolled back from, and so a sail-provided strategy gets the same
audit trail instead of none."
```

---

### Task 5: `Executor#version_survey`, `#rollback_plan` and `#rollback_all`

**Files:**
- Modify: `odysseus-core/lib/odysseus/deployer/executor.rb`
- Modify: `odysseus-core/lib/odysseus/version_resolver.rb:54` (make `#deployer` public)
- Create: `odysseus-core/spec/fixtures/deploy-multihost.yml`
- Test: `odysseus-core/spec/odysseus/deployer/executor_spec.rb`

**Interfaces:**
- Consumes: `HostVersions.read` (Task 2), `RollbackPlanner#plan` (Task 3), `Executor#run_deploy` (Task 4), `VersionResolver#deployer`.
- Produces:
  - `Executor#version_survey -> Array<Odysseus::HostVersions>` — one per unique host across all roles, in config order.
  - `Executor#rollback_plan(version: nil) -> Odysseus::RollbackPlan` — surveys, then plans. Raises `RollbackError`.
  - `Executor#rollback_all(plan) -> Hash{String => Hash}` — keyed `"role@host"`, same shape as `deploy_all`.

Two calls rather than one so the CLI can show the target and any warning before acting, and so the survey runs once.

- [ ] **Step 1: Create the multi-host fixture**

Create `odysseus-core/spec/fixtures/deploy-multihost.yml`:

```yaml
# spec/fixtures/deploy-multihost.yml
# Three roles over three hosts, with cron sharing web1: four role/host pairs
# but only three hosts, so per-host survey de-duplication is provable. cron
# also names a deploy strategy, so the sail path is reachable.

service: myapp
image: myapp-production

servers:
  web:
    hosts:
      - web1.example.com
      - web2.example.com
  jobs:
    hosts:
      - jobs1.example.com
    cmd: bundle exec sidekiq
  cron:
    hosts:
      - web1.example.com
    cmd: bundle exec whenever
    deploy:
      strategy: rolling

proxy:
  ssl: false
  hosts:
    - app.example.com
  app_port: 3000
  healthcheck:
    path: "/health"

env:
  clear:
    RAILS_ENV: production

ssh:
  user: root
  keys:
    - ~/.ssh/id_ed25519
```

- [ ] **Step 2: Write the failing tests**

Add to `spec/odysseus/deployer/executor_spec.rb`:

```ruby
  describe 'rollback' do
    let(:multihost) { described_class.new(fixture_path('deploy-multihost.yml')) }
    let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
    let(:deploy_log) { instance_double(Odysseus::DeployLog) }

    # The fixture's cron role names deploy.strategy: rolling, and the config
    # validator refuses a strategy that is not registered (validators/config.rb:88)
    # — so the sail has to exist before the config parses. That makes every
    # example here exercise a sail-deployed role alongside the built-in
    # orchestrators, which is what pins "a sail role gets recorded too".
    let(:sail_class) do
      Class.new do
        def initialize(ssh:, config:, logger:, secrets_loader:); end

        def deploy(image_tag:, role:)
          { success: true, image_tag: image_tag, role: role }
        end
      end
    end

    # sails_spec.rb:8 and validators/config_spec.rb:182 both guard the global
    # registry with around/reset!; match that so example order cannot matter.
    around do |example|
      Odysseus::Sails.reset!
      Odysseus::Sails.register(:rolling, sail_class)
      example.run
      Odysseus::Sails.reset!
    end

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
      allow(mock_ssh).to receive(:close)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(mock_docker)
      allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
      allow(deploy_log).to receive(:append)
      allow(deploy_log).to receive(:entries).and_return([])
      allow(mock_docker).to receive(:list).and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.version=v2' }]
      )
      allow(mock_docker).to receive(:image_tags).and_return(%w[v2 v1])
    end

    describe '#version_survey' do
      # The fixture has four role/host pairs over three hosts: cron shares
      # web1 with web. Surveying a host twice would open two connections and
      # report it twice in rollback --list.
      it 'reports one entry per host even when a host serves two roles' do
        expect(multihost.version_survey.map(&:host))
          .to eq(%w[web1.example.com web2.example.com jobs1.example.com])
      end

      it 'closes every connection it opened' do
        expect(mock_ssh).to receive(:close).exactly(3).times

        multihost.version_survey
      end

      it 'closes the connection even when reading a host fails' do
        allow(mock_docker).to receive(:image_tags).and_raise(Odysseus::SSHCommandError, 'no docker')
        expect(mock_ssh).to receive(:close).at_least(:once)

        expect { multihost.version_survey }.to raise_error(Odysseus::SSHCommandError)
      end
    end

    describe '#rollback_plan' do
      it 'plans against every host, not just the first' do
        plan = multihost.rollback_plan

        expect(plan.version).to eq('v1')
        expect(plan.replacing.keys)
          .to eq(%w[web1.example.com web2.example.com jobs1.example.com])
      end

      it 'refuses when the target is missing on one host' do
        tags = { 'web1.example.com' => %w[v2 v1], 'web2.example.com' => %w[v2],
                 'jobs1.example.com' => %w[v2 v1] }
        seen = []
        allow(Odysseus::Deployer::SSH).to receive(:new) { |args| seen << args[:host]; mock_ssh }
        allow(mock_docker).to receive(:image_tags) { tags.fetch(seen.last) }

        expect { multihost.rollback_plan(version: 'v1') }
          .to raise_error(Odysseus::RollbackError, /web2\.example\.com/)
      end
    end

    describe '#rollback_all' do
      let(:plan) do
        Odysseus::RollbackPlan.new(
          version: 'v1', ref: 'main', approximate: false,
          replacing: { 'web1.example.com' => 'v2', 'web2.example.com' => 'v2',
                       'jobs1.example.com' => 'v2' }
        )
      end

      before do
        allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(Odysseus::Orchestrator::JobDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(mock_orchestrator).to receive(:deploy).and_return(success: true)
      end

      it 'deploys the planned version to every role on every host' do
        expect(mock_orchestrator).to receive(:deploy).with(image_tag: 'v1', role: :web).twice
        expect(mock_orchestrator).to receive(:deploy).with(image_tag: 'v1', role: :jobs).once

        multihost.rollback_all(plan)
      end

      it 'returns results keyed by role@host, including a shared host twice' do
        expect(multihost.rollback_all(plan).keys).to contain_exactly(
          'web@web1.example.com', 'web@web2.example.com',
          'jobs@jobs1.example.com', 'cron@web1.example.com'
        )
      end

      # cron is deployed by the sail, not by WebDeploy or JobDeploy. Before
      # recording moved into Executor, a sail-deployed role left no trace in
      # deploys.log at all, which would make it invisible to a later rollback.
      it 'records a role that a sail strategy deployed' do
        expect(deploy_log).to receive(:append).with(hash_including(role: :cron))

        multihost.rollback_all(plan)
      end

      it 'records the rollback as such, naming the version it came from' do
        expect(deploy_log).to receive(:append).with(
          hash_including(version: 'v1', kind: 'rolled-back', from: 'v2')
        ).at_least(:once)

        multihost.rollback_all(plan)
      end

      it 'carries the commit ref recovered by the plan into the record' do
        expect(deploy_log).to receive(:append).with(hash_including(ref: 'main')).at_least(:once)

        multihost.rollback_all(plan)
      end

      it 'names who ran the rollback rather than leaving it blank' do
        expect(deploy_log).to receive(:append)
          .with(hash_including(deployer: a_string_matching(/\S/))).at_least(:once)

        multihost.rollback_all(plan)
      end

      # The label a container carries must be the version it is actually
      # running, or status and the next rollback both lie.
      it 'labels the rolled-back container with the target version' do
        expect(Odysseus::Orchestrator::WebDeploy).to receive(:new) do |args|
          expect(args[:config][:deploy_version].version).to eq('v1')
          mock_orchestrator
        end.at_least(:once)

        multihost.rollback_all(plan)
      end
    end
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/deployer/executor_spec.rb -e 'rollback'`
Expected: FAIL, `NoMethodError: undefined method 'version_survey'`.

- [ ] **Step 4: Make `VersionResolver#deployer` public**

In `lib/odysseus/version_resolver.rb`, move `deployer` above the `private` keyword and document it:

```ruby
    # Who is running this command: git's configured email, falling back to the
    # shell user. Works outside a repository — `git config user.email` reads
    # global config — so a rollback can name a deployer even when the version
    # came from a host rather than a commit.
    #
    # @return [String]
    def deployer
      git.committer_email || ENV.fetch('USER', 'unknown')
    end

    private
```

- [ ] **Step 5: Add the three methods to `Executor`**

Add to the public section, after `deploy_all`:

```ruby
      # What every host reports about this service's versions.
      #
      # One entry per unique host across all roles, so a host serving two roles
      # is surveyed once. Connections are opened and closed per host.
      #
      # @return [Array<Odysseus::HostVersions>]
      def version_survey
        collect_all_hosts.map do |host|
          ssh = connect_to_server(host)

          begin
            Odysseus::HostVersions.read(
              host: host, ssh: ssh, service: @config[:service], image: @config[:image]
            )
          ensure
            ssh.close
          end
        end
      end

      # Decide what a rollback would do, without doing it.
      #
      # Surveys the fleet and returns the plan, or raises RollbackError with a
      # message naming the hosts at fault. Separate from rollback_all so the
      # caller can show the target — and any approximate-ordering warning —
      # before anything is touched, and so the survey runs once.
      #
      # @param version [String, nil] explicit target, or nil for the previous one
      # @return [Odysseus::RollbackPlan]
      def rollback_plan(version: nil)
        Odysseus::RollbackPlanner.new(version_survey).plan(version: version)
      end

      # Roll every role on every host back to the planned version.
      #
      # Reuses the deploy path unchanged, so health gating, proxy handling and
      # zero-downtime behaviour are shared with deploy rather than
      # reimplemented. Sequential, and inheriting deploy's partial-failure
      # semantics: the plan's pre-flight rules out the common cause of a
      # half-rolled-back fleet — a missing image — but does not make the roll
      # atomic.
      #
      # @param plan [Odysseus::RollbackPlan] from #rollback_plan
      # @return [Hash] results keyed "role@host"
      def rollback_all(plan)
        resolved = Odysseus::DeployVersion.new(
          version: plan.version, ref: plan.ref, deployer: version_resolver.deployer
        )
        results = {}

        @config[:servers].each do |role, role_config|
          resolve_hosts(role_config).each do |host|
            puts "\n=== Rolling back #{role} on #{host} to #{plan.version} ==="
            results["#{role}@#{host}"] = run_deploy(
              host: host, role: role, resolved: resolved,
              kind: 'rolled-back', from: plan.from_for(host)
            )
          end
        end

        results
      end
```

- [ ] **Step 6: Run to verify passing**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/deployer/executor_spec.rb`
Expected: PASS.

Then the whole suite: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 7: Mutation-check**

1. `kind: 'rolled-back'` → `kind: 'deployed'` → "records the rollback as such" fails.
2. `from: plan.from_for(host)` → `from: nil` → same example fails on the `from: 'v2'` expectation.
3. `ref: plan.ref` → `ref: nil` → "carries the commit ref" fails.
4. `deployer: version_resolver.deployer` → `deployer: nil` → "names who ran the rollback" fails.
5. `collect_all_hosts` → `@config[:servers].keys` in `version_survey` → "reports one entry per unique host" fails.
6. Remove the `ensure ssh.close` in `version_survey` → "closes every connection" fails.
7. `plan.version` → `'latest'` in the `DeployVersion` → "labels the rolled-back container" fails.

- [ ] **Step 8: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib odysseus-core/spec
git commit -m "Survey the fleet and roll it back through the deploy path"
```

---

### Task 6: The `rollback` command

**Files:**
- Modify: `odysseus-cli/lib/odysseus/cli/cli.rb`
- Modify: `odysseus-cli/bin/odysseus`
- Test: `odysseus-cli/spec/odysseus/cli/cli_spec.rb`

**Interfaces:**
- Consumes: `Executor#rollback_plan(version:) -> RollbackPlan`, `Executor#rollback_all(plan) -> Hash`, `Executor#version_survey -> Array<HostVersions>`, `RollbackPlan#version/#ref/#approximate`, `HostVersions#host/#current/#history/#available?`, `UI#header/#info/#blank/#warn/#section/#step/#table/#spin_step/#stream_steps/#step_fail`.
- Produces: `CLI#rollback(options = {})` where `options[:version]`, `options[:list]`, `options[:config]`, `options[:verbose]`.

- [ ] **Step 1: Write the failing tests**

Add to `odysseus-cli/spec/odysseus/cli/cli_spec.rb`. The file already stubs `Odysseus::Deployer::Executor.new` to return `executor` in its top-level `before`:

```ruby
  describe '#rollback' do
    let(:plan) do
      Odysseus::RollbackPlan.new(
        version: 'v1', ref: 'main', approximate: false,
        replacing: { 'web1.example.com' => 'v2' }
      )
    end

    before { allow(executor).to receive(:rollback_plan).and_return(plan) }

    it 'rolls back to the planned version' do
      expect(executor).to receive(:rollback_all).with(plan)

      output_of { cli.rollback(config: config_file) }
    end

    it 'shows the target version before acting' do
      allow(executor).to receive(:rollback_all)

      expect(output_of { cli.rollback(config: config_file) }).to include('v1')
    end

    it 'shows the commit the target was built from' do
      allow(executor).to receive(:rollback_all)

      expect(output_of { cli.rollback(config: config_file) }).to include('main')
    end

    it 'passes an explicit version through to the planner' do
      expect(executor).to receive(:rollback_plan).with(version: 'v0').and_return(plan)
      allow(executor).to receive(:rollback_all)

      output_of { cli.rollback(config: config_file, version: 'v0') }
    end

    it 'warns when the ordering is only approximate' do
      approximate = Odysseus::RollbackPlan.new(
        version: 'v1', ref: nil, approximate: true, replacing: {}
      )
      allow(executor).to receive(:rollback_plan).and_return(approximate)
      allow(executor).to receive(:rollback_all)

      expect(output_of { cli.rollback(config: config_file) }).to match(/approximate/i)
    end

    it 'reports a refused rollback and exits non-zero without deploying' do
      allow(executor).to receive(:rollback_plan)
        .and_raise(Odysseus::RollbackError, 'No image tagged v1 is present on web2.example.com')
      expect(executor).not_to receive(:rollback_all)

      expect { output_of { cli.rollback(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('web2.example.com')
    end

    it 'reports a failed rollback and exits non-zero' do
      allow(executor).to receive(:rollback_all)
        .and_raise(Odysseus::DeployError, 'Container failed health checks')

      expect { output_of { cli.rollback(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('failed health checks')
    end
  end

  describe '#rollback --list' do
    let(:entry) do
      Odysseus::DeployLog::Entry.new(
        at: '2026-08-12T11:27:59Z', version: 'v2', role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
    end
    let(:older) do
      Odysseus::DeployLog::Entry.new(
        at: '2026-08-10T09:00:00Z', version: 'v1', role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
    end
    let(:survey) do
      [Odysseus::HostVersions.new(
        host: 'web1.example.com', current: 'v2', available: %w[v2], history: [older, entry]
      )]
    end

    before { allow(executor).to receive(:version_survey).and_return(survey) }

    it 'lists each host and what it is serving' do
      out = output_of { cli.rollback(config: config_file, list: true) }

      expect(out).to include('web1.example.com')
      expect(out).to include('v2')
    end

    it 'marks a version whose image is gone as unavailable' do
      out = output_of { cli.rollback(config: config_file, list: true) }

      expect(out).to include('missing')
    end

    it 'marks a version whose image is present' do
      out = output_of { cli.rollback(config: config_file, list: true) }

      expect(out).to include('present')
    end

    it 'does not roll anything back' do
      expect(executor).not_to receive(:rollback_all)
      expect(executor).not_to receive(:rollback_plan)

      output_of { cli.rollback(config: config_file, list: true) }
    end

    it 'says so when a host has no deploy history' do
      allow(executor).to receive(:version_survey).and_return(
        [Odysseus::HostVersions.new(host: 'web1.example.com', current: nil,
                                    available: [], history: [])]
      )

      expect(output_of { cli.rollback(config: config_file, list: true) })
        .to match(/no deploy history/i)
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd odysseus-cli && bundle exec rspec spec/odysseus/cli/cli_spec.rb -e rollback`
Expected: FAIL, `NoMethodError: undefined method 'rollback'`.

- [ ] **Step 3: Implement the command**

In `odysseus-cli/lib/odysseus/cli/cli.rb`, after `#deploy` (which ends at line 65):

```ruby
      # Rollback command
      def rollback(options = {})
        config_file = options[:config] || 'deploy.yml'
        verbose = options[:verbose] || @ui.debug?

        config = load_config(config_file)
        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)

        return rollback_list(executor, config) if options[:list]

        plan = @ui.spin_step('Checking what every host can run') do
          executor.rollback_plan(version: options[:version])
        end

        @ui.blank
        @ui.info 'Service', config[:service]
        @ui.info 'Rolling back to', "#{config[:image]}:#{plan.version}"
        @ui.info 'Commit', plan.ref if plan.ref
        if plan.approximate
          @ui.warn 'No host had a deploy log, so the previous version was taken from image ' \
                   'creation time and the ordering is approximate'
        end
        @ui.blank

        start_time = Time.now

        @ui.stream_steps(title: 'Rolling back service') do
          executor.rollback_all(plan)
        end

        @ui.deploy_complete(duration: (Time.now - start_time).round(1))
      rescue Odysseus::Error => e
        @ui.step_fail e.message
        exit 1
      end
```

Then in the private section:

```ruby
      # rollback --list: what each host has, without changing anything.
      # Reads only the hosts, so it works without a git repository.
      def rollback_list(executor, config)
        survey = @ui.spin_step('Reading versions from hosts') { executor.version_survey }

        @ui.blank
        @ui.info 'Service', config[:service]
        @ui.blank

        survey.each do |host_versions|
          @ui.section host_versions.host
          @ui.info 'Serving', host_versions.current || '(nothing running)'

          rows = rollback_rows(host_versions)
          if rows.empty?
            @ui.step '(no deploy history on this host)'
          else
            @ui.table(headers: %w[Version Deployed Ref Deployer Image], rows: rows)
          end
          @ui.blank
        end
      end

      # One row per distinct version, most recently deployed first. A version
      # deployed repeatedly is reported once, at its latest deploy time.
      def rollback_rows(host_versions)
        latest = {}
        host_versions.history.each { |e| latest[e.version] = e }

        latest.values.reverse.map do |e|
          [e.version, e.at, e.ref, e.deployer,
           host_versions.available?(e.version) ? 'present' : 'missing']
        end
      end
```

`history` is oldest-first, so assigning into `latest` keyed by version keeps each version's newest entry, and `.reverse` on the values puts the most recent version first (Ruby hashes preserve insertion order).

- [ ] **Step 4: Run to verify passing**

Run: `cd odysseus-cli && bundle exec rspec spec/odysseus/cli/cli_spec.rb`
Expected: PASS.

- [ ] **Step 5: Wire up `bin/odysseus`**

Add to the `commands` hash (after the `'deploy'` line):

```ruby
    'rollback' => { method: :rollback, needs_server: false },
```

Add to the global `OptionParser` block, after the `--dry-run` line:

```ruby
    opts.on('--list', 'List rollback candidates per host without changing anything') { |v| options[:list] = v }
```

After `end.parse!(command_args)` and before `cmd_info = commands[command]`, add:

```ruby
  # rollback takes an optional positional VERSION; OptionParser#parse! has
  # already removed the flags, so anything left is that argument.
  options[:version] = command_args[0] if command == 'rollback' && command_args[0]
```

In `print_help`, add to the Commands list after `deploy`:

```ruby
  puts '  rollback [VERSION]        Roll every role back to a previously deployed version'
```

and a new options section after "Deploy options:":

```ruby
  puts 'Rollback options:'
  puts '  --list                    Show each host: versions deployed, which images remain,'
  puts '                            and what is serving. Changes nothing.'
  puts ''
```

- [ ] **Step 6: Verify the command is reachable**

```bash
cd odysseus-cli && bundle exec bin/odysseus 2>&1 | grep rollback
```
Expected: both the command line and the `--list` option appear.

```bash
bundle exec bin/odysseus rollback --config /nonexistent.yml
```
Expected: exit 1 with a config error, **not** a `NoMethodError` or a usage dump — this proves dispatch reaches `CLI#rollback`.

- [ ] **Step 7: Mutation-check**

1. `options[:list]` guard removed → "does not roll anything back" fails.
2. `version: options[:version]` → `version: nil` → "passes an explicit version through" fails.
3. `plan.approximate` guard inverted → "warns when the ordering is only approximate" fails.
4. `'present' : 'missing'` swapped → the present/missing examples fail.
5. Remove the `rescue Odysseus::Error` → "reports a refused rollback" fails with the raw error instead of `SystemExit`.

- [ ] **Step 8: Run rake in both gems and commit**

```bash
cd odysseus-cli && bundle exec rake
cd ../odysseus-core && bundle exec rake
git add odysseus-cli/lib odysseus-cli/bin odysseus-cli/spec
git commit -m "Add the rollback command and its per-host candidate listing"
```

---

### Task 7: Documentation

**Files:**
- Modify: `odysseus-core/CHANGELOG.md`, `odysseus-cli/CHANGELOG.md`
- Modify: `odysseus-cli/README.md`, `README.md`
- Modify: `TODO.md`

- [ ] **Step 1: Read what the READMEs currently claim**

```bash
grep -n 'rollback\|## Commands\|^### \|app exec' README.md odysseus-cli/README.md
```

`README.md` recently had claims removed for features that do not exist (commit `d9f25b0`), so add only what this plan actually shipped. Check whether either README has a command table that now needs a `rollback` row.

- [ ] **Step 2: Add the CHANGELOG entries**

`odysseus-core/CHANGELOG.md`, under `## [Unreleased]`:

```markdown
### Added
- `Executor#rollback_plan` and `#rollback_all`, which return every role on
  every host to a previously deployed version by reusing the deploy path, so
  health gating and proxy handling are shared with `deploy`. The target is
  chosen from what the hosts report — running container labels, images present,
  and each host's `deploys.log` — never from the local repository, which can
  drift from what a host can actually run.
- A fleet pre-flight: the target image must be present on every host across all
  roles before any host is touched. A half-rolled-back fleet is worse than a
  refused command.
- `Executor#version_survey`, `HostVersions` and `RollbackPlanner`.
- `Docker::Client#image_tags`, listing the tags a host has for a repository.

### Changed
- Deploys are recorded on the host by `Executor` rather than by each
  orchestrator. A rollback now records `kind=rolled-back` with the version it
  replaced, and a role deployed by a sail-provided strategy gets the same audit
  trail instead of none.
- `VersionResolver#deployer` is public, so a rollback can name who ran it even
  though its version came from a host rather than a commit.
```

`odysseus-cli/CHANGELOG.md`, under `## [Unreleased]`:

```markdown
### Added
- `odysseus rollback [VERSION]`, returning every role on every host to a
  previously deployed version. With no VERSION, the target is the most recent
  version in the hosts' deploy logs that is not already serving and whose image
  is still present everywhere. Refuses, changing nothing, when any host lacks
  the image.
- `odysseus rollback --list`, showing per host: every version deployed, when,
  by whom, from which commit, whether the image is still present, and what is
  serving. Reads only the hosts, so it works without a git repository.
```

- [ ] **Step 3: Document the command in the CLI README**

Match the surrounding style. Include the constraint that matters operationally:

```markdown
### Rollback

    odysseus rollback              # to the previous version
    odysseus rollback abc123def456 # to a specific version
    odysseus rollback --list       # what each host could roll back to

The target is chosen from what the hosts have, not from your checkout: the
version must still have an image on **every** host, or the rollback refuses
without touching any of them.

A rollback re-runs the deploy path, so it starts a container and waits for
health checks — roughly the time of a normal deploy, minus build and transfer.

Only versions deployed by odysseus 0.4.2 or later can be rolled back to.
Earlier deploys were built from `:latest`, so no image identifies them.
```

- [ ] **Step 4: Update `TODO.md`**

Mark the rollback item done. Leave retention/pruning (phase 4) and git notes (phase 5) open, and check whether the multi-host partial-failure item and the deploy-lock item need their wording adjusted now that the pre-flight exists — the pre-flight removes the common cause but does not make a roll atomic, so neither item is closed.

- [ ] **Step 5: Commit**

```bash
git add README.md TODO.md odysseus-core/CHANGELOG.md odysseus-cli/CHANGELOG.md odysseus-cli/README.md
git commit -m "Document rollback"
```

---

## Verification

Before considering the plan complete:

- [ ] `cd odysseus-core && bundle exec rake` — RSpec and RuboCop both clean
- [ ] `cd odysseus-cli && bundle exec rake` — RSpec and RuboCop both clean
- [ ] `bundle exec bin/odysseus` lists `rollback` in its help
- [ ] Every new example has been checked against a deliberate mutation
- [ ] No spec opens a network connection: `grep -rn 'Net::SSH.start' spec/` returns nothing

**Manual verification on a real host** is required before this is trusted, because no unit test proves the deploy path accepts a tag it did not build. On a host that has had at least two 0.4.2 deploys:

1. `odysseus rollback --list` — the versions match `ssh <host> cat /var/lib/odysseus/<service>/deploys.log`, and the present/missing column matches `ssh <host> docker images <image>`.
2. `odysseus rollback` — completes, and `odysseus status <host>` afterwards reports the older version.
3. `ssh <host> cat /var/lib/odysseus/<service>/deploys.log` — the last line reads `rolled-back from=<the version that was serving>`, on **one** line.
4. `odysseus rollback v-does-not-exist` — refuses, names the hosts, and `odysseus status` shows the fleet unchanged.
5. Roll forward again with `odysseus deploy` to leave the host on current code.

Step 3 deserves its own attention: the one-line shape of `deploys.log` was broken once already in phase 2 by a `printf` that reused its format per argument, and no unit test could catch it. Read the file, do not just count lines.

## Deviations from the spec

Two, both deliberate — a reviewer should read them as decisions, not misses:

- The spec says the pre-flight should "abort and report which hosts have which
  versions". The error names the hosts that lack the target and points at
  `rollback --list` for the full picture, rather than dumping every host's tag
  list into an exception message. `--list` renders that as a table, which is
  where it reads well.
- `rollback --list` reports what is serving with an `info` line per host rather
  than a `Serving` column in the table. Same information; a column repeating one
  value down every row is noise.

## Out of scope

- **Retention and pruning** (phase 4). Until it lands, SHA-tagged images accumulate on hosts. They share layers, so the cost is modest, and `cleanup --prune-images` only removes dangling images so it will not delete a rollback target.
- **Git notes** (phase 5).
- **`rollback --dry-run`.** `--list` covers inspection, and `rollback_plan` already refuses before touching anything.
- **Per-role rollback.** The spec rules it out: rolling `web` back while leaving `jobs` on newer code is not a mode this command offers.
- **A deploy lock.** Two concurrent deploys, or a deploy racing a rollback, can still interleave. Tracked separately in `TODO.md`.
