# Image Retention and Pruning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop SHA-tagged images accumulating without limit on every host, by pruning a service's images beyond the newest `retain_versions` distinct versions after a successful deploy.

**Architecture:** A pure `RetentionPlanner` decides which image tags to remove from what a host reports — its `deploys.log`, the tags actually present, and the versions any container on it still references. `Executor` then removes each selected tag with its own rescue, so one unremovable image is a logged skip rather than a failed deploy. Three independent layers stop this deleting something live: the retain window, an explicit exclusion of every version a container references, and `docker image rm` itself refusing an image in use.

**Tech Stack:** Ruby 3.2+, Zeitwerk autoloading, `Data.define` value objects, RSpec, RuboCop, net-ssh.

**Spec:** `docs/specs/2026-08-12-deploy-versioning-and-rollback.md` — this plan implements its phase 4 ("Retention and pruning"). Phase 5 (git notes) is a separate plan.

**Context:** Phases 1–3 shipped in 0.4.2–0.4.3. The image tag is the git SHA, containers carry `odysseus.version`, each host keeps `/var/lib/odysseus/<service>/deploys.log`, and `odysseus rollback` reads all three. Nothing removes old images today: `cleanup --prune-images` runs `docker image prune -f`, which only removes *dangling* images, and a SHA-tagged image is never dangling.

## Global Constraints

- Ruby `>= 3.2.0`; both gems MIT. **No new runtime dependencies.**
- `bundle exec rake` must pass RSpec **and** RuboCop clean in both `odysseus-core` and `odysseus-cli` before any commit.
- **Do NOT edit `.rubocop_todo.yml`** in either gem, and do not add an inline `rubocop:disable`. `Executor` and `CLI` are both near their `Metrics/ClassLength` limits; extract a small class or a private helper instead. Two earlier phases did exactly this — see `Deployer::DependencyManager` and `CLI::RollbackCommands`.
- `config.warnings = true` in core: no unused variables, shadowed locals, or method redefinitions.
- Specs never open a network connection. `Odysseus::Deployer::SSH` and `Odysseus::Docker::Client` are always doubles.
- Every new spec must be checked against a deliberate mutation of the code under test — break it, confirm a *named* example fails, restore. **This is where every defect on the last two branches was found**, and four times the cause was a fixture too uniform to tell the mutant from correct code. Make fixture values differ along the axis under test.
- `DeployLog#entries` returns entries **oldest first**; `Entry#at` is fixed-width UTC ISO 8601, so string sort is chronological sort. `DeployLog` writes the literal `-` for an absent field.
- Deleting images on a production host is the most destructive thing odysseus does. Where a choice exists between deleting and keeping, keep.

---

## Design decisions made here, not in the spec

The spec leaves these open; a reviewer should read them as decisions, not omissions.

**Pruning runs once per host, after all of that host's roles are deployed** — not inside `run_deploy`, which is called once per role. A host serving `web` and `cron` would otherwise prune twice, and would prune while `cron` was still on the previous version.

**Rollback does not prune.** `rollback_all` deliberately skips retention: deleting images during a recovery is the wrong moment, and the version you just rolled back *from* is the most likely next thing you want. Only `deploy_all` prunes.

**A host with no `deploys.log` is skipped entirely.** Retention needs the log to know what "newest N" means. Falling back to image creation time would risk deleting a version someone still wants, and creation time is *build* time — images can reach a host out of order. Skipping is the safe default and is logged.

**`latest` is never pruned automatically.** Per the spec. Pre-0.4.2 deploys were built from it, something may still reference it, and it is a moving pointer. `cleanup --prune-images` remains the manual sweep.

**The sweep lives in its own class, not in `Executor`.** Measured before writing this plan: `Executor` is **249 lines against its `Metrics/ClassLength` limit of 273**, and the prune logic is about 42 lines of code. Putting it inline would breach the limit and force exactly the choice the Global Constraints forbid. `Deployer::RetentionSweeper` mirrors `Deployer::DependencyManager`, which exists for the same reason: it takes the config, a connector, and a logger, and `Executor` delegates to it in three lines. Phase 3 hit this wall twice mid-task and improvised; this plan does the arithmetic up front.

**`retain_versions: 1` is legal but leaves nothing to roll back to.** The spec says validate `>= 1`, so this plan does. The README must say what it means: after a deploy, the previous version's image is eligible for removal, so `odysseus rollback` will have no candidate. The default of 5 is what most people should leave alone.

---

## File Structure

**Create (odysseus-core):**

| File | Responsibility |
| --- | --- |
| `lib/odysseus/retention_plan.rb` | `Odysseus::RetentionPlan` — which tags to remove and which were protected, plus why. Pure data. |
| `lib/odysseus/retention_planner.rb` | `Odysseus::RetentionPlanner` — the selection rules. Pure: no SSH, no config, no git. |
| `lib/odysseus/deployer/retention_sweeper.rb` | `Odysseus::Deployer::RetentionSweeper` — walks the hosts, applies the plan, removes images. Owns the SSH side so `Executor` stays under its size limit. |
| `spec/odysseus/retention_planner_spec.rb` | The selection rules, with no doubles at all. |
| `spec/odysseus/deployer/retention_sweeper_spec.rb` | The sweep, against doubled SSH and Docker. |
| `spec/fixtures/deploy-retain-two.yml` | `retain_versions: 2`, so a non-default value is provably read. |

**Modify (odysseus-core):**

| File | Change |
| --- | --- |
| `lib/odysseus/docker/client.rb` | Add `#remove_image(image)` and `#versions_in_use(service_labels)`. |
| `lib/odysseus/config/parser.rb` | Parse `retain_versions`, defaulting to 5. |
| `lib/odysseus/validators/config.rb` | Validate `retain_versions` is an integer >= 1. |
| `lib/odysseus/deployer/executor.rb` | Add `#prune_old_images`, delegating to the sweeper, called from `deploy_all`. **Thin on purpose** — see the note below. |
| `spec/odysseus/docker/client_spec.rb` | Cover the two new methods. |
| `spec/odysseus/config/parser_spec.rb` | Cover the default and an explicit value. |
| `spec/odysseus/validators/config_spec.rb` | Cover the validation. |
| `spec/odysseus/deployer/executor_spec.rb` | Cover the prune pass and that rollback does not prune. |

**Docs:** `odysseus-core/CHANGELOG.md`, `odysseus-cli/CHANGELOG.md`, `odysseus-core/README.md`, `odysseus-cli/README.md`, `TODO.md`.

---

### Task 1: `Docker::Client#remove_image` and `#versions_in_use`

**Files:**
- Modify: `odysseus-core/lib/odysseus/docker/client.rb` (add after `#image_tags`)
- Test: `odysseus-core/spec/odysseus/docker/client_spec.rb`

**Interfaces:**
- Consumes: `@ssh.execute(String) -> String` (raises `Odysseus::SSHCommandError` on non-zero exit), `Odysseus::Docker::Labels.version_of(container)`, `#list(service:, all:)`.
- Produces:
  - `Docker::Client#remove_image(image) -> String` — runs `docker image rm <image>`. **Lets `SSHCommandError` propagate**; the caller rescues per image. Consistent with every other method on this client.
  - `Docker::Client#versions_in_use(service_labels) -> Array<String>` — the `odysseus.version` labels of every container, running **or stopped**, carrying any of the given `odysseus.service` label values. De-duplicated, never nil.

`versions_in_use` must pass `all: true`: `cleanup_old_containers(keep: 2)` deliberately retains two stopped containers per service, and their images must survive.

- [ ] **Step 1: Write the failing tests**

Append inside `RSpec.describe Odysseus::Docker::Client do` in `spec/odysseus/docker/client_spec.rb`. It already defines `let(:mock_ssh)` and `let(:client)` at lines 7-8 — reuse them.

```ruby
  describe '#remove_image' do
    it 'removes the image by reference' do
      expect(mock_ssh).to receive(:execute).with(a_string_including('docker image rm')).and_return('')

      client.remove_image('myapp-production:abc123')
    end

    it 'escapes the image reference' do
      expect(mock_ssh).to receive(:execute).with(a_string_including('my\ app')).and_return('')

      client.remove_image('my app')
    end

    # Every other method on this client lets SSHCommandError through, and the
    # caller prunes image-by-image so one refusal is a skip rather than a failed
    # deploy. Swallowing it here would hide a host that cannot prune at all.
    it 'lets a failure propagate for the caller to rescue' do
      allow(mock_ssh).to receive(:execute).and_raise(Odysseus::SSHCommandError, 'image is in use')

      expect { client.remove_image('myapp-production:abc123') }
        .to raise_error(Odysseus::SSHCommandError, /in use/)
    end
  end

  describe '#versions_in_use' do
    it 'collects the version label of every container across the given service labels' do
      allow(client).to receive(:list).with(service: 'myapp', all: true).and_return(
        [{ 'Labels' => 'odysseus.service=myapp,odysseus.version=v2' }]
      )
      allow(client).to receive(:list).with(service: 'myapp-jobs', all: true).and_return(
        [{ 'Labels' => 'odysseus.service=myapp-jobs,odysseus.version=v1' }]
      )

      expect(client.versions_in_use(%w[myapp myapp-jobs])).to contain_exactly('v1', 'v2')
    end

    # cleanup_old_containers keeps two stopped containers per service on purpose.
    # Their images must not be pruned out from under them, so stopped containers
    # count as in use.
    it 'includes stopped containers' do
      expect(client).to receive(:list).with(service: 'myapp', all: true).and_return(
        [{ 'State' => 'exited', 'Labels' => 'odysseus.version=v1' }]
      )

      expect(client.versions_in_use(['myapp'])).to eq(['v1'])
    end

    it 'de-duplicates a version running under two labels' do
      allow(client).to receive(:list).and_return([{ 'Labels' => 'odysseus.version=v2' }])

      expect(client.versions_in_use(%w[myapp myapp-jobs])).to eq(['v2'])
    end

    it 'skips a container carrying no version label' do
      allow(client).to receive(:list).and_return(
        [{ 'Labels' => 'odysseus.service=myapp' }, { 'Labels' => 'odysseus.version=v2' }]
      )

      expect(client.versions_in_use(['myapp'])).to eq(['v2'])
    end

    it 'returns an empty array when nothing is on the host' do
      allow(client).to receive(:list).and_return([])

      expect(client.versions_in_use(['myapp'])).to eq([])
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb -e '#remove_image' -e '#versions_in_use'`
Expected: FAIL, 8 examples, `NoMethodError` on both methods.

- [ ] **Step 3: Write the implementation**

In `lib/odysseus/docker/client.rb`, directly after `#image_tags`:

```ruby
      # Remove one image by reference.
      #
      # Lets SSHCommandError through deliberately: docker refuses to remove an
      # image a container still references, and the caller prunes one image at a
      # time so a refusal is a logged skip rather than a failed deploy.
      #
      # @param image [String] repository:tag
      # @return [String] docker's output
      def remove_image(image)
        @ssh.execute("docker image rm #{Shellwords.escape(image)}")
      end

      # The versions any container on this host still references.
      #
      # Includes stopped containers (`all: true`): cleanup_old_containers keeps
      # two per service on purpose, and pruning their images would leave nothing
      # to fall back to. Used to protect those versions from retention.
      #
      # @param service_labels [Array<String>] odysseus.service values to check
      # @return [Array<String>] distinct odysseus.version labels found
      def versions_in_use(service_labels)
        service_labels.flat_map { |label| list(service: label, all: true) }
                      .filter_map { |container| Odysseus::Docker::Labels.version_of(container) }
                      .uniq
      end
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check**

Each must break a *named* example; restore after each:
1. Remove `Shellwords.escape` from `remove_image` → "escapes the image reference" fails.
2. Wrap `remove_image`'s body in `rescue Odysseus::SSHCommandError; nil` → "lets a failure propagate" fails.
3. `all: true` → `all: false` in `versions_in_use` → **if nothing fails, the fixtures are not distinguishing running from stopped.** Strengthen "includes stopped containers" so it does (it constrains `list` with `all: true`, so this mutation should already fail it — confirm).
4. `filter_map` → `map` → "skips a container carrying no version label" fails.
5. Remove `.uniq` → "de-duplicates a version running under two labels" fails.

- [ ] **Step 6: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib/odysseus/docker/client.rb odysseus-core/spec/odysseus/docker/client_spec.rb
git commit -m "Remove an image, and report the versions a host still references"
```

---

### Task 2: `retain_versions` config

**Files:**
- Modify: `odysseus-core/lib/odysseus/config/parser.rb`
- Modify: `odysseus-core/lib/odysseus/validators/config.rb`
- Create: `odysseus-core/spec/fixtures/deploy-retain-two.yml`
- Test: `odysseus-core/spec/odysseus/config/parser_spec.rb`, `odysseus-core/spec/odysseus/validators/config_spec.rb`

**Interfaces:**
- Produces: `config[:retain_versions] -> Integer`, defaulting to `5`. Validated as an integer `>= 1`, raising `Odysseus::ConfigValidationError`.

Note the validator reads the **raw string-keyed** config (`@config['retain_versions']`), before `normalize`; the parser produces the symbol-keyed value. `Parser#parse` calls `validate!` on the raw hash first (`parser.rb:18`).

- [ ] **Step 1: Create the fixture**

`odysseus-core/spec/fixtures/deploy-retain-two.yml`:

```yaml
# spec/fixtures/deploy-retain-two.yml
# retain_versions deliberately set to 2, not the default 5, so a spec can prove
# the configured value is read rather than the default being returned.

service: myapp
image: myapp-production
retain_versions: 2

servers:
  web:
    hosts:
      - web1.example.com

ssh:
  user: root
  keys:
    - ~/.ssh/id_ed25519
```

- [ ] **Step 2: Write the failing tests**

Add to `spec/odysseus/config/parser_spec.rb`, inside the top-level describe:

```ruby
  describe 'retain_versions' do
    it 'defaults to 5 when not configured' do
      expect(parser.parse[:retain_versions]).to eq(5)
    end

    it 'reads a configured value' do
      config = described_class.new(fixture_path('deploy-retain-two.yml')).parse

      expect(config[:retain_versions]).to eq(2)
    end
  end
```

Add to `spec/odysseus/validators/config_spec.rb`. It already defines `let(:valid_config)` (a **string-keyed** hash, since the validator runs before `normalize`) at line 7 and a `validate(config)` helper at line 17 — verified; reuse both rather than inventing a second pattern:

```ruby
  describe 'retain_versions' do
    it 'accepts an integer of 1 or more' do
      expect { validate(valid_config.merge('retain_versions' => 1)) }.not_to raise_error
    end

    it 'rejects zero' do
      expect { validate(valid_config.merge('retain_versions' => 0)) }
        .to raise_error(Odysseus::ConfigValidationError, /retain_versions/)
    end

    it 'rejects a negative number' do
      expect { validate(valid_config.merge('retain_versions' => -1)) }
        .to raise_error(Odysseus::ConfigValidationError, /retain_versions/)
    end

    it 'rejects a non-integer' do
      expect { validate(valid_config.merge('retain_versions' => 'five')) }
        .to raise_error(Odysseus::ConfigValidationError, /retain_versions/)
    end

    # 2.0 is not an Integer, and accepting it would mean deciding whether to
    # round; refusing is clearer than guessing.
    it 'rejects a float' do
      expect { validate(valid_config.merge('retain_versions' => 2.0)) }
        .to raise_error(Odysseus::ConfigValidationError, /retain_versions/)
    end

    it 'accepts a config that omits it' do
      expect { validate(valid_config) }.not_to raise_error
    end
  end
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/config/parser_spec.rb spec/odysseus/validators/config_spec.rb -e retain_versions`
Expected: FAIL — the parser returns nil, and the validator raises nothing.

- [ ] **Step 4: Write the implementation**

In `lib/odysseus/config/parser.rb`, add to the hash in `normalize` (after `registry:`):

```ruby
          retain_versions: config['retain_versions'] || DEFAULT_RETAIN_VERSIONS
```

and near the top of the class:

```ruby
      # Distinct versions of a service's image kept on each host. Five is enough
      # to roll back through a bad week; the images share layers, so the cost of
      # keeping a few is small.
      DEFAULT_RETAIN_VERSIONS = 5
```

In `lib/odysseus/validators/config.rb`, add to `validate!`:

```ruby
        validate_retain_versions! if @config.key?('retain_versions')
```

and the private method:

```ruby
      def validate_retain_versions!
        value = @config['retain_versions']
        return if value.is_a?(Integer) && value >= 1

        raise Odysseus::ConfigValidationError,
              "retain_versions must be an integer of 1 or more, got #{value.inspect}"
      end
```

`value.is_a?(Integer)` rejects `2.0` and `'five'`; `true` is not an Integer in Ruby, so it is rejected too.

- [ ] **Step 5: Run to verify they pass, then the whole suite**

Run: `cd odysseus-core && bundle exec rspec`
Expected: PASS. If an existing example asserts on the exact set of keys `parse` returns, it will need `retain_versions` added — that is a legitimate update, not a weakening.

- [ ] **Step 6: Mutation-check**

1. `DEFAULT_RETAIN_VERSIONS = 5` → `4` → "defaults to 5" fails.
2. `config['retain_versions'] || DEFAULT` → `DEFAULT` → "reads a configured value" fails.
3. `value >= 1` → `value >= 0` → "rejects zero" fails.
4. `value.is_a?(Integer)` → `value.is_a?(Numeric)` → "rejects a float" fails.
5. `if @config.key?('retain_versions')` → unconditional → "accepts a config that omits it" fails.

- [ ] **Step 7: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib odysseus-core/spec
git commit -m "Add retain_versions to deploy.yml, defaulting to 5"
```

---

### Task 3: `RetentionPlanner` — which tags to remove

The decision logic, pure so its rules are testable with plain values. This is the task where a mistake deletes something live.

**Files:**
- Create: `odysseus-core/lib/odysseus/retention_plan.rb`
- Create: `odysseus-core/lib/odysseus/retention_planner.rb`
- Test: `odysseus-core/spec/odysseus/retention_planner_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::DeployLog::Entry` (`:at`, `:version`, …).
- Produces:
  - `Odysseus::RetentionPlan = Data.define(:remove, :keep)` — `remove` is an Array of version strings, oldest first; `keep` is an Array of the versions retained. Both are versions, not full image references; the caller builds `"#{image}:#{version}"`.
  - `RetentionPlanner.new(history:, available:, in_use:, retain:)` where `history: Array<DeployLog::Entry>` (oldest first), `available: Array<String>` (tags present on the host), `in_use: Array<String>`, `retain: Integer`.
  - `RetentionPlanner#plan -> RetentionPlan`

**The rules, in order:**
1. Rank the logged versions newest-deploy first, de-duplicated, keeping the newest occurrence — the same ordering `RollbackPlanner#logged_versions` uses.
2. Keep the newest `retain` of those.
3. Everything else logged is a removal candidate.
4. Remove from the candidates: anything not in `available` (nothing to delete), anything in `in_use`, and `latest`.
5. A version present on the host but absent from the log is **never** removed — the log is what authorises removal.
6. An empty `history` yields an empty `remove`.

- [ ] **Step 1: Write the failing test**

Create `odysseus-core/spec/odysseus/retention_planner_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/retention_planner_spec.rb`
Expected: FAIL, 13 examples, `NameError: uninitialized constant Odysseus::RetentionPlanner`.

- [ ] **Step 3: Write `RetentionPlan`**

Create `odysseus-core/lib/odysseus/retention_plan.rb`:

```ruby
# lib/odysseus/retention_plan.rb

module Odysseus
  # What retention decided for one host.
  #
  # remove  versions whose images should be deleted, **oldest first**, so a
  #         partial failure leaves the newest behind
  # keep    versions retained, newest first — reported so an operator can see
  #         what the window covers without re-deriving it
  #
  # Both hold versions, not image references; the caller pairs them with the
  # configured image name.
  RetentionPlan = Data.define(:remove, :keep)
end
```

- [ ] **Step 4: Write `RetentionPlanner`**

Create `odysseus-core/lib/odysseus/retention_planner.rb`:

```ruby
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
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/retention_planner_spec.rb`
Expected: PASS, 13 examples.

- [ ] **Step 6: Mutation-check**

Every one must break a *named* example; restore after each:
1. `.reverse` removed from `ranked` → "ranks by deploy time" fails.
2. `.uniq` removed → "treats a redeployed version as recent" fails.
3. `ranked - keep` → `ranked` → "removes nothing when the log is within the retain window" fails.
4. `.reverse` removed from `removable` → "removes oldest first" fails.
5. `@available.include?(version)` → `true` → "skips a version whose image is already gone" fails.
6. `!@in_use.include?(version)` → `true` → "never removes a version a container still references" fails.
7. `!PROTECTED_TAGS.include?(version)` → `true` → "never removes latest" fails.
8. `take(@retain)` → `take(@retain + 1)` → "retains only the newest when retain is 1" fails.
9. Add `@available - ranked` into `removable` → "never removes a version the log does not mention" fails.

**Mutation 4 needs care:** with `remove == %w[v1 v2]`, dropping the final `.reverse` yields `%w[v2 v1]`, so the example must assert exact order (`eq`), not membership. Confirm it does.

- [ ] **Step 7: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib/odysseus/retention_plan.rb odysseus-core/lib/odysseus/retention_planner.rb \
        odysseus-core/spec/odysseus/retention_planner_spec.rb
git commit -m "Choose which of a service's images a host no longer needs"
```

---

### Task 4: `RetentionSweeper` and `Executor#prune_old_images`

**Files:**
- Create: `odysseus-core/lib/odysseus/deployer/retention_sweeper.rb`
- Modify: `odysseus-core/lib/odysseus/deployer/executor.rb` (thin delegation plus one line in `deploy_all`)
- Test: `odysseus-core/spec/odysseus/deployer/retention_sweeper_spec.rb`
- Test: `odysseus-core/spec/odysseus/deployer/executor_spec.rb` (the `deploy_all` wiring only)

**Why a separate class:** `Executor` measures 249 lines against a `Metrics/ClassLength` limit of 273, and this logic is about 42. `Deployer::DependencyManager` was extracted for exactly this reason — follow its shape.

**Interfaces:**
- Consumes: `Docker::Client#image_tags`, `#versions_in_use`, `#remove_image` (Task 1); `DeployLog#entries`; `RetentionPlanner` (Task 3); `Docker::Labels.service_for(service:, role:)`.
- Produces:
  - `Deployer::RetentionSweeper.new(config:, connector:, logger:)` where `connector` is a `#call`-able returning an open SSH connection for a host (`Executor` passes `method(:connect_to_server)`, the same seam `DependencyManager` uses), and `logger` responds to `#info` and `#warn`.
  - `RetentionSweeper#sweep(host_roles) -> Hash{String => Array<String>}` — versions actually removed, keyed by host. `host_roles` is `{host => [roles]}`.
  - `Executor#prune_old_images -> Hash{String => Array<String>}` — delegates. Public so it is directly testable and can become a CLI command later.

Host resolution stays in `Executor`: the sweeper is handed the already-resolved `host_roles` rather than reaching for `HostProviders` itself, so there remains one place that knows how hosts are resolved.

**Behaviour:**
- One pass per unique host, in config order, opening and closing one connection each.
- Skip a host whose `deploys.log` is empty, logging that it was skipped and why.
- Protect the versions of every container on that host, across all roles it serves — build the label list with `Labels.service_for`, exactly as `version_survey` does.
- Remove each selected tag as `"#{@config[:image]}:#{version}"`, each in its own `begin/rescue`. Rescue `StandardError`, not `Odysseus::Error`: `SSH#execute` can raise `Net::SSH::Disconnect`, `IOError` or `Net::SSH::ChannelOpenFailed` untranslated, and the deploy has already succeeded by this point.
- Log every removal and every skip, with the reason.
- **The whole pass is best effort.** A host that cannot be reached at all must not fail a deploy that already succeeded.

- [ ] **Step 1: Write the failing tests**

Create `spec/odysseus/deployer/retention_sweeper_spec.rb`. Drive it **through `Executor#prune_old_images`**, not by constructing the sweeper directly: that is the entry point the deploy path uses, and it is the pattern a reviewer already endorsed for `DependencyManager`. Model the setup on `executor_spec.rb`'s `describe 'rollback'` block, which stubs `SSH.new`, `Docker::Client.new` and `DeployLog.new` the same way.

```ruby
# spec/odysseus/deployer/retention_sweeper_spec.rb
#
# Exercised through Executor#prune_old_images rather than by constructing the
# sweeper, because that is the path a deploy takes.

require 'spec_helper'

RSpec.describe Odysseus::Deployer::RetentionSweeper do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_orchestrator) { instance_double(Odysseus::Orchestrator::WebDeploy) }

  describe 'sweeping through Executor#prune_old_images' do
    let(:retain_two) { described_class.new(fixture_path('deploy-retain-two.yml')) }
    let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
    let(:deploy_log) { instance_double(Odysseus::DeployLog) }

    def entry(version, at)
      Odysseus::DeployLog::Entry.new(
        at: at, version: version, role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
    end

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
      allow(mock_ssh).to receive(:close)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(mock_docker)
      allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
      allow(deploy_log).to receive(:entries).and_return(
        [entry('v1', '2026-08-01T09:00:00Z'), entry('v2', '2026-08-02T09:00:00Z'),
         entry('v3', '2026-08-03T09:00:00Z')]
      )
      allow(mock_docker).to receive(:image_tags).and_return(%w[v3 v2 v1])
      allow(mock_docker).to receive(:versions_in_use).and_return(['v3'])
      allow(mock_docker).to receive(:remove_image)
    end

    it 'removes the images outside the retain window, fully qualified' do
      expect(mock_docker).to receive(:remove_image).with('myapp-production:v1')

      retain_two.prune_old_images
    end

    it 'keeps the versions inside the retain window' do
      expect(mock_docker).not_to receive(:remove_image).with('myapp-production:v3')
      expect(mock_docker).not_to receive(:remove_image).with('myapp-production:v2')

      retain_two.prune_old_images
    end

    it 'returns the versions removed, keyed by host' do
      expect(retain_two.prune_old_images).to eq('web1.example.com' => ['v1'])
    end

    it 'protects the versions of every container on the host, across all its roles' do
      expect(mock_docker).to receive(:versions_in_use).with(['myapp']).and_return(%w[v3 v1])
      expect(mock_docker).not_to receive(:remove_image)

      retain_two.prune_old_images
    end

    it 'skips a host with no deploy log rather than guessing from image order' do
      allow(deploy_log).to receive(:entries).and_return([])
      expect(mock_docker).not_to receive(:remove_image)

      expect(retain_two.prune_old_images).to eq('web1.example.com' => [])
    end

    # The deploy has already succeeded and traffic has already switched by the
    # time this runs. An image docker refuses to delete must be a logged skip.
    it 'continues after a removal docker refuses, and still reports the rest' do
      allow(deploy_log).to receive(:entries).and_return(
        [entry('v1', '2026-08-01T09:00:00Z'), entry('v2', '2026-08-02T09:00:00Z'),
         entry('v3', '2026-08-03T09:00:00Z'), entry('v4', '2026-08-04T09:00:00Z')]
      )
      allow(mock_docker).to receive(:image_tags).and_return(%w[v4 v3 v2 v1])
      allow(mock_docker).to receive(:versions_in_use).and_return(['v4'])
      allow(mock_docker).to receive(:remove_image).with('myapp-production:v1')
                                                  .and_raise(Odysseus::SSHCommandError, 'image is in use')
      allow(mock_docker).to receive(:remove_image).with('myapp-production:v2')

      expect(retain_two.prune_old_images).to eq('web1.example.com' => ['v2'])
    end

    it 'survives a raw connection error without failing the caller' do
      allow(mock_docker).to receive(:remove_image).and_raise(IOError, 'connection reset')

      expect { retain_two.prune_old_images }.not_to raise_error
    end

    it 'closes the connection it opened, even when a removal raises' do
      allow(mock_docker).to receive(:remove_image).and_raise(IOError, 'connection reset')
      expect(mock_ssh).to receive(:close)

      retain_two.prune_old_images
    end
  end
```

Then, for the multi-host wiring and the deliberate rollback exclusion, add inside the existing `describe 'rollback'` block (which already has the multi-host fixture and its sail `around` hook):

```ruby
    describe 'retention and rollback' do
      before do
        allow(deploy_log).to receive(:entries).and_return([])
        allow(mock_docker).to receive(:versions_in_use).and_return([])
        allow(mock_docker).to receive(:remove_image)
      end

      # Deleting images during a recovery is the wrong moment, and the version
      # just rolled back FROM is the most likely next thing wanted.
      it 'does not prune when rolling back' do
        plan = Odysseus::RollbackPlan.new(version: 'v1', ref: 'main', approximate: false,
                                          replacing: { 'web1.example.com' => 'v2',
                                                       'web2.example.com' => 'v2',
                                                       'jobs1.example.com' => 'v2' })
        allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(Odysseus::Orchestrator::JobDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(mock_orchestrator).to receive(:deploy).and_return(success: true)

        expect(mock_docker).not_to receive(:remove_image)

        multihost.rollback_all(plan)
      end

      it 'surveys each host once even when a host serves two roles' do
        expect(mock_docker).to receive(:versions_in_use).exactly(3).times.and_return([])

        multihost.prune_old_images
      end
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/deployer/executor_spec.rb -e prune`
Expected: FAIL, `NoMethodError: undefined method 'prune_old_images'`.

- [ ] **Step 3: Write the implementation**

Create `odysseus-core/lib/odysseus/deployer/retention_sweeper.rb`:

```ruby
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
```

Every log line names the host: on a fleet, "nothing pruned" without a host name is useless.

Then add to `Executor`'s public section, after `rollback_all`:

```ruby
      # Delete a service's images that no host needs any more.
      #
      # @return [Hash{String => Array<String>}] versions removed, keyed by host
      def prune_old_images
        retention_sweeper.sweep(host_roles)
      end
```

and to `Executor`'s private section, next to the other collaborator builders:

```ruby
      def retention_sweeper
        @retention_sweeper ||= Odysseus::Deployer::RetentionSweeper.new(
          config: @config, connector: method(:connect_to_server), logger: build_logger
        )
      end
```

`host_roles` is the private helper added in phase 3 for `version_survey` (`executor.rb`). It returns a Hash of `{host => [roles]}` in config order, one entry per host even when a host serves several roles — verified. `Hash#to_h` with a block yields `(key, value)`, which is why `host_roles.to_h { |host, roles| ... }` works.

`retain_versions` is not the only config this reads: `@config[:image]` is the repository and `@config[:service]` is both the deploy-log directory and the base of the container label. Do not conflate them — `image` and `service` are different values in every real deploy.yml.

- [ ] **Step 4: Wire it into `deploy_all`**

In `deploy_all`, after the role loop and before `results` is returned:

```ruby
        prune_old_images unless dry_run

        results
```

Then add two examples alongside the existing `#deploy_all` examples. Assert on the observable effect — whether `remove_image` reaches the Docker client — rather than on `prune_old_images` having been called. A `expect(executor).to receive(:prune_old_images)` would pass against a `prune_old_images` that does nothing:

```ruby
    context 'image retention' do
      let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
      let(:deploy_log) { instance_double(Odysseus::DeployLog) }

      before do
        allow(Odysseus::Docker::Client).to receive(:new).and_return(mock_docker)
        allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
        allow(deploy_log).to receive(:append)
        allow(deploy_log).to receive(:entries).and_return(
          [Odysseus::DeployLog::Entry.new(at: '2026-08-01T09:00:00Z', version: 'v_old', role: 'web',
                                          ref: 'main', deployer: 'dev@example.com',
                                          kind: 'deployed', from: nil)]
        )
        allow(mock_docker).to receive(:image_tags).and_return(%w[v_old])
        allow(mock_docker).to receive(:versions_in_use).and_return([])
        allow(mock_docker).to receive(:remove_image)
      end

      # retain_versions defaults to 5 and the log has one entry, so nothing is
      # eligible — which is why this asserts the sweep *ran* by checking the
      # host was read, not by checking a removal happened.
      it 'sweeps each host after deploying' do
        expect(mock_docker).to receive(:versions_in_use)

        executor.deploy_all(image_tag: 'v1.0')
      end

      it 'does not touch any host on a dry run' do
        expect(mock_docker).not_to receive(:versions_in_use)
        expect(mock_docker).not_to receive(:remove_image)

        executor.deploy_all(image_tag: 'v1.0', dry_run: true)
      end
    end
```

- [ ] **Step 5: Run to verify they pass, then the whole suite**

Run: `cd odysseus-core && bundle exec rspec`
Expected: PASS. If existing `#deploy_all` examples now fail because they do not stub the prune pass, add `allow(executor).to receive(:prune_old_images)` to that block's `before` — those examples are about deploying, not pruning.

- [ ] **Step 6: Mutation-check**

1. `"#{@config[:image]}:#{version}"` → `version` → "removes the images outside the retain window, fully qualified" fails.
2. `retain: @config[:retain_versions]` → `retain: 5` → "removes the images outside the retain window" fails (the fixture sets 2).
3. `in_use: docker.versions_in_use(labels)` → `in_use: []` → "protects the versions of every container on the host" fails.
4. `return nil if history.empty?` removed → "skips a host with no deploy log" fails.
5. `rescue StandardError` in `prune_image` → `rescue Odysseus::SSHCommandError` → "survives a raw connection error" fails.
6. `prune_image`'s `false` → `true` on rescue → "continues after a removal docker refuses" fails.
7. `prune_old_images unless dry_run` → `prune_old_images` → "does not touch any host on a dry run" fails.
8. Add `prune_old_images` to `rollback_all` → "does not prune when rolling back" fails.
9. `RetentionSweeper#sweep`'s body → `{}` → several named examples fail. If none do, the sweep is not actually reached through `Executor` and the whole spec is asserting nothing.

- [ ] **Step 6a: Confirm the size arithmetic held**

The reason this task has its own class is `Metrics/ClassLength`. Verify it worked rather than assuming:

```bash
cd odysseus-core && bundle exec rubocop lib/odysseus/deployer/executor.rb lib/odysseus/deployer/retention_sweeper.rb
```
Expected: no offences, and `.rubocop_todo.yml` untouched. If `Executor` still breaches the limit, say so and stop rather than editing the todo file — something else needs to move.

- [ ] **Step 7: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib odysseus-core/spec
git commit -m "Prune a service's unneeded images after a successful deploy"
```

---

### Task 5: Documentation

**Files:** `odysseus-core/CHANGELOG.md`, `odysseus-cli/CHANGELOG.md`, `odysseus-core/README.md`, `odysseus-cli/README.md`, `TODO.md`

- [ ] **Step 1: Read what the READMEs currently say**

```bash
grep -n 'retain\|prune\|cleanup' README.md odysseus-core/README.md odysseus-cli/README.md
```

Check whether either README documents a config-key table that needs a `retain_versions` row, and what `cleanup --prune-images` is currently promised to do.

- [ ] **Step 2: Core CHANGELOG, under `## [Unreleased]`**

```markdown
### Added
- `retain_versions` in deploy.yml, default 5: how many distinct versions of a
  service's image each host keeps. After a successful deploy, images beyond that
  window are removed. Until now SHA-tagged images accumulated without limit —
  `cleanup --prune-images` only removes *dangling* images, and a tagged image is
  never dangling.
- `RetentionPlanner`, `Docker::Client#remove_image` and
  `Docker::Client#versions_in_use`.

### Changed
- `deploy` prunes old images on each host once all of that host's roles are
  deployed. `rollback` deliberately does not: deleting images during a recovery
  is the wrong moment, and the version just rolled back from is the most likely
  next thing wanted.

Three independent things must agree before an image is deleted: it must fall
outside the retain window, no container on the host may reference it (stopped
containers included, since cleanup keeps two per service), and docker must
accept the removal. Each removal is attempted on its own, so one refusal is a
logged skip rather than a failed deploy. A host with no `deploys.log` is skipped
entirely rather than pruned by image creation time, which is build time and can
be out of order. `latest` is never removed automatically.
```

- [ ] **Step 3: CLI CHANGELOG, under `## [Unreleased]`**

```markdown
### Changed
- `odysseus deploy` now prunes old images on each host, keeping the newest
  `retain_versions` (default 5). See odysseus-core's changelog for what is
  protected from removal.
```

- [ ] **Step 4: README**

Document `retain_versions` where the other top-level keys live, including the two things a reader needs to know and will not guess:

```markdown
### retain_versions

How many distinct versions of your service's image each host keeps. Default 5.

    retain_versions: 5

After a successful deploy, images outside that window are removed from each
host. An image is only removed if the host's own deploy log records it, no
container on the host still references it, and docker accepts the removal — so
a version you are still running is never deleted, and a failure to delete one
image never fails the deploy.

Setting this to `1` is allowed but means the previous version's image becomes
eligible for removal as soon as you deploy, leaving `odysseus rollback` with no
candidate. Use at least 2 if you want to be able to roll back.

`latest` is never removed automatically; `odysseus cleanup --prune-images`
remains the manual sweep.
```

- [ ] **Step 5: `TODO.md`**

Mark retention/pruning done in the P1 rollback entry, which currently says it "stays open". Leave phase 5 (git notes) open. Check whether the `retain_containers` P1 item should now reference this — it is about `cleanup_old_containers(keep: 2)`, which is containers rather than images, so they are separate; say so if the wording is ambiguous.

- [ ] **Step 6: Commit**

```bash
git add README.md TODO.md odysseus-core/CHANGELOG.md odysseus-cli/CHANGELOG.md \
        odysseus-core/README.md odysseus-cli/README.md
git commit -m "Document retain_versions and image pruning"
```

---

## Verification

- [ ] `cd odysseus-core && bundle exec rake` — RSpec and RuboCop clean
- [ ] `cd odysseus-cli && bundle exec rake` — RSpec and RuboCop clean
- [ ] Every new example checked against a deliberate mutation
- [ ] `git status --porcelain` empty — no mutation left in the tree

**Manual verification on a real host is required before this is trusted**, because deleting images is not reversible and no unit test proves docker behaves as assumed. On a host with at least four 0.4.x deploys of one service:

1. `ssh <host> docker images <image>` and `ssh <host> cat /var/lib/odysseus/<service>/deploys.log` — note what is present before.
2. Set `retain_versions: 2` and deploy. The output should name each pruned image and each kept one.
3. `ssh <host> docker images <image>` — exactly the two newest versions remain, plus any `latest`.
4. **`odysseus status <host>` — the running version is still serving.** This is the check that matters; everything else is bookkeeping.
5. `odysseus rollback --list` — the remaining version is still offered as a candidate.
6. Confirm a protected image is genuinely protected: with `retain_versions: 1`, deploy again and verify the currently-serving version was *not* removed, because `versions_in_use` covered it. The log line should say `Kept …` with docker's reason, or the version should never have been selected.
7. Restore `retain_versions` to its intended value.

Step 6 is the one worth doing carefully: it is the only test of the interaction between the retain window and the in-use protection, and it is the case where getting it wrong deletes the image of a running container.

## Out of scope

- **Pruning as its own CLI command.** `prune_old_images` is public so `odysseus prune` is a small later addition, but the spec does not ask for it.
- **Pruning dependency images.** Retention covers the service's own image repository only. A dependency's image (`postgres:16`) is pinned by tag in deploy.yml and shared, so removing it is not this feature's business.
- **Retaining containers.** `cleanup_old_containers(keep: 2)` is still hardcoded; making it configurable is a separate `TODO.md` item.
- **Git notes** (phase 5).
