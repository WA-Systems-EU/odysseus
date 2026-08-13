# Plugin Loading and Rolling Sail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sail plugins loadable at all, and bring `odysseus-sail-rolling` current so a rolling deploy is visible to `status`, `rollback` and image retention.

**Architecture:** An explicit `plugins:` key in deploy.yml, loaded by a new `Odysseus::Plugins` module *before* config validation — because the validator is what asks whether a strategy is registered. Version identity moves out of the two orchestrators into a shared `Odysseus::Core::DeployVersioning` mixin, so any orchestrator, including one in another gem, labels containers correctly by construction rather than by convention.

**Tech Stack:** Ruby 3.2+, Zeitwerk autoloading (core only), RSpec, RuboCop (core only), net-ssh.

**Spec:** `docs/specs/2026-08-13-plugin-loading-and-rolling-sail.md`.

## Global Constraints

- Ruby `>= 3.2.0`. **No new runtime dependencies** in either repository.
- **Two repositories.** Tasks 1, 2 and 4a are in `Odysseus` (`/home/tsultrim/Code/WaConstellation/WaSystems/OdysseusProject/Odysseus`). Tasks 3 and 4b are in `odysseus-sail-rolling` (`../odysseus-sail-rolling`), a separate git repo at one commit. Commit in each repo separately; never stage across them.
- **The two repos verify differently.** In `Odysseus`, `bundle exec rake` runs RSpec **and** RuboCop and must be clean in both gems. **`odysseus-sail-rolling` has no `Rakefile` and no `.rubocop.yml`** — use `bundle exec rspec` there, and do not add either.
- **Do NOT edit `.rubocop_todo.yml`** in either odysseus gem, and do not add an inline `rubocop:disable`.
- `config.warnings = true` in odysseus-core: no unused variables, shadowed locals, or method redefinitions.
- Specs never open a network connection; `Odysseus::Deployer::SSH` and `Odysseus::Docker::Client` are always doubles. The one deliberate exception is `Plugins.load!`, which must really `require` a real file (Task 1).
- Every new spec is checked against a deliberate mutation of the code under test — break it, confirm a **named** example fails, restore. Every defect found across the last three branches came this way, most often from a fixture too uniform to tell the mutant from correct code.
- The sail's Gemfile already points at `../Odysseus/odysseus-core` via `path:`, so it picks up Task 2's mixin with no version juggling. Task 3 depends on Task 2 having landed.

---

## Design decisions carried from the spec

**`plugins:` validates itself.** Every other key is shape-checked by `Validators::Config`, but `plugins:` is consumed before the validator runs, so `Plugins.load!` raises `ConfigError` for a malformed list itself.

**Ambiguous key pairs raise, never resolve silently.** Both `plugins:`/`sails:` and `dependencies:`/`accessories:` error when both are present. The existing `config['dependencies'] || config['accessories']` silently prefers the new key; that changes.

**`odysseus validate` will load plugins**, because it parses. That makes it a real pre-flight, at the cost of failing on a machine without the sail installed.

**This ships without host verification.** Rollback and retention were both proven with a real deploy; rolling will not be. The docs must say so.

---

## File Structure

**Create — `Odysseus`:**

| File | Responsibility |
| --- | --- |
| `odysseus-core/lib/odysseus/plugins.rb` | `Odysseus::Plugins` — resolve the key, validate its shape, require each gem, turn every failure into `ConfigError`. |
| `odysseus-core/lib/odysseus/core/deploy_versioning.rb` | `Odysseus::Core::DeployVersioning` — the container version tag and version labels, shared by every orchestrator. |
| `odysseus-core/spec/odysseus/plugins_spec.rb` | Loading, against a real file on `$LOAD_PATH`. |
| `odysseus-core/spec/odysseus/core/deploy_versioning_spec.rb` | The mixin's two methods. |
| `odysseus-core/spec/fixtures/plugins/fake_sail.rb` | A real requireable file that registers a fake sail. |

**Modify — `Odysseus`:**

| File | Change |
| --- | --- |
| `odysseus-core/lib/odysseus/config/parser.rb` | Call `Plugins.load!` between `load_yaml` and `validate!`; raise on `dependencies:`+`accessories:`. |
| `odysseus-core/lib/odysseus/orchestrator/web_deploy.rb` | Include the mixin; delete the two now-shared methods. |
| `odysseus-core/lib/odysseus/orchestrator/job_deploy.rb` | Same. |
| `odysseus-core/spec/odysseus/config/parser_spec.rb` | Cover plugin loading order and the ambiguous-pair error. |

**Modify — `odysseus-sail-rolling`:**

| File | Change |
| --- | --- |
| `lib/odysseus/sail/rolling/orchestrator.rb` | Include the mixin; real version and labels; role-correct container label at **two** sites; conditional pull. |
| `odysseus-sail-rolling.gemspec` | `odysseus-core` `~> 0.2` → `~> 0.5`. |
| `spec/odysseus/sail/rolling/orchestrator_spec.rb` | Cover all four fixes. |
| `docs/rolling-deploy.md` | Document `plugins:`, and that this is unverified on a real host. |

**Docs — `Odysseus`:** both CHANGELOGs, `odysseus-core/README.md`, `odysseus-cli/README.md`, `README.md`, `TODO.md`.

---

### Task 1: `Odysseus::Plugins`, parser ordering, and ambiguous key pairs

**Repo:** `Odysseus`, from `odysseus-core/`.

**Files:**
- Create: `lib/odysseus/plugins.rb`, `spec/odysseus/plugins_spec.rb`, `spec/fixtures/plugins/fake_sail.rb`
- Modify: `lib/odysseus/config/parser.rb`, `spec/odysseus/config/parser_spec.rb`

**Interfaces:**
- Consumes: the raw string-keyed hash from `YAML.load_file`; `Odysseus::ConfigError`.
- Produces: `Odysseus::Plugins.load!(raw_config) -> nil`, raising `Odysseus::ConfigError` on an ambiguous key pair, a malformed list, or a gem that will not load.

- [ ] **Step 1: Write the fixture that gets really required**

`spec/fixtures/plugins/fake_sail.rb`:

```ruby
# spec/fixtures/plugins/fake_sail.rb
# Really required by plugins_spec via $LOAD_PATH, so the spec proves a gem's
# registration side effect actually happens. Stubbing Kernel#require would only
# assert that the stub was called.

Odysseus::Sails.register(:fake, Class.new)
```

- [ ] **Step 2: Write the failing tests**

`spec/odysseus/plugins_spec.rb`:

```ruby
# spec/odysseus/plugins_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Plugins do
  # The fixture directory goes on the load path so `require 'fake_sail'`
  # resolves — the same way a real gem's lib directory would.
  around do |example|
    Odysseus::Sails.reset!
    $LOAD_PATH.unshift(fixture_path('plugins'))
    example.run
  ensure
    $LOAD_PATH.delete(fixture_path('plugins'))
    $LOADED_FEATURES.reject! { |f| f.include?('fake_sail') }
    Odysseus::Sails.reset!
  end

  describe '.load!' do
    it 'requires each named plugin, so its registration runs' do
      described_class.load!('plugins' => ['fake_sail'])

      expect(Odysseus::Sails.registered?(:fake)).to be true
    end

    it 'accepts sails as an alias for plugins' do
      described_class.load!('sails' => ['fake_sail'])

      expect(Odysseus::Sails.registered?(:fake)).to be true
    end

    it 'does nothing when neither key is present' do
      expect { described_class.load!('service' => 'myapp') }.not_to raise_error
      expect(Odysseus::Sails.available).to be_empty
    end

    it 'loads nothing for an empty list' do
      described_class.load!('plugins' => [])

      expect(Odysseus::Sails.available).to be_empty
    end

    # Silently preferring one would let someone edit the wrong key and see no
    # effect, which is the failure mode a mistyped retain_versions already cost
    # a diagnosis round-trip.
    it 'refuses a config carrying both keys' do
      expect { described_class.load!('plugins' => ['a'], 'sails' => ['b']) }
        .to raise_error(Odysseus::ConfigError, /both `plugins:` and `sails:`/)
    end

    it 'names the gem that could not be loaded' do
      expect { described_class.load!('plugins' => ['odysseus-sail-nonexistent']) }
        .to raise_error(Odysseus::ConfigError, /odysseus-sail-nonexistent/)
    end

    it 'suggests how to fix a missing gem' do
      expect { described_class.load!('plugins' => ['odysseus-sail-nonexistent']) }
        .to raise_error(Odysseus::ConfigError, /gem install/)
    end

    it 'refuses a list that is not an array' do
      expect { described_class.load!('plugins' => 'odysseus-sail-rolling') }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end

    it 'refuses a list containing something that is not a string' do
      expect { described_class.load!('plugins' => [{ 'name' => 'x' }]) }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end

    it 'refuses a key present with no value' do
      expect { described_class.load!('plugins' => nil) }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end
  end
end
```

Check `spec/spec_helper.rb` for the existing `fixture_path` helper and reuse it; do not define a second one.

- [ ] **Step 3: Run to verify failure**

Run: `bundle exec rspec spec/odysseus/plugins_spec.rb`
Expected: FAIL, 10 examples, `NameError: uninitialized constant Odysseus::Plugins`.

- [ ] **Step 4: Write the implementation**

Create `lib/odysseus/plugins.rb`:

```ruby
# lib/odysseus/plugins.rb

module Odysseus
  # Loads the gems named in deploy.yml's `plugins:` list, so that the sail and
  # host-provider registries have something in them.
  #
  # Runs before config validation, because the validator is what asks whether a
  # named strategy is registered. That ordering is why this validates its own
  # shape rather than leaving it to Validators::Config like every other key.
  #
  # Requiring a gem name read from a config file is a real capability, and is
  # documented as such: deploy.yml already runs arbitrary docker commands as
  # root on the target hosts, so this widens visibility rather than trust.
  module Plugins
    # `sails:` matches the project's own vocabulary; `plugins:` is what someone
    # guesses without reading the docs. Both work, but not together.
    KEYS = %w[plugins sails].freeze

    # @param raw_config [Hash] the string-keyed hash straight from YAML
    # @raise [Odysseus::ConfigError] on an ambiguous pair, a bad shape, or a
    #   gem that will not load
    def self.load!(raw_config)
      names = names_from(raw_config)
      return if names.nil? && !key_present?(raw_config)

      unless names.is_a?(Array) && names.all?(String)
        raise Odysseus::ConfigError,
              "`plugins:` must be a list of gem names, got #{names.inspect}"
      end

      names.each { |name| require_plugin(name) }
      nil
    end

    def self.key_present?(raw_config)
      KEYS.any? { |key| raw_config.key?(key) }
    end

    def self.names_from(raw_config)
      present = KEYS.select { |key| raw_config.key?(key) }

      if present.length > 1
        raise Odysseus::ConfigError,
              'deploy.yml has both `plugins:` and `sails:` — use one; they name the same thing'
      end

      present.empty? ? nil : raw_config[present.first]
    end

    def self.require_plugin(name)
      require name
    rescue LoadError
      raise Odysseus::ConfigError,
            "Could not load the plugin `#{name}` named in deploy.yml. Install it with " \
            "`gem install #{name}`, or remove it from `plugins:`."
    end

    private_class_method :key_present?, :names_from, :require_plugin
  end
end
```

Note the `return if names.nil? && !key_present?` guard: a key present with an empty value yields `nil`, and that is a malformed config that must raise, not a silently absent one.

- [ ] **Step 5: Wire it into the parser and forbid the other ambiguous pair**

In `lib/odysseus/config/parser.rb`, `#parse` becomes:

```ruby
      def parse
        raw_config = load_yaml
        Odysseus::Plugins.load!(raw_config)
        validate!(raw_config)
        normalize(raw_config)
      rescue Psych::SyntaxError => e
        raise Odysseus::ConfigParseError, "Failed to parse YAML: #{e.message}"
      end
```

Keep the existing `rescue` exactly as it is. Then replace the `dependencies:` line in `normalize`:

```ruby
          dependencies: parse_dependencies(dependencies_config(config)),
```

and add the private helper next to `parse_dependencies`:

```ruby
      # `accessories:` is the former name, still accepted. Both present is an
      # error rather than a silent preference: a config with two contradictory
      # lists should say so.
      def dependencies_config(config)
        if config.key?('dependencies') && config.key?('accessories')
          raise Odysseus::ConfigError,
                'deploy.yml has both `dependencies:` and `accessories:` — use one; ' \
                '`accessories:` is the former name'
        end

        config['dependencies'] || config['accessories']
      end
```

Add to `spec/odysseus/config/parser_spec.rb`:

```ruby
  describe 'plugin loading' do
    # Loading must precede validation: the validator is what rejects a strategy
    # no sail has registered, so a plugin loaded afterwards would be too late.
    it 'loads plugins before validating, so a strategy the plugin registers is accepted' do
      order = []
      allow(Odysseus::Plugins).to receive(:load!) { order << :load }
      allow_any_instance_of(Odysseus::Validators::Config).to receive(:validate!) { order << :validate }

      described_class.new(fixture_path('deploy.yml')).parse

      expect(order).to eq(%i[load validate])
    end
  end

  describe 'dependencies and accessories together' do
    it 'refuses a config carrying both keys' do
      expect { described_class.new(fixture_path('deploy-both-dependency-keys.yml')).parse }
        .to raise_error(Odysseus::ConfigError, /both `dependencies:` and `accessories:`/)
    end
  end
```

Create `spec/fixtures/deploy-both-dependency-keys.yml` — a minimal valid config carrying both `dependencies:` and `accessories:`, each with one entry. Model it on `deploy-dependencies.yml`.

`allow_any_instance_of` is ordinarily a smell; here it is the least-bad way to observe ordering across two collaborators without restructuring the parser. If the project's RuboCop or RSpec config forbids it, assert the ordering instead by having the `Plugins.load!` stub raise a sentinel and confirming validation never ran.

- [ ] **Step 6: Run to verify passing, then the whole suite**

Run: `bundle exec rspec spec/odysseus/plugins_spec.rb spec/odysseus/config/parser_spec.rb`
Expected: PASS.

Then `bundle exec rspec`. Every existing spec that parses a config now also calls `Plugins.load!`; with no `plugins:` key that is a no-op, so nothing should break. If something does, understand it before changing it.

- [ ] **Step 7: Mutation-check**

Each must break a **named** example; restore after each:
1. `require name` → `nil` in `require_plugin` → "requires each named plugin" fails.
2. `KEYS` → `%w[plugins]` → "accepts sails as an alias" fails.
3. The `present.length > 1` guard removed → "refuses a config carrying both keys" fails.
4. `names.all?(String)` → `true` → "refuses a list containing something that is not a string" fails.
5. `Plugins.load!` moved *after* `validate!` in `#parse` → "loads plugins before validating" fails.
6. The `dependencies_config` guard removed → "refuses a config carrying both keys" (the dependencies one) fails.
7. `return if names.nil? && !key_present?` → `return if names.nil?` → "refuses a key present with no value" fails.

- [ ] **Step 8: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
cd ../odysseus-cli && bundle exec rake
git add odysseus-core/lib odysseus-core/spec
git commit -m "Load sail plugins named in deploy.yml, before validating it"
```

---

### Task 2: `Odysseus::Core::DeployVersioning`

**Repo:** `Odysseus`, from `odysseus-core/`.

**Files:**
- Create: `lib/odysseus/core/deploy_versioning.rb`, `spec/odysseus/core/deploy_versioning_spec.rb`
- Modify: `lib/odysseus/orchestrator/web_deploy.rb`, `lib/odysseus/orchestrator/job_deploy.rb`

**Interfaces:**
- Consumes: `@config[:deploy_version]`, an `Odysseus::DeployVersion` or nil.
- Produces: `#deploy_version_tag(image) -> String` and `#version_labels -> Hash{String=>String}`, available to any class that includes the module and exposes `@config`.

**Verified before writing this plan:** the two methods are **byte-identical** in `web_deploy.rb` and `job_deploy.rb`. This is a pure extraction — the bodies move unchanged.

- [ ] **Step 1: Write the failing test**

Create `spec/odysseus/core/deploy_versioning_spec.rb`:

```ruby
# spec/odysseus/core/deploy_versioning_spec.rb
#
# Exercised through a minimal host class rather than an orchestrator: the module
# is the contract every orchestrator shares, including sail-provided ones in
# other gems, so it is tested independently of any one of them.

require 'spec_helper'

RSpec.describe Odysseus::Core::DeployVersioning do
  let(:host_class) do
    Class.new do
      include Odysseus::Core::DeployVersioning

      def initialize(config)
        @config = config
      end
    end
  end

  def with(deploy_version)
    host_class.new(deploy_version.nil? ? {} : { deploy_version: deploy_version })
  end

  let(:resolved) do
    Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
  end

  describe '#deploy_version_tag' do
    it 'is the resolved version when the deploy has one' do
      expect(with(resolved).deploy_version_tag('myapp:ignored')).to eq('abc123def456')
    end

    # A caller passing --image still gets a self-describing container name.
    it 'falls back to the tag in the image reference' do
      expect(with(nil).deploy_version_tag('myapp-production:v9')).to eq('v9')
    end

    it 'handles an image reference carrying a registry port' do
      expect(with(nil).deploy_version_tag('registry.example.com:5000/myapp:v9')).to eq('v9')
    end
  end

  describe '#version_labels' do
    it 'always stamps the deploy time in UTC ISO 8601' do
      expect(with(nil).version_labels['odysseus.deployed_at'])
        .to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'records the git ref when the version came from a commit' do
      expect(with(resolved).version_labels['odysseus.git_ref']).to eq('main')
    end

    # An explicit --image says nothing about a commit, so claiming one would lie.
    it 'omits the git ref when there is no resolved version' do
      expect(with(nil).version_labels).not_to have_key('odysseus.git_ref')
    end

    it 'omits the git ref when the resolved version has none' do
      tagless = Odysseus::DeployVersion.new(version: 'v9', ref: nil, deployer: 'dev@example.com')

      expect(with(tagless).version_labels).not_to have_key('odysseus.git_ref')
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/odysseus/core/deploy_versioning_spec.rb`
Expected: FAIL, 7 examples, `NameError: uninitialized constant Odysseus::Core::DeployVersioning`.

- [ ] **Step 3: Write the module**

Create `lib/odysseus/core/deploy_versioning.rb`:

```ruby
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
```

- [ ] **Step 4: Use it from both orchestrators**

In `lib/odysseus/orchestrator/web_deploy.rb`, add below the existing `include`:

```ruby
      include Odysseus::Core::DeployVersioning
```

and **delete** the private `deploy_version_tag` and `version_labels` definitions, including their comments — the comments moved into the module. Do the same in `lib/odysseus/orchestrator/job_deploy.rb`.

The methods become public where they were private. That matches `VolumeNamespacer`, whose `namespace_volumes` is public on every includer, and is what lets a sail in another gem call them.

- [ ] **Step 5: Run the whole suite**

Run: `bundle exec rspec`
Expected: PASS, with no changes to `web_deploy_spec.rb` or `job_deploy_spec.rb`. **Those two suites passing unchanged is the evidence the extraction preserved behaviour** — if either needs editing, the extraction was not faithful. Investigate rather than adjusting the spec.

- [ ] **Step 6: Mutation-check**

1. `resolved.version` → `image.to_s.split(':').last` (drop the early return) → "is the resolved version" fails, and so should existing orchestrator examples.
2. `labels['odysseus.git_ref'] = resolved.ref if resolved&.ref` → unconditional → "omits the git ref when the resolved version has none" fails.
3. Remove `include Odysseus::Core::DeployVersioning` from `web_deploy.rb` → `NoMethodError` in the WebDeploy suite, proving the orchestrators really use the module rather than retaining a copy.

- [ ] **Step 7: Run rake and commit**

```bash
cd odysseus-core && bundle exec rake
git add odysseus-core/lib odysseus-core/spec
git commit -m "Share container version identity between orchestrators"
```

---

### Task 3: Bring `odysseus-sail-rolling` current

**Repo:** `odysseus-sail-rolling` — `cd ../odysseus-sail-rolling`. Depends on Task 2.

**Files:**
- Modify: `lib/odysseus/sail/rolling/orchestrator.rb`, `odysseus-sail-rolling.gemspec`, `spec/odysseus/sail/rolling/orchestrator_spec.rb`

**Verify first:** `bundle exec rspec` passes (17 examples) before you change anything. There is no `Rakefile` and no `.rubocop.yml` here — do not add either.

Four fixes.

**(a) Real version identity.** Add `include Odysseus::Core::DeployVersioning` beside the existing `include Odysseus::Core::VolumeNamespacer`, then in `start_container` replace:

```ruby
              service: service,
              version: timestamp,
```

with:

```ruby
              service: Odysseus::Docker::Labels.service_for(service: service, role: role),
              version: deploy_version_tag(image),
              labels: version_labels,
```

and delete the now-unused `timestamp` local. `Docker::Client#run` already accepts `labels:`.

**(b) Role-correct container label — exactly two sites.** The orchestrator names `service:` in five places, and **three of them must not change**:

| Line | Call | Change? |
| --- | --- | --- |
| ~95 | the returned result hash | **No** — reporting only |
| ~125 | `@caddy.drain_upstream(service:)` | **No** — a Caddy route key, a different namespace |
| ~182 | `@caddy.add_upstream(service:)` | **No** — same |
| ~215 | `@docker.run(options: { service: })` | **Yes** — becomes the `odysseus.service` label |
| ~322 | `@docker.list(service:)` | **Yes** — filters on that label |

Changing the Caddy calls would break proxy routing on every rolling deploy. Site 215 is covered by (a). For site 322, `cleanup_orphaned_containers(service, container_count, name_pattern)` needs the role to compute the label — change its signature to take the already-computed label, and pass `Odysseus::Docker::Labels.service_for(service: service, role: role)` from `deploy`.

**(c) Do not pull without a registry.** `@docker.pull(image)` in `deploy` is unconditional, so rolling breaks under pussh — the default distribution — because there is no registry to pull from. Neither `WebDeploy` nor `JobDeploy` pulls at all. Guard it:

```ruby
          if @config.dig(:registry, :server)
            log 'Pulling image...'
            @docker.pull(image)
            log '  Image pulled'
          end
```

**(d) Gemspec constraint.** `odysseus-core` `~> 0.2` → `~> 0.5`. `~> 0.2` excludes 0.5.0 outright; the suite passes today only through the Gemfile's local `path:` override, which would not save a published gem.

- [ ] **Step 1: Write the failing tests**

Add to `spec/odysseus/sail/rolling/orchestrator_spec.rb`. Read its existing setup first and reuse its doubles and config shape rather than inventing new ones.

```ruby
  describe 'version identity' do
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
    end

    # Before this, the sail stamped odysseus.version with a timestamp, so
    # retention's in-use guard — which compares labels against deploy log
    # versions — could never match, and status showed a timestamp not a commit.
    it 'labels the container with the deployed version, not a timestamp' do
      expect(mock_docker).to receive(:run)
        .with(hash_including(options: hash_including(version: 'abc123def456')))
        .and_return('container123')

      orchestrator_with(deploy_version: resolved).deploy(image_tag: 'abc123def456')
    end

    it 'labels the container with the git ref and deploy time' do
      expect(mock_docker).to receive(:run) do |args|
        labels = args[:options][:labels]
        expect(labels['odysseus.git_ref']).to eq('main')
        expect(labels['odysseus.deployed_at']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
        'container123'
      end

      orchestrator_with(deploy_version: resolved).deploy(image_tag: 'abc123def456')
    end
  end

  describe 'the odysseus.service label' do
    it 'uses the bare service name for the web role' do
      expect(mock_docker).to receive(:run)
        .with(hash_including(options: hash_including(service: 'myapp')))
        .and_return('container123')

      orchestrator.deploy(image_tag: 'v1', role: :web)
    end

    # A jobs role labelled `myapp` instead of `myapp-jobs` is invisible to
    # status, rollback and retention — the defect that blocked the retention
    # branch at final review.
    it 'suffixes the role for a non-web role' do
      expect(mock_docker).to receive(:run)
        .with(hash_including(options: hash_including(service: 'myapp-jobs')))
        .and_return('container123')

      orchestrator.deploy(image_tag: 'v1', role: :jobs)
    end

    it 'looks for orphaned containers under the same label it wrote' do
      expect(mock_docker).to receive(:list).with(service: 'myapp-jobs', all: true).and_return([])

      orchestrator.deploy(image_tag: 'v1', role: :jobs)
    end

    # Caddy routes are keyed by service, not by the container label, so the
    # proxy calls must keep the bare name whatever the role.
    it 'still addresses Caddy by the bare service name' do
      expect(mock_caddy).to receive(:add_upstream).with(hash_including(service: 'myapp'))

      orchestrator.deploy(image_tag: 'v1', role: :jobs)
    end
  end

  describe 'image distribution' do
    # pussh is the default: the image is already on the host and there is no
    # registry to pull from, so pulling would fail the deploy outright.
    it 'does not pull when no registry is configured' do
      expect(mock_docker).not_to receive(:pull)

      orchestrator.deploy(image_tag: 'v1')
    end

    it 'pulls when a registry is configured' do
      expect(mock_docker).to receive(:pull).with('myapp-production:v1')

      orchestrator_with(registry: { server: 'registry.example.com' }).deploy(image_tag: 'v1')
    end
  end
```

The spec already defines `mock_ssh`, `mock_docker`, `mock_caddy`, `silent_logger`, `config` and `orchestrator` (lines 6-55) — verified; reuse them rather than redefining. It has no config-override helper, so add this one beside `let(:orchestrator)`:

```ruby
  def orchestrator_with(**overrides)
    described_class.new(ssh: mock_ssh, config: config.merge(overrides), logger: silent_logger)
  end
```

`config` is the symbol-keyed parsed shape, so `config.merge(deploy_version: resolved)` and `config.merge(registry: { server: '…' })` are the right form.

- [ ] **Step 2: Run to verify failure**

Run: `cd ../odysseus-sail-rolling && bundle exec rspec`
Expected: the new examples fail; the original 17 still pass.

- [ ] **Step 3: Make the four changes** as described above.

- [ ] **Step 4: Run to verify passing**

Run: `bundle exec rspec`
Expected: PASS, all examples. The original 17 must still pass — the rolling behaviour itself is unchanged.

- [ ] **Step 5: Mutation-check**

1. `version: deploy_version_tag(image)` → `version: timestamp` (restore the old line) → "labels the container with the deployed version" fails.
2. Remove `labels: version_labels` → "labels the container with the git ref" fails.
3. `Labels.service_for(...)` → bare `service` at site 215 → "suffixes the role for a non-web role" fails.
4. Same at site 322 → "looks for orphaned containers under the same label" fails.
5. `Labels.service_for(...)` applied to the Caddy `add_upstream` call → "still addresses Caddy by the bare service name" fails. **This one matters most** — it is the mutation that proves the plan's two-sites-only rule is enforced by a test rather than by hoping.
6. Remove the `@config.dig(:registry, :server)` guard → "does not pull when no registry is configured" fails.

- [ ] **Step 6: Commit, in the sail repo**

```bash
cd ../odysseus-sail-rolling
bundle exec rspec
git add lib spec odysseus-sail-rolling.gemspec
git commit -m "Carry odysseus version identity, label by role, and stop pulling without a registry"
```

---

### Task 4: Documentation

**Two repos.** Commit separately in each.

- [ ] **Step 1: Read what is currently claimed**

```bash
grep -rn "strategy\|sail\|plugin" README.md odysseus-core/README.md odysseus-cli/README.md | head -20
```

The READMEs describe `deploy.strategy` and the `aws:` hook as usable. P0 already removed claims for features that did not exist; these become true for the first time, so they need documenting properly rather than deleting.

- [ ] **Step 2: `Odysseus` — core CHANGELOG, under `## [Unreleased]`**

```markdown
### Added
- `plugins:` in deploy.yml, a list of gem names loaded before the config is
  validated, so a sail can register its strategy in time for
  `servers.<role>.deploy.strategy` to resolve. `sails:` is accepted as an alias.
  Until now nothing ever loaded a sail: both registries raised "is the gem
  loaded?" for every user, so `deploy.strategy` and the `aws:` host hook were
  unreachable while both READMEs described them.
- `Odysseus::Core::DeployVersioning`, the shared container version identity —
  `odysseus.version`, `odysseus.git_ref` and `odysseus.deployed_at` — included
  by both built-in orchestrators and available to sails. `status`, `rollback`
  and image retention all read these labels, so an orchestrator that invents
  its own scheme is invisible to them.

### Changed
- A deploy.yml carrying both `plugins:` and `sails:`, or both `dependencies:`
  and `accessories:`, is now an error. Silently preferring one meant editing
  the wrong key had no visible effect.
- `odysseus validate` loads plugins, so it now catches a plugin gem that is not
  installed. It will fail on a machine without the gem, where it passed before.
```

- [ ] **Step 3: `Odysseus` — CLI CHANGELOG, READMEs, TODO**

CLI changelog: `odysseus validate` now catches a missing plugin gem; point at core's entry.

READMEs: document `plugins:` where the other top-level keys live, with the rolling sail as the worked example, and **state plainly that the rolling strategy has not been exercised on a real host**, unlike the built-in strategies. Do not imply parity.

`TODO.md`: the P1 "Plugin (sail) loading" item is done. Add: `odysseus-sail-aws-asg` remains unverified — it cannot `bundle install` locally (`aws-sdk-autoscaling`, `aws-sdk-ec2`, `aws-partitions` missing), so nothing here exercises it even though the loading mechanism covers it.

- [ ] **Step 4: `odysseus-sail-rolling` — `docs/rolling-deploy.md`**

Add how to enable it — `gem install odysseus-sail-rolling`, then `plugins:` plus `deploy.strategy` — and a short honest note that the gem has never run against a live fleet and that its container labels only became compatible with `status`, `rollback` and retention in this change.

- [ ] **Step 5: Commit in each repo**

```bash
cd Odysseus && git add README.md TODO.md odysseus-core odysseus-cli && \
  git commit -m "Document plugin loading"
cd ../odysseus-sail-rolling && git add docs && \
  git commit -m "Document enabling the rolling sail"
```

---

## Verification

- [ ] `cd odysseus-core && bundle exec rake` — clean
- [ ] `cd odysseus-cli && bundle exec rake` — clean
- [ ] `cd ../odysseus-sail-rolling && bundle exec rspec` — clean
- [ ] Every new example checked against a deliberate mutation
- [ ] `git status --porcelain` empty in **both** repos

**End-to-end check, offline.** With `odysseus-sail-rolling` in the CLI's Gemfile via `path:`, run `odysseus validate --config <a config with plugins: and strategy: rolling>`. It must succeed — proving the load-then-validate ordering works through the real parser, which no unit test covers end to end. Then remove the `plugins:` line and confirm it fails with the "not registered" error.

**No real-host verification.** Rollback and retention were each proven with a live deploy; this is not, by decision. The READMEs say so. If rolling is ever run in anger, the first target should be a service with a non-web role, since role-correct labelling is the change most likely to be wrong in a way specs cannot show.

## Out of scope

- **`odysseus-sail-aws-asg`.** It will load through the same mechanism, but its suite cannot run locally, so nothing here verifies it.
- **Auto-discovery of installed `odysseus-sail-*` gems**, and folding rolling into core — both considered and rejected in the spec.
- **Adding RuboCop or a Rakefile to the sail repo.**
- **Releasing the sail gem.** It cannot be published until core 0.5.1 is, because its gemspec will require `~> 0.5`.
