# Deploy Versioning — Phases 1–2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every deployed container traceable to a git commit, and have each host record its own deploy history.

**Architecture:** A local `Git` wrapper answers questions about the app's work tree. A `VersionResolver` turns those answers plus `--image` into an immutable `DeployVersion` (version, ref, deployer). `Executor` resolves it once and merges it into the config hash handed to orchestrators, which use it for the container name and three labels. A `DeployLog` appends one line per successful deploy to `/var/lib/odysseus/<service>/deploys.log` on each host.

**Tech Stack:** Ruby 3.2+, RSpec 3.13, Open3 for local git, existing `Deployer::SSH` for remote commands, Zeitwerk autoloading.

Implements phases 1 and 2 of `docs/specs/2026-08-12-deploy-versioning-and-rollback.md`. Phases 3–5 (rollback, retention, git notes) get a separate plan once these interfaces exist.

## Global Constraints

- Ruby `>= 3.2.0`. `Data.define` is available and preferred over `Struct` for value objects.
- RuboCop must stay clean: single-quoted strings, `Layout/LineLength` max 140. `bundle exec rake` runs RSpec + RuboCop and must exit 0 in **both** gems before every commit.
- Version string: `git rev-parse --short=12 HEAD`.
- Dirty check: `git status --porcelain --untracked-files=no`, any output means dirty. Untracked files warn, never abort.
- Labels: `odysseus.service`, `odysseus.version` (the SHA), `odysseus.deployed_at` (ISO 8601 UTC), `odysseus.git_ref`. **No role label** — the role is recoverable from `odysseus.service`.
- Container name: `<service>-<version>-<timestamp>` where timestamp is `%Y%m%d%H%M%S`.
- `deploys.log` path: `/var/lib/odysseus/<service>/deploys.log`, where `<service>` is the plain `service:` value, never the role-suffixed name.
- `deploys.log` line: `<iso8601> <version> <role> <git_ref> <deployer> <kind> [from=<version>]`.
- No `:latest` tag is ever produced. `--image latest` remains usable.
- **Sail plugin compatibility:** external sails implement `deploy(image_tag:, role:)` and are constructed with exactly `ssh:, config:, logger:, secrets_loader:`. Do not add or rename a keyword on either. Version metadata travels inside the `config` hash under `:deploy_version`.
- Every new spec is checked against a deliberate mutation of the code under test before its task is considered done, per `CONTRIBUTING.md`.

## File Structure

| File | Responsibility |
| --- | --- |
| `odysseus-core/lib/odysseus/git.rb` (create) | Local git queries for one directory. No deploy knowledge. |
| `odysseus-core/lib/odysseus/deploy_version.rb` (create) | `Data` value object: version, ref, deployer. |
| `odysseus-core/lib/odysseus/version_resolver.rb` (create) | Resolution rules and their errors. Consumes `Git`, produces `DeployVersion`. |
| `odysseus-core/lib/odysseus/docker/labels.rb` (create) | Parses the flat label string `docker ps` emits. |
| `odysseus-core/lib/odysseus/deploy_log.rb` (create) | Reads and appends the per-host deploy log. |
| `odysseus-core/lib/odysseus/docker/client.rb` (modify) | Quote label values. |
| `odysseus-core/lib/odysseus/deployer/executor.rb` (modify) | Resolve the version once, expose it, merge into config. |
| `odysseus-core/lib/odysseus/orchestrator/web_deploy.rb` (modify) | Container name, labels, log append. |
| `odysseus-core/lib/odysseus/orchestrator/job_deploy.rb` (modify) | Same, for non-web roles. |
| `odysseus-cli/lib/odysseus/cli/cli.rb` (modify) | Stop defaulting to `latest`; show version in `deploy`/`build`/`status`; resolve running version for `app` commands. |

---

### Task 1: Local git queries

**Files:**
- Create: `odysseus-core/lib/odysseus/git.rb`
- Test: `odysseus-core/spec/odysseus/git_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Odysseus::Git.new(dir)` with `#repository?` → Boolean, `#head_sha(length: 12)` → String or nil, `#uncommitted_changes?` → Boolean, `#untracked_files?` → Boolean, `#ref` → String or nil, `#committer_email` → String or nil.
- `head_sha` and `ref` answer nil when git cannot tell us — most realistically a repository with no commits yet. `Git` reports facts, including "couldn't"; deciding that a missing sha is fatal belongs to `VersionResolver` in Task 2, alongside the dirty-tree and not-a-repository rules.

- [ ] **Step 1: Write the failing test**

Create `odysseus-core/spec/odysseus/git_spec.rb`. These run against real temporary repositories — stubbing `git` would only assert that the stub was called.

```ruby
# spec/odysseus/git_spec.rb

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

RSpec.describe Odysseus::Git do
  # Build a real repository. Config is set locally so a developer's global
  # config cannot change the outcome.
  def make_repo(dir)
    Open3.capture3('git', 'init', '--initial-branch=main', chdir: dir)
    Open3.capture3('git', 'config', 'user.email', 'dev@example.com', chdir: dir)
    Open3.capture3('git', 'config', 'user.name', 'Dev', chdir: dir)
    File.write(File.join(dir, 'app.rb'), "puts 'v1'\n")
    Open3.capture3('git', 'add', '.', chdir: dir)
    Open3.capture3('git', 'commit', '-m', 'first', chdir: dir)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  subject(:git) { described_class.new(@dir) }

  context 'in a git work tree' do
    before { make_repo(@dir) }

    it 'reports that it is a repository' do
      expect(git.repository?).to be true
    end

    it 'returns a 12 character head sha' do
      expect(git.head_sha).to match(/\A[0-9a-f]{12}\z/)
    end

    it 'returns the branch name' do
      expect(git.ref).to eq('main')
    end

    it 'returns the committer email from the repository config' do
      expect(git.committer_email).to eq('dev@example.com')
    end

    it 'is clean' do
      expect(git.uncommitted_changes?).to be false
      expect(git.untracked_files?).to be false
    end

    it 'reports a modified tracked file as uncommitted' do
      File.write(File.join(@dir, 'app.rb'), "puts 'v2'\n")

      expect(git.uncommitted_changes?).to be true
    end

    it 'does not treat an untracked file as uncommitted' do
      File.write(File.join(@dir, 'scratch.txt'), 'notes')

      expect(git.uncommitted_changes?).to be false
      expect(git.untracked_files?).to be true
    end

    it 'reports HEAD as the ref when detached' do
      sha = git.head_sha(length: 40)
      Open3.capture3('git', 'checkout', sha, chdir: @dir)

      expect(git.ref).to eq('HEAD')
    end
  end

  context 'outside a git work tree' do
    it 'reports that it is not a repository' do
      expect(git.repository?).to be false
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/git_spec.rb
```

Expected: every example fails with `NameError: uninitialized constant Odysseus::Git`.

- [ ] **Step 3: Write minimal implementation**

Create `odysseus-core/lib/odysseus/git.rb`:

```ruby
# lib/odysseus/git.rb

require 'open3'

module Odysseus
  # Answers questions about a local git work tree. Knows nothing about deploys:
  # the rules that turn these answers into a version live in VersionResolver.
  class Git
    # @param dir [String] directory inside the work tree
    def initialize(dir)
      @dir = dir
    end

    # @return [Boolean] true when dir is inside a git work tree
    def repository?
      _, status = capture('rev-parse', '--git-dir')
      status.success?
    end

    # @param length [Integer] characters of the object name to return
    # @return [String, nil] abbreviated commit sha of HEAD
    def head_sha(length: 12)
      out, status = capture('rev-parse', "--short=#{length}", 'HEAD')
      status.success? ? out : nil
    end

    # Tracked modifications only. Untracked files are reported separately: they
    # are usually local noise, and blocking on them would make deploys hostile.
    # @return [Boolean]
    def uncommitted_changes?
      out, status = capture('status', '--porcelain', '--untracked-files=no')
      status.success? && !out.empty?
    end

    # @return [Boolean] true when the work tree has files git is not tracking
    def untracked_files?
      out, status = capture('ls-files', '--others', '--exclude-standard')
      status.success? && !out.empty?
    end

    # @return [String, nil] branch name, or 'HEAD' when detached
    def ref
      out, status = capture('rev-parse', '--abbrev-ref', 'HEAD')
      status.success? ? out : nil
    end

    # @return [String, nil] user.email as git resolves it for this repository
    def committer_email
      out, status = capture('config', 'user.email')
      status.success? && !out.empty? ? out : nil
    end

    private

    def capture(*args)
      stdout, _stderr, status = Open3.capture3('git', *args, chdir: @dir)
      [stdout.strip, status]
    rescue Errno::ENOENT
      # git is not installed; treat as "not a repository" rather than crashing.
      ['', FailedStatus.new]
    end

    # Stands in for a Process::Status when git could not be executed at all.
    class FailedStatus
      def success?
        false
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/git_spec.rb
```

Expected: PASS, 9 examples.

- [ ] **Step 5: Verify the specs have teeth**

Break the code deliberately and confirm the specs catch it. Run each, then revert with `git checkout -- lib/odysseus/git.rb`:

1. In `uncommitted_changes?`, drop `--untracked-files=no` → the untracked example must fail.
2. In `head_sha`, change `--short=#{length}` to `--short=7` → the 12-character example must fail.

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/git_spec.rb
git checkout -- lib/odysseus/git.rb
```

- [ ] **Step 6: Run the full suite and linter**

```bash
cd odysseus-core && bundle exec rake
```

Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/git.rb odysseus-core/spec/odysseus/git_spec.rb
git commit -m "Add Git wrapper for local work tree queries"
```

---

### Task 2: Version resolution

**Files:**
- Create: `odysseus-core/lib/odysseus/deploy_version.rb`
- Create: `odysseus-core/lib/odysseus/version_resolver.rb`
- Test: `odysseus-core/spec/odysseus/version_resolver_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::Git` from Task 1.
- Produces: `Odysseus::DeployVersion` with readers `#version`, `#ref`, `#deployer`; and `Odysseus::VersionResolver.new(config_dir:, logger: nil)` with `#resolve(image_tag: nil)` → `DeployVersion`, raising `Odysseus::ConfigError`.
- `#resolve` must refuse when `Git#head_sha` returns nil rather than building a `DeployVersion` with an empty version. That happens in a repository with no commits, which reaches this point because the dirty check passes: uncommitted files are untracked there, and untracked files only warn.

- [ ] **Step 1: Write the failing test**

Create `odysseus-core/spec/odysseus/version_resolver_spec.rb`:

```ruby
# spec/odysseus/version_resolver_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::VersionResolver do
  let(:git) { instance_double(Odysseus::Git) }
  let(:warnings) { [] }
  let(:logger) do
    collected = warnings
    Object.new.tap do |l|
      l.define_singleton_method(:info) { |_msg| nil }
      l.define_singleton_method(:warn) { |msg| collected << msg }
    end
  end

  subject(:resolver) { described_class.new(config_dir: '/app', logger: logger) }

  before { allow(Odysseus::Git).to receive(:new).with('/app').and_return(git) }

  context 'with an explicit image tag' do
    it 'uses it without consulting git' do
      expect(Odysseus::Git).not_to receive(:new)

      resolved = resolver.resolve(image_tag: 'v1.2.3')

      expect(resolved.version).to eq('v1.2.3')
    end

    it 'still reports no ref or deployer' do
      resolved = resolver.resolve(image_tag: 'v1.2.3')

      expect(resolved.ref).to be_nil
      expect(resolved.deployer).to be_nil
    end
  end

  context 'in a clean repository' do
    before do
      allow(git).to receive(:repository?).and_return(true)
      allow(git).to receive(:uncommitted_changes?).and_return(false)
      allow(git).to receive(:untracked_files?).and_return(false)
      allow(git).to receive(:head_sha).and_return('abc123def456')
      allow(git).to receive(:ref).and_return('main')
      allow(git).to receive(:committer_email).and_return('dev@example.com')
    end

    it 'resolves the version from HEAD' do
      expect(resolver.resolve.version).to eq('abc123def456')
    end

    it 'carries the ref and the deployer' do
      resolved = resolver.resolve

      expect(resolved.ref).to eq('main')
      expect(resolved.deployer).to eq('dev@example.com')
    end

    it 'falls back to $USER when git has no committer email' do
      allow(git).to receive(:committer_email).and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('USER', 'unknown').and_return('thomas')

      expect(resolver.resolve.deployer).to eq('thomas')
    end

    it 'warns about untracked files without aborting' do
      allow(git).to receive(:untracked_files?).and_return(true)

      expect(resolver.resolve.version).to eq('abc123def456')
      expect(warnings.join).to match(/untracked/i)
    end
  end

  context 'in a dirty repository' do
    before do
      allow(git).to receive(:repository?).and_return(true)
      allow(git).to receive(:uncommitted_changes?).and_return(true)
    end

    it 'refuses to resolve a version' do
      expect { resolver.resolve }
        .to raise_error(Odysseus::ConfigError, /uncommitted changes/i)
    end

    it 'names --image as the way through' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError, /--image/)
    end

    it 'still honours an explicit tag' do
      expect(resolver.resolve(image_tag: 'hotfix').version).to eq('hotfix')
    end
  end

  context 'in a repository with no commits' do
    before do
      allow(git).to receive(:repository?).and_return(true)
      allow(git).to receive(:uncommitted_changes?).and_return(false)
      allow(git).to receive(:head_sha).and_return(nil)
    end

    it 'refuses rather than building an empty version' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError, /no commits yet/i)
    end

    it 'names --image as the way through' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError, /--image/)
    end
  end

  context 'outside a repository' do
    before { allow(git).to receive(:repository?).and_return(false) }

    it 'refuses, naming the directory and --image' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError) { |error|
        expect(error.message).to include('/app')
        expect(error.message).to include('--image')
      }
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/version_resolver_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant Odysseus::VersionResolver`.

- [ ] **Step 3: Write minimal implementation**

Create `odysseus-core/lib/odysseus/deploy_version.rb`:

```ruby
# lib/odysseus/deploy_version.rb

module Odysseus
  # The identity of one deploy: the image tag, plus where it came from.
  # ref and deployer are nil when the version was given explicitly, because an
  # arbitrary tag says nothing about a commit.
  DeployVersion = Data.define(:version, :ref, :deployer)
end
```

Create `odysseus-core/lib/odysseus/version_resolver.rb`:

```ruby
# lib/odysseus/version_resolver.rb

module Odysseus
  # Turns an optional --image tag plus the state of the work tree into the
  # version a deploy will use. The rules live here rather than in Executor so
  # they can be tested without a config file or an SSH connection.
  class VersionResolver
    SHA_LENGTH = 12

    # @param config_dir [String] directory holding deploy.yml
    # @param logger [Object, nil] responds to #info and #warn
    def initialize(config_dir:, logger: nil)
      @config_dir = config_dir
      @logger = logger
    end

    # @param image_tag [String, nil] explicit tag; wins over git when given
    # @return [DeployVersion]
    # @raise [Odysseus::ConfigError] when no version can be established
    def resolve(image_tag: nil)
      return DeployVersion.new(version: image_tag, ref: nil, deployer: nil) if image_tag

      unless git.repository?
        raise Odysseus::ConfigError,
              "#{@config_dir} is not a git repository, so the version cannot be taken from a " \
              'commit. Pass --image to name the version explicitly.'
      end

      if git.uncommitted_changes?
        raise Odysseus::ConfigError,
              'The working tree has uncommitted changes, so the image tag would not identify ' \
              'the code being deployed. Commit them, or pass --image to name the version.'
      end

      sha = git.head_sha(length: SHA_LENGTH)

      unless sha
        raise Odysseus::ConfigError,
              "#{@config_dir} is a git repository with no commits yet, so there is no version to " \
              'deploy. Commit first, or pass --image to name the version.'
      end

      warn_about_untracked_files

      DeployVersion.new(version: sha, ref: git.ref, deployer: deployer)
    end

    private

    def git
      @git ||= Odysseus::Git.new(@config_dir)
    end

    def deployer
      git.committer_email || ENV.fetch('USER', 'unknown')
    end

    # The build context includes untracked files unless .dockerignore excludes
    # them, so they can change the image while the tag stays the same. Worth
    # saying out loud; not worth refusing over.
    def warn_about_untracked_files
      return unless git.untracked_files?
      return unless @logger.respond_to?(:warn)

      @logger.warn('Working tree has untracked files; they may enter the image without changing its tag')
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/version_resolver_spec.rb
```

Expected: PASS, 13 examples.

- [ ] **Step 5: Verify the specs have teeth**

Apply each mutation, run the spec, confirm a failure, then `git checkout -- lib/odysseus/version_resolver.rb`:

1. Delete the `git.uncommitted_changes?` guard → the two dirty-repository examples must fail.
2. Delete the `git.repository?` guard → the outside-a-repository example must fail.
3. Change `warn_about_untracked_files` to return early always → the untracked warning example must fail.
4. Delete the nil-sha guard → the two no-commits examples must fail.

- [ ] **Step 6: Run the full suite and linter**

```bash
cd odysseus-core && bundle exec rake
```

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/deploy_version.rb \
        odysseus-core/lib/odysseus/version_resolver.rb \
        odysseus-core/spec/odysseus/version_resolver_spec.rb
git commit -m "Resolve the deploy version from the git work tree"
```

---

### Task 3: Quote label values

**Files:**
- Modify: `odysseus-core/lib/odysseus/docker/client.rb` — the label lines in `build_run_command`
- Test: `odysseus-core/spec/odysseus/docker/client_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature change. `run(name:, image:, options: { labels: { 'k' => 'v' } })` now emits shell-safe `--label` arguments.

Labels are about to carry timestamps and refs, and `--label #{key}=#{value}` is unquoted today — the same class of bug as the env vars fixed in 0.4.0.

- [ ] **Step 1: Write the failing test**

Add `require 'shellwords'` below `require 'spec_helper'` at the top of
`odysseus-core/spec/odysseus/docker/client_spec.rb`, then add this to the `#run` describe block:

```ruby
    context 'with custom labels' do
      # Assert what docker actually receives, by parsing the command the way a
      # shell would. Escaping style is an implementation detail; a label arriving
      # as one argument is the requirement.
      def labels_in(cmd)
        tokens = Shellwords.split(cmd)
        tokens.each_cons(2).select { |flag, _| flag == '--label' }.map(&:last)
      end

      it 'passes a label value containing a space as a single argument' do
        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(labels_in(cmd)).to include('odysseus.git_ref=feature/a b')
          "#{container_id}\n"
        end

        client.run(
          name: 'test',
          image: 'myapp:latest',
          options: { labels: { 'odysseus.git_ref' => 'feature/a b' } }
        )
      end

      it 'leaves the service and version labels intact' do
        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(labels_in(cmd)).to include('odysseus.service=myapp', 'odysseus.version=abc123def456')
          "#{container_id}\n"
        end

        client.run(
          name: 'test',
          image: 'myapp:latest',
          options: { service: 'myapp', version: 'abc123def456' }
        )
      end
    end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb -e 'custom labels'
```

Expected: FAIL — the command contains `--label odysseus.git_ref=feature/a b` without quotes.

- [ ] **Step 3: Write minimal implementation**

In `odysseus-core/lib/odysseus/docker/client.rb`, add the require at the top of the file, next to `require 'json'`:

```ruby
require 'shellwords'
```

Replace the three label lines in `build_run_command`:

```ruby
        # Labels for tracking. Values are quoted: they carry refs and timestamps
        # supplied by the app's repository, not just internal identifiers.
        parts << "--label #{Shellwords.escape("odysseus.service=#{options[:service] || name}")}"
        parts << "--label #{Shellwords.escape("odysseus.version=#{options[:version]}")}" if options[:version]

        # Additional custom labels
        options[:labels]&.each do |key, value|
          parts << "--label #{Shellwords.escape("#{key}=#{value}")}"
        end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb
```

Expected: PASS. `Shellwords.escape` backslash-escapes rather than wrapping in quotes — it emits
`odysseus.git_ref=feature/a\ b`. That is why the examples parse the command with
`Shellwords.split` instead of matching quote characters: the requirement is that docker receives
one argument, not that a particular escaping style was used.

- [ ] **Step 5: Verify the specs have teeth**

Revert one `Shellwords.escape` call to bare interpolation, run the spec, confirm failure, then restore.

- [ ] **Step 6: Run the full suite and linter**

```bash
cd odysseus-core && bundle exec rake
```

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/docker/client.rb odysseus-core/spec/odysseus/docker/client_spec.rb
git commit -m "Quote docker label values"
```

---

### Task 4: Executor resolves the version once

**Files:**
- Modify: `odysseus-core/lib/odysseus/deployer/executor.rb`
- Test: `odysseus-core/spec/odysseus/deployer/executor_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::VersionResolver` and `Odysseus::DeployVersion` from Task 2.
- Produces: `Executor#deploy_version(image_tag = nil)` → `DeployVersion`, memoised per tag. `deploy_all`, `deploy_role`, `build`, `pussh`, `build_and_distribute`, `build_and_pussh` and `build_and_push_to_registry` all accept `image_tag: nil` and resolve when it is nil. The config hash passed to orchestrators gains `:deploy_version`.

- [ ] **Step 1: Write the failing test**

Add to `odysseus-core/spec/odysseus/deployer/executor_spec.rb`:

```ruby
  describe '#deploy_version' do
    let(:resolver) { instance_double(Odysseus::VersionResolver) }
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
    end

    before do
      allow(Odysseus::VersionResolver).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:resolve).and_return(resolved)
    end

    it 'resolves against the directory holding deploy.yml' do
      expect(Odysseus::VersionResolver)
        .to receive(:new).with(config_dir: File.dirname(fixture_file), logger: anything)
        .and_return(resolver)

      executor.deploy_version
    end

    it 'passes an explicit tag through to the resolver' do
      expect(resolver).to receive(:resolve).with(image_tag: 'v9').and_return(resolved)

      executor.deploy_version('v9')
    end

    it 'resolves only once for the same tag' do
      expect(resolver).to receive(:resolve).once.and_return(resolved)

      executor.deploy_version
      executor.deploy_version
    end

    it 'hands the resolved version to the orchestrator inside the config' do
      allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
      allow(mock_orchestrator).to receive(:deploy).and_return({ success: true })

      expect(Odysseus::Orchestrator::WebDeploy).to receive(:new).with(
        ssh: mock_ssh,
        config: hash_including(deploy_version: resolved),
        logger: anything,
        secrets_loader: anything
      ).and_return(mock_orchestrator)

      executor.deploy_role(host: 'test-server', image_tag: nil, role: :web)
    end

    it 'deploys the resolved version when no tag is given' do
      allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)

      expect(mock_orchestrator).to receive(:deploy)
        .with(image_tag: 'abc123def456', role: :web)
        .and_return({ success: true })

      executor.deploy_role(host: 'test-server', image_tag: nil, role: :web)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/deployer/executor_spec.rb -e '#deploy_version'
```

Expected: FAIL with `NoMethodError: undefined method 'deploy_version'`.

- [ ] **Step 3: Write minimal implementation**

In `odysseus-core/lib/odysseus/deployer/executor.rb`, add the public method after `initialize`:

```ruby
      # The identity of the deploy: version, ref and deployer.
      #
      # Resolved once per tag so a multi-role, multi-host deploy cannot end up
      # with two versions, and so the git commands run once rather than per host.
      #
      # @param image_tag [String, nil] explicit tag, or nil to resolve from git
      # @return [Odysseus::DeployVersion]
      def deploy_version(image_tag = nil)
        @deploy_versions ||= {}
        @deploy_versions[image_tag] ||= version_resolver.resolve(image_tag: image_tag)
      end
```

Add the private helpers:

```ruby
      def version_resolver
        @version_resolver ||= Odysseus::VersionResolver.new(config_dir: @config_dir, logger: build_logger)
      end

      # Sails are constructed with a fixed keyword set, so version metadata
      # travels in the config hash rather than as a new keyword argument.
      def orchestrator_config(resolved)
        @config.merge(deploy_version: resolved)
      end
```

Change `deploy_role` so it resolves and threads the result. Replace the existing method body's opening and the orchestrator construction:

```ruby
      def deploy_role(host:, image_tag: nil, dry_run: false, role:)
        resolved = deploy_version(image_tag)

        if dry_run
          puts "Dry run - would deploy #{@config[:image]}:#{resolved.version} to #{host}"
          puts "Service: #{@config[:service]}"
          puts "Role: #{role}"
          puts "Proxy hosts: #{@config[:proxy][:hosts].join(', ')}" if role == WEB_ROLE
          return { success: true, dry_run: true }
        end

        ssh = connect_to_server(host)

        begin
          orchestrator = build_orchestrator(ssh, role, resolved)
          orchestrator.deploy(image_tag: resolved.version, role: role)
        ensure
          ssh.close
        end
      end
```

Change `build_orchestrator` to take the resolved version and use `orchestrator_config`:

```ruby
      def build_orchestrator(ssh, role, resolved)
        logger = build_logger
        role_config = @config[:servers][role] || {}
        strategy = role_config.dig(:deploy, :strategy)
        config = orchestrator_config(resolved)

        if strategy && Odysseus::Sails.registered?(strategy)
          Odysseus::Sails.resolve(strategy).new(
            ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader
          )
        elsif role == WEB_ROLE
          Odysseus::Orchestrator::WebDeploy.new(
            ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader
          )
        else
          Odysseus::Orchestrator::JobDeploy.new(
            ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader
          )
        end
      end
```

Then make the remaining entry points default to nil and resolve. Change these signatures and their internal uses of `image_tag`:

```ruby
      def build(image_tag: nil, push: false, context_path: nil)
        resolved = deploy_version(image_tag)
        context = context_path || resolve_build_context
        full_image = "#{@config[:image]}:#{resolved.version}"
        # ... rest unchanged
      end

      def pussh(image_tag: nil)
        resolved = deploy_version(image_tag)
        full_image = "#{@config[:image]}:#{resolved.version}"
        # ... rest unchanged
      end

      def deploy_all(image_tag: nil, dry_run: false)
        # body unchanged; it already delegates to deploy_role
      end

      def build_and_deploy(image_tag: nil, context_path: nil, dry_run: false)
      def build_and_pussh(image_tag: nil, context_path: nil)
      def build_and_distribute(image_tag: nil, context_path: nil)
      def build_and_push_to_registry(image_tag: nil, context_path: nil)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/deployer/executor_spec.rb
```

Expected: PASS. Existing examples that pass `image_tag: 'v1.0'` keep working, because an explicit tag bypasses git.

- [ ] **Step 5: Verify the specs have teeth**

1. Make `deploy_version` call `resolve` every time (drop the `||=`) → the resolves-only-once example must fail.
2. Pass `@config` instead of `orchestrator_config(resolved)` in `build_orchestrator` → the config-carries-the-version example must fail.

- [ ] **Step 6: Run the full suite and linter**

```bash
cd odysseus-core && bundle exec rake
```

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/deployer/executor.rb odysseus-core/spec/odysseus/deployer/executor_spec.rb
git commit -m "Resolve the deploy version once per Executor"
```

---

### Task 5: Version in container names and labels

**Files:**
- Modify: `odysseus-core/lib/odysseus/orchestrator/web_deploy.rb` — `start_new_container`
- Modify: `odysseus-core/lib/odysseus/orchestrator/job_deploy.rb` — `start_new_container`
- Test: `odysseus-core/spec/odysseus/orchestrator/web_deploy_spec.rb`
- Test: `odysseus-core/spec/odysseus/orchestrator/job_deploy_spec.rb`

**Interfaces:**
- Consumes: `config[:deploy_version]` from Task 4; quoted labels from Task 3.
- Produces: containers named `<service>-<version>-<timestamp>` carrying `odysseus.version`, `odysseus.deployed_at` and `odysseus.git_ref`.

- [ ] **Step 1: Write the failing test**

Add to `odysseus-core/spec/odysseus/orchestrator/web_deploy_spec.rb` inside the `#deploy` describe:

```ruby
    context 'with a resolved deploy version' do
      let(:config) do
        super().merge(
          deploy_version: Odysseus::DeployVersion.new(
            version: 'abc123def456', ref: 'main', deployer: 'dev@example.com'
          )
        )
      end

      it 'names the container after the version' do
        expect(mock_docker).to receive(:run) do |args|
          expect(args[:name]).to start_with('myapp-abc123def456-')
          'new-container-123'
        end

        orchestrator.deploy(image_tag: 'abc123def456')
      end

      it 'labels the container with the version, not the timestamp' do
        expect(mock_docker).to receive(:run) do |args|
          expect(args[:options][:version]).to eq('abc123def456')
          'new-container-123'
        end

        orchestrator.deploy(image_tag: 'abc123def456')
      end

      it 'labels the container with the ref and the deploy time' do
        expect(mock_docker).to receive(:run) do |args|
          labels = args[:options][:labels]
          expect(labels['odysseus.git_ref']).to eq('main')
          expect(labels['odysseus.deployed_at']).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
          'new-container-123'
        end

        orchestrator.deploy(image_tag: 'abc123def456')
      end
    end

    context 'without a resolved deploy version' do
      it 'falls back to the image tag for the name and version label' do
        expect(mock_docker).to receive(:run) do |args|
          expect(args[:name]).to start_with('myapp-v1.0-')
          expect(args[:options][:version]).to eq('v1.0')
          expect(args[:options][:labels]).not_to have_key('odysseus.git_ref')
          'new-container-123'
        end

        orchestrator.deploy(image_tag: 'v1.0')
      end
    end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/web_deploy_spec.rb -e 'deploy version'
```

Expected: FAIL — the name is `myapp-<timestamp>` and `options[:version]` is the timestamp.

- [ ] **Step 3: Write minimal implementation**

In `web_deploy.rb`, replace the opening of `start_new_container`:

```ruby
      def start_new_container(image:, role:)
        service = @config[:service]
        timestamp = Time.now.utc.strftime('%Y%m%d%H%M%S')
        container_name = "#{service}-#{deploy_version_tag(image)}-#{timestamp}"
```

and its `@docker.run` options, changing `version:` and adding `labels:`:

```ruby
            service: service,
            version: deploy_version_tag(image),
            labels: version_labels,
```

Add these private helpers to `web_deploy.rb`:

```ruby
      # The version this deploy identifies. Falls back to the tag in the image
      # reference so a caller passing --image still gets a self-describing name.
      def deploy_version_tag(image)
        resolved = @config[:deploy_version]
        return resolved.version if resolved

        image.to_s.split(':').last
      end

      # deployed_at replaces the timestamp that odysseus.version used to hold;
      # git_ref is only known when the version came from a commit.
      def version_labels
        labels = { 'odysseus.deployed_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
        resolved = @config[:deploy_version]
        labels['odysseus.git_ref'] = resolved.ref if resolved&.ref
        labels
      end
```

Apply the same three changes to `job_deploy.rb`, where the name is built from `role_name` rather than `service`:

```ruby
        container_name = "#{role_name}-#{deploy_version_tag(image)}-#{timestamp}"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/
```

Expected: PASS.

- [ ] **Step 5: Add the matching job_deploy examples**

Add to `odysseus-core/spec/odysseus/orchestrator/job_deploy_spec.rb`:

```ruby
    context 'with a resolved deploy version' do
      let(:config) do
        super().merge(
          deploy_version: Odysseus::DeployVersion.new(
            version: 'abc123def456', ref: 'main', deployer: 'dev@example.com'
          )
        )
      end

      it 'names the container after the role and the version' do
        expect(mock_docker).to receive(:run) do |args|
          expect(args[:name]).to start_with('myapp-jobs-abc123def456-')
          expect(args[:options][:version]).to eq('abc123def456')
          'new-container-123'
        end

        orchestrator.deploy(image_tag: 'abc123def456', role: :jobs)
      end
    end
```

The existing fixture in that file uses `service: 'myapp'`, `image: 'myapp/image'` and a single
`jobs` role, so the container name is `myapp-jobs-<version>-<timestamp>` and the service label is
`myapp-jobs`. Run:

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/job_deploy_spec.rb
```

- [ ] **Step 6: Verify the specs have teeth**

1. Make `deploy_version_tag` always return the image tag → the version-label examples must fail.
2. Drop `odysseus.git_ref` from `version_labels` → the ref example must fail.

- [ ] **Step 7: Run the full suite and linter**

```bash
cd odysseus-core && bundle exec rake
```

- [ ] **Step 8: Commit**

```bash
git add odysseus-core/lib/odysseus/orchestrator/ odysseus-core/spec/odysseus/orchestrator/
git commit -m "Name and label containers by deploy version"
```

---

### Task 6: Read labels back, and show them in status

**Files:**
- Create: `odysseus-core/lib/odysseus/docker/labels.rb`
- Test: `odysseus-core/spec/odysseus/docker/labels_spec.rb`
- Modify: `odysseus-cli/lib/odysseus/cli/cli.rb` — the `Web` section of `status`
- Test: `odysseus-cli/spec/odysseus/cli/cli_spec.rb`

**Interfaces:**
- Consumes: labels written in Task 5.
- Produces: `Odysseus::Docker::Labels.parse(string)` → `Hash`, and `Odysseus::Docker::Labels.version_of(container_hash)` → String or nil.

- [ ] **Step 1: Write the failing test**

Create `odysseus-core/spec/odysseus/docker/labels_spec.rb`:

```ruby
# spec/odysseus/docker/labels_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Docker::Labels do
  describe '.parse' do
    it 'parses the comma separated pairs docker ps emits' do
      parsed = described_class.parse('odysseus.service=myapp,odysseus.version=abc123def456')

      expect(parsed).to eq(
        'odysseus.service' => 'myapp',
        'odysseus.version' => 'abc123def456'
      )
    end

    it 'keeps a value containing an equals sign intact' do
      parsed = described_class.parse('odysseus.git_ref=feature=x')

      expect(parsed['odysseus.git_ref']).to eq('feature=x')
    end

    it 'returns an empty hash for nil or empty input' do
      expect(described_class.parse(nil)).to eq({})
      expect(described_class.parse('')).to eq({})
    end
  end

  describe '.version_of' do
    it 'reads the version label from a docker ps entry' do
      container = { 'Labels' => 'odysseus.service=myapp,odysseus.version=abc123def456' }

      expect(described_class.version_of(container)).to eq('abc123def456')
    end

    it 'is nil when the container carries no version label' do
      expect(described_class.version_of({ 'Labels' => 'foo=bar' })).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/docker/labels_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant Odysseus::Docker::Labels`.

- [ ] **Step 3: Write minimal implementation**

Create `odysseus-core/lib/odysseus/docker/labels.rb`:

```ruby
# lib/odysseus/docker/labels.rb

module Odysseus
  module Docker
    # docker ps --format '{{json .}}' reports labels as one flat string:
    # "k=v,k2=v2". This turns that back into a hash.
    module Labels
      VERSION_KEY = 'odysseus.version'.freeze

      # @param raw [String, nil] the Labels field of a docker ps entry
      # @return [Hash{String => String}]
      def self.parse(raw)
        return {} if raw.nil? || raw.empty?

        raw.split(',').each_with_object({}) do |pair, acc|
          key, value = pair.split('=', 2)
          acc[key] = value.to_s unless key.nil? || key.empty?
        end
      end

      # @param container [Hash] a docker ps entry
      # @return [String, nil] the deployed version, when labelled
      def self.version_of(container)
        parse(container['Labels'])[VERSION_KEY]
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/docker/labels_spec.rb
```

Expected: PASS, 5 examples.

- [ ] **Step 5: Show the version in `status`**

Add to `odysseus-cli/spec/odysseus/cli/cli_spec.rb`:

```ruby
  describe '#status' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }
    let(:caddy) { instance_double(Odysseus::Caddy::Client) }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
      allow(Odysseus::Caddy::Client).to receive(:new).and_return(caddy)
      allow(caddy).to receive(:status).and_return(running: false, services: [], tls: { enabled: false })
      allow(docker).to receive(:list).and_return([])
      allow(docker).to receive(:list).with(service: 'myapp').and_return(
        [{
          'ID' => 'abc123abc123',
          'Names' => 'myapp-abc123def456-20260812112759',
          'State' => 'running',
          'Status' => 'Up 8 minutes (healthy)',
          'Image' => 'myapp-production:abc123def456',
          'Labels' => 'odysseus.service=myapp,odysseus.version=abc123def456,' \
                      'odysseus.deployed_at=2026-08-12T11:27:59Z,odysseus.git_ref=main'
        }]
      )
    end

    it 'reports the version, ref and deploy time of the running container' do
      out = output_of { cli.status('web1.example.com', config: config_file) }

      expect(out).to include('abc123def456')
      expect(out).to include('main')
      expect(out).to include('2026-08-12T11:27:59Z')
    end
  end
```

Run it and watch it fail: `cd odysseus-cli && bundle exec rspec spec/odysseus/cli/cli_spec.rb -e 'reports the version'`. Expected: FAIL, the output has the image name but no version.

Then in `odysseus-cli/lib/odysseus/cli/cli.rb`, in `status`, replace the web container rows:

```ruby
            rows = web_containers.map do |c|
              labels = Odysseus::Docker::Labels.parse(c['Labels'])
              health = c['Status'].include?('healthy') ? '✓' : ''
              [
                labels['odysseus.version'] || '(unlabelled)',
                labels['odysseus.git_ref'] || '-',
                labels['odysseus.deployed_at'] || '-',
                c['State'],
                health
              ]
            end
            @ui.table(headers: ['Version', 'Ref', 'Deployed', 'State', 'Health'], rows: rows)
```

Run again. Expected: PASS.

- [ ] **Step 6: Verify the specs have teeth**

1. Change `parse` to split on `=` without the limit of 2 → the equals-in-value example must fail.
2. Revert the `status` rows to show `c['Image']` → the status example must fail.

- [ ] **Step 7: Run both suites and linters**

```bash
cd odysseus-core && bundle exec rake && cd ../odysseus-cli && bundle exec rake
```

- [ ] **Step 8: Commit**

```bash
git add odysseus-core/lib/odysseus/docker/labels.rb \
        odysseus-core/spec/odysseus/docker/labels_spec.rb \
        odysseus-cli/lib/odysseus/cli/cli.rb \
        odysseus-cli/spec/odysseus/cli/cli_spec.rb
git commit -m "Report the deployed version in status"
```

---

### Task 7: CLI stops defaulting to latest

**Files:**
- Modify: `odysseus-cli/lib/odysseus/cli/cli.rb` — `deploy`, `build`, `pussh`, `app_exec`, `app_shell`, `app_console`
- Test: `odysseus-cli/spec/odysseus/cli/cli_spec.rb`

**Interfaces:**
- Consumes: `Executor#deploy_version` from Task 4; `Docker::Labels.version_of` from Task 6.
- Produces: no new public API. `deploy`, `build` and `pussh` pass `options[:image]` through unchanged, including nil. The `app` commands run the version that is serving.

- [ ] **Step 1: Write the failing test**

Add to `odysseus-cli/spec/odysseus/cli/cli_spec.rb`:

```ruby
  describe 'version handling' do
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
    end

    before { allow(executor).to receive(:deploy_version).and_return(resolved) }

    it 'lets the executor resolve the version when --image is absent' do
      expect(executor).to receive(:deploy_all).with(image_tag: nil, dry_run: false)

      output_of { cli.deploy(config: config_file) }
    end

    it 'passes --image through when given' do
      expect(executor).to receive(:deploy_all).with(image_tag: 'v9', dry_run: false)

      output_of { cli.deploy(config: config_file, image: 'v9') }
    end

    it 'shows the resolved version in the deploy header' do
      allow(executor).to receive(:deploy_all)

      expect(output_of { cli.deploy(config: config_file) }).to include('abc123def456')
    end

    it 'reports a dirty tree without deploying' do
      allow(executor).to receive(:deploy_version)
        .and_raise(Odysseus::ConfigError, 'The working tree has uncommitted changes')
      expect(executor).not_to receive(:deploy_all)

      expect { output_of { cli.deploy(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('uncommitted changes')
    end
  end

  describe '#app_exec' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
    end

    it 'runs the version that is currently serving' do
      allow(docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.version=abc123def456' }]
      )

      expect(docker).to receive(:run_once)
        .with(image: 'myapp-production:abc123def456', command: 'true', options: anything)
        .and_return('done')

      output_of { cli.app_exec('web1.example.com', config: config_file, command: 'true') }
    end

    it 'exits non-zero when nothing is running for the service' do
      allow(docker).to receive(:list).with(service: 'myapp').and_return([])

      expect { output_of { cli.app_exec('web1.example.com', config: config_file, command: 'true') } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to match(/no running container/i)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-cli && bundle exec rspec spec/odysseus/cli/cli_spec.rb -e 'version handling'
```

Expected: FAIL — `deploy_all` receives `image_tag: 'latest'`.

- [ ] **Step 3: Write minimal implementation**

In `odysseus-cli/lib/odysseus/cli/cli.rb`, in `deploy`, replace the tag default and header:

```ruby
        config_file = options[:config] || 'deploy.yml'
        image_tag = options[:image]
        should_build = options[:build] || false
        dry_run = options[:'dry-run'] || false
        verbose = options[:verbose] || @ui.debug?

        config = load_config(config_file)
        uses_registry = config[:registry] && config[:registry][:server]

        executor = Odysseus::Deployer::Executor.new(config_file, verbose: verbose)
        resolved = executor.deploy_version(image_tag)

        distribution = uses_registry ? "registry (#{config[:registry][:server]})" : 'pussh (SSH)'
        @ui.deploy_header(
          service: config[:service],
          image: config[:image],
          image_tag: resolved.version,
          build: should_build,
          distribution: distribution
        )
```

and pass the raw option onward, so the executor's memoised resolution is reused:

```ruby
        @ui.stream_steps(title: 'Deploying service') do
          executor.deploy_all(image_tag: image_tag, dry_run: dry_run)
        end
```

Apply the same change in `build` and `pussh`: `image_tag = options[:image]`, then display `executor.deploy_version(image_tag).version`.

Replace the image reference in `app_exec`, `app_shell` and `app_console` with a lookup. Add this private helper:

```ruby
      # The image reference that is actually serving, so a one-off container runs
      # the same code as the deployed one.
      def running_image(server, config)
        ssh = connect_to_server(server)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          container = docker.list(service: config[:service]).first

          unless container
            @ui.error "No running container for #{config[:service]} on #{server}"
            exit 1
          end

          version = Odysseus::Docker::Labels.version_of(container)

          unless version
            @ui.error "The running container for #{config[:service]} carries no version label"
            exit 1
          end

          "#{config[:image]}:#{version}"
        ensure
          ssh.close
        end
      end
```

In `app_exec`, replace `image = "#{config[:image]}:latest"` with `image = running_image(server, config)`. Do the same in `app_shell` and `app_console`.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-cli && bundle exec rspec
```

Expected: PASS. `app_exec` opens a second SSH connection for the lookup; the doubles return the same instance, which is fine.

- [ ] **Step 5: Verify the specs have teeth**

1. Restore `image_tag = options[:image] || 'latest'` in `deploy` → the resolve-when-absent example must fail.
2. Make `running_image` return `"#{config[:image]}:latest"` → the app_exec example must fail.

- [ ] **Step 6: Run both suites and linters**

```bash
cd odysseus-core && bundle exec rake && cd ../odysseus-cli && bundle exec rake
```

- [ ] **Step 7: Commit**

```bash
git add odysseus-cli/lib/odysseus/cli/cli.rb odysseus-cli/spec/odysseus/cli/cli_spec.rb
git commit -m "Take the deploy version from git instead of defaulting to latest"
```

---

### Task 8: Host deploy log

**Files:**
- Create: `odysseus-core/lib/odysseus/deploy_log.rb`
- Test: `odysseus-core/spec/odysseus/deploy_log_spec.rb`

**Interfaces:**
- Consumes: `Deployer::SSH#execute`.
- Produces: `Odysseus::DeployLog.new(ssh:, service:)` with `#append(version:, role:, ref:, deployer:, kind: 'deployed', from: nil)`, `#entries` → `Array<DeployLog::Entry>`, and `DeployLog::Entry` with readers `#at`, `#version`, `#role`, `#ref`, `#deployer`, `#kind`, `#from`. `DeployLog::PATH_ROOT` is `/var/lib/odysseus`.

- [ ] **Step 1: Write the failing test**

Create `odysseus-core/spec/odysseus/deploy_log_spec.rb`:

```ruby
# spec/odysseus/deploy_log_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::DeployLog do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:log) { described_class.new(ssh: mock_ssh, service: 'myapp') }
  let(:path) { '/var/lib/odysseus/myapp/deploys.log' }

  describe '#append' do
    it 'creates the directory and appends one line' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd| commands << cmd; '' }

      log.append(version: 'abc123def456', role: :web, ref: 'main', deployer: 'dev@example.com')

      expect(commands.first).to include('mkdir -p /var/lib/odysseus/myapp')
      expect(commands.last).to include(">> #{path}")
      expect(commands.last).to include('abc123def456')
      expect(commands.last).to include('web')
      expect(commands.last).to include('deployed')
    end

    it 'records a rollback with the version it came from' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd| commands << cmd; '' }

      log.append(
        version: '9f8e7d6c5b4a', role: :web, ref: 'main', deployer: 'dev@example.com',
        kind: 'rolled-back', from: 'abc123def456'
      )

      expect(commands.last).to include('rolled-back')
      expect(commands.last).to include('from=abc123def456')
    end

    it 'escapes values so a hostile ref cannot inject a command' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd| commands << cmd; '' }

      log.append(version: 'abc', role: :web, ref: 'main; rm -rf /', deployer: 'dev@example.com')

      expect(commands.last).not_to include('; rm -rf /')
      expect(commands.last).to include('rm -rf')
    end

    it 'uses a timestamp in the format the log defines' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd| commands << cmd; '' }

      log.append(version: 'abc', role: :web, ref: 'main', deployer: 'dev@example.com')

      expect(commands.last).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    end
  end

  describe '#entries' do
    it 'parses the log newest last' do
      allow(mock_ssh).to receive(:execute).and_return(
        "2026-08-12T11:27:59Z abc123def456 web main dev@example.com deployed\n" \
        "2026-08-12T14:02:11Z 9f8e7d6c5b4a web main dev@example.com rolled-back from=abc123def456\n"
      )

      entries = log.entries

      expect(entries.map(&:version)).to eq(%w[abc123def456 9f8e7d6c5b4a])
      expect(entries.last.kind).to eq('rolled-back')
      expect(entries.last.from).to eq('abc123def456')
      expect(entries.first.role).to eq('web')
      expect(entries.first.deployer).to eq('dev@example.com')
    end

    it 'is empty when the log does not exist' do
      allow(mock_ssh).to receive(:execute).and_return('')

      expect(log.entries).to eq([])
    end

    it 'skips lines it cannot parse rather than raising' do
      allow(mock_ssh).to receive(:execute).and_return("garbage\n2026-08-12T11:27:59Z abc web main d deployed\n")

      expect(log.entries.map(&:version)).to eq(['abc'])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/deploy_log_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant Odysseus::DeployLog`.

- [ ] **Step 3: Write minimal implementation**

Create `odysseus-core/lib/odysseus/deploy_log.rb`:

```ruby
# lib/odysseus/deploy_log.rb

require 'shellwords'

module Odysseus
  # Append-only record of what has been deployed to one host, keyed by service.
  #
  # This is the host's own account of its history: it orders versions reliably,
  # which image timestamps cannot, and it survives container removal and image
  # pruning. It is also the host-side audit trail.
  class DeployLog
    PATH_ROOT = '/var/lib/odysseus'.freeze
    FILENAME = 'deploys.log'.freeze
    TIME_FORMAT = '%Y-%m-%dT%H:%M:%SZ'.freeze

    Entry = Data.define(:at, :version, :role, :ref, :deployer, :kind, :from)

    # @param ssh [Odysseus::Deployer::SSH] connection to the host
    # @param service [String] the service: value from deploy.yml, never role-suffixed
    def initialize(ssh:, service:)
      @ssh = ssh
      @service = service
    end

    # @return [String] absolute path of this service's log on the host
    def path
      File.join(PATH_ROOT, @service, FILENAME)
    end

    # Record one deploy of one role.
    #
    # @param kind [String] 'deployed' or 'rolled-back'
    # @param from [String, nil] the version replaced, for a rollback
    def append(version:, role:, ref:, deployer:, kind: 'deployed', from: nil)
      fields = [Time.now.utc.strftime(TIME_FORMAT), version, role.to_s, ref || '-', deployer || '-', kind]
      fields << "from=#{from}" if from

      line = fields.map { |field| Shellwords.escape(field.to_s) }.join(' ')

      @ssh.execute("mkdir -p #{Shellwords.escape(File.dirname(path))}")
      @ssh.execute("printf '%s\\n' #{line} >> #{Shellwords.escape(path)}")
    end

    # @return [Array<Entry>] parsed entries, oldest first; empty when absent
    def entries
      raw = @ssh.execute("cat #{Shellwords.escape(path)} 2>/dev/null || true")

      raw.to_s.lines.filter_map { |line| parse_line(line) }
    end

    private

    def parse_line(line)
      at, version, role, ref, deployer, kind, extra = line.strip.split(/\s+/, 7)
      return nil if at.nil? || version.nil? || kind.nil?
      return nil unless at.match?(/\A\d{4}-\d{2}-\d{2}T/)

      Entry.new(
        at: at, version: version, role: role, ref: ref, deployer: deployer,
        kind: kind, from: extra&.slice(/\Afrom=(\S+)/, 1)
      )
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/deploy_log_spec.rb
```

Expected: PASS, 7 examples.

- [ ] **Step 5: Verify the specs have teeth**

1. Drop the `Shellwords.escape` from the field mapping → the hostile-ref example must fail.
2. Remove the timestamp format guard in `parse_line` → the unparseable-line example must fail.

- [ ] **Step 6: Run the full suite and linter**

```bash
cd odysseus-core && bundle exec rake
```

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/deploy_log.rb odysseus-core/spec/odysseus/deploy_log_spec.rb
git commit -m "Add the per-host deploy log"
```

---

### Task 9: Orchestrators record successful deploys

**Files:**
- Modify: `odysseus-core/lib/odysseus/orchestrator/web_deploy.rb` — end of `deploy`
- Modify: `odysseus-core/lib/odysseus/orchestrator/job_deploy.rb` — end of `deploy`
- Test: `odysseus-core/spec/odysseus/orchestrator/web_deploy_spec.rb`
- Test: `odysseus-core/spec/odysseus/orchestrator/job_deploy_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::DeployLog` from Task 8; `config[:deploy_version]` from Task 4.
- Produces: one log line per successful role deploy. A failed log write must not fail a deploy that worked.

- [ ] **Step 1: Write the failing test**

Add to `odysseus-core/spec/odysseus/orchestrator/web_deploy_spec.rb`, inside the `with a resolved deploy version` context created in Task 5:

```ruby
      let(:deploy_log) { instance_double(Odysseus::DeployLog) }

      before do
        allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
        allow(deploy_log).to receive(:append)
      end

      it 'records the deploy on the host' do
        expect(Odysseus::DeployLog).to receive(:new).with(ssh: mock_ssh, service: 'myapp')
                                                    .and_return(deploy_log)
        expect(deploy_log).to receive(:append).with(
          version: 'abc123def456', role: :web, ref: 'main', deployer: 'dev@example.com'
        )

        orchestrator.deploy(image_tag: 'abc123def456')
      end

      it 'does not record anything when the deploy fails' do
        allow(mock_docker).to receive(:wait_healthy).and_return(false)
        allow(mock_docker).to receive(:stop)
        allow(mock_docker).to receive(:remove)
        allow(mock_docker).to receive(:logs).and_return('')
        allow(mock_docker).to receive(:health_status).and_return('unhealthy')
        expect(deploy_log).not_to receive(:append)

        expect { orchestrator.deploy(image_tag: 'abc123def456') }
          .to raise_error(Odysseus::DeployError)
      end

      it 'still succeeds when the log cannot be written' do
        allow(deploy_log).to receive(:append).and_raise(Odysseus::SSHCommandError, 'read-only fs')

        expect(orchestrator.deploy(image_tag: 'abc123def456')).to include(success: true)
      end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/web_deploy_spec.rb -e 'records the deploy'
```

Expected: FAIL — `append` is never called.

- [ ] **Step 3: Write minimal implementation**

In `web_deploy.rb`, add the record step immediately before the success return in `deploy`, after the stale-upstream cleanup:

```ruby
        record_deploy(role)

        log "Deploy complete for #{service}"
```

Add the private method:

```ruby
      # The host's own record of what it is running. Best effort: a deploy that
      # reached this point has succeeded, and an unwritable log must not undo it.
      def record_deploy(role, kind: 'deployed', from: nil)
        resolved = @config[:deploy_version]
        return unless resolved

        Odysseus::DeployLog.new(ssh: @ssh, service: @config[:service]).append(
          version: resolved.version,
          role: role,
          ref: resolved.ref,
          deployer: resolved.deployer,
          kind: kind,
          from: from
        )
      rescue Odysseus::Error => e
        log "Could not record the deploy on this host: #{e.message}", :warn
      end
```

Add the same call and method to `job_deploy.rb`, before its `log "Deploy complete for #{role_name}"`. Note it uses `@config[:service]` for the log path, not `role_name`: the log is service-level.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/
```

Expected: PASS.

- [ ] **Step 5: Add the matching job_deploy example**

Put it in a context carrying the same setup — repeated here in full, because the file is read on
its own:

```ruby
    context 'with a resolved deploy version' do
      let(:config) do
        super().merge(
          deploy_version: Odysseus::DeployVersion.new(
            version: 'abc123def456', ref: 'main', deployer: 'dev@example.com'
          )
        )
      end
      let(:deploy_log) { instance_double(Odysseus::DeployLog) }

      before do
        allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
        allow(deploy_log).to receive(:append)
      end

      it 'records the deploy against the service, not the role name' do
        expect(Odysseus::DeployLog).to receive(:new).with(ssh: mock_ssh, service: 'myapp')
                                                    .and_return(deploy_log)
        expect(deploy_log).to receive(:append).with(hash_including(role: :jobs))

        orchestrator.deploy(image_tag: 'abc123def456', role: :jobs)
      end
    end
```

```bash
cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/job_deploy_spec.rb
```

- [ ] **Step 6: Verify the specs have teeth**

1. Move `record_deploy(role)` above the health check → the does-not-record-on-failure example must fail.
2. Remove the `rescue Odysseus::Error` → the still-succeeds example must fail.
3. Pass `role_name` as `service:` in `job_deploy.rb` → the records-against-the-service example must fail.

- [ ] **Step 7: Run the full suite and linter**

```bash
cd odysseus-core && bundle exec rake
```

- [ ] **Step 8: Update the changelogs and commit**

Add under `## [Unreleased]` in `odysseus-core/CHANGELOG.md`:

```markdown
### Added
- The image tag now defaults to the git commit being deployed, and containers
  carry `odysseus.version`, `odysseus.deployed_at` and `odysseus.git_ref` labels,
  so a running container can be traced to a commit. `odysseus.version` previously
  held the deploy timestamp, which `odysseus.deployed_at` now carries.
- Each host records successful deploys in `/var/lib/odysseus/<service>/deploys.log`.

### Changed
- `deploy` and `build` no longer default to the `latest` tag. Outside a git
  repository, or with uncommitted changes, they stop and ask for `--image`.
```

And in `odysseus-cli/CHANGELOG.md`:

```markdown
### Changed
- `status` reports the version, ref and deploy time of each container.
- `app exec`, `app shell` and `app console` run the version that is currently
  serving instead of `:latest`.
```

```bash
git add odysseus-core/lib/odysseus/orchestrator/ odysseus-core/spec/odysseus/orchestrator/ \
        odysseus-core/CHANGELOG.md odysseus-cli/CHANGELOG.md
git commit -m "Record successful deploys on the host"
```

---

## Done when

- `odysseus deploy` in a clean repo tags the image with the 12-character SHA, names the container `<service>-<sha>-<timestamp>`, and labels it with version, ref and deploy time.
- `odysseus deploy` with uncommitted changes, or outside a repository, refuses before contacting a host.
- `odysseus status <host>` shows which commit is serving.
- `odysseus app exec <host> --command …` runs the serving version.
- `/var/lib/odysseus/<service>/deploys.log` gains a line per role per successful deploy.
- `bundle exec rake` exits 0 in both gems.

## Not in this plan

Phases 3–5 of the spec, to be planned once the interfaces above exist: `rollback` with its fleet pre-flight, image retention and pruning, and the git notes record. `DeployLog#entries` is written and tested here because rollback needs it, and testing a reader without a writer is how format bugs survive.
