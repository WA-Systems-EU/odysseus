# `odysseus setup` — host preparation (phase 3a) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a stock Ubuntu LTS host that already has Docker into one odysseus can deploy to as a non-root user — creating that user, its docker-group membership, its authorized key, and its state directory — and prove it works before reporting success.

**Architecture:** A new `Odysseus::Setup::Escalation` wraps commands with `sudo -n` when the bootstrap identity is not root; `Odysseus::Setup::Preparer` runs a check-then-apply sequence over one connection and returns structured results, the same shape `HostVerifier` uses. The CLI renders them and decides the exit code. Nothing modifies root's or the bootstrap user's configuration — setup only ever *adds* access, so a failure leaves the host reachable exactly as it was.

**Tech Stack:** Ruby 3.2+ (developed on 4.0.6), Zeitwerk autoloading, RSpec with `verify_partial_doubles` and `config.warnings = true`, RuboCop.

**Spec:** `docs/specs/2026-08-16-user-model-and-setup.md`. Read *What `setup` is for, and what it is not*, *Three identities, two configured*, *What `setup` does* (steps 0, 1, 3, 4, 5, 6, 8), *How this gets tested*, and *What could go wrong*.

## Scope: this is one of three plans

The spec's `setup` is nine steps spanning package installation, user administration, key installation and a data migration. That is too much for one plan, so it is split into three, each independently shippable and testable:

- **3a — this plan.** Steps 0, 1, 3, 4, 5, 6, 8: the escalation probe, distro gate, user, group, keys, directories and self-test. On a host without Docker it **refuses**, naming what is missing.
- **3b — the Docker install** (spec step 2). The riskiest and most isolated step: apt repository keys, dpkg locks, half-configured state. Replaces 3a's refusal.
- **3c — the deploy-log migration** (spec step 7). Data movement whose failure mode is silent loss of rollback history.

All three merge together, per the spec's decision to ship the install with the rest. Planning them apart keeps each small enough to get right.

## Global Constraints

- Ruby `>= 3.2.0` (gemspec floor); developed against 4.0.6.
- **The bootstrap identity comes from `--as`, default `ubuntu`.** `setup` adds **no config keys**: it reads `ssh.user` (the user to create), `ssh.keys` (the keys to install) and `servers.*.hosts` (where to go) — all already in `deploy.yml`.
- **`sudo -n` prefixes root-needing commands only when `--as` is not root.** Minimal images often have no `sudo` at all, so a root bootstrap must not depend on it.
- **A sudo password prompt cannot be answered.** `Net::SSH.start` runs with `non_interactive: true` (`deployer/ssh.rb`), so a prompt hangs and then fails. The probe exists to turn that into one sentence.
- **Setup never modifies root's or the bootstrap user's configuration**, never deletes anything, and never touches the firewall, swap, `sshd_config` or unattended-upgrades. It only adds.
- **Every step is check-then-apply.** An interrupted run re-converges on the next run; a second run against a healthy host changes nothing and says so.
- **Refuse before creating anything if no public key can be found.** A created user with no way to log in is the worst outcome available.
- Supported distros: **Ubuntu 24.04 and 26.04**, named explicitly in code rather than computed, so a new LTS is a deliberate edit with a tested host behind it.
- Every spec verified against a deliberate mutation of the code under test (`CONTRIBUTING.md`). A spec that still passes when its code is broken is not a spec.
- **Do not edit `.rubocop_todo.yml`** in either gem.
- Both suites and RuboCop stay green. Baselines: odysseus-core **620 examples / 0 failures / 77 files clean**; odysseus-cli **171 / 0 / 14 files clean**.
- Branch `feat/setup`, from `trunk`. Do not merge.
- Commit messages explain *why*, matching `git log --oneline -12`. No "Generated with Claude Code" trailers, no Co-Authored-By lines.

## File Structure

| File | Responsibility |
| --- | --- |
| `odysseus-core/lib/odysseus/setup/escalation.rb` | **New.** Probes for passwordless sudo and wraps a command with `sudo -n` when the identity needs it. Knows nothing about what the commands do. |
| `odysseus-core/lib/odysseus/setup/public_key.rb` | **New.** Resolves a public key on the **local** machine: an explicit path, a `.pub` sibling, or derived from a private key. No SSH. |
| `odysseus-core/lib/odysseus/setup/preparer.rb` | **New.** The remote sequence: distro gate, docker presence, user, group, keys, directories, self-test. Returns `Result` values. |
| `odysseus-cli/lib/odysseus/cli/setup_commands.rb` | **New.** The `setup` verb: parses `--as`/`--key`, renders results, sets the exit code. Mirrors `doctor_commands.rb`. |
| `odysseus-cli/bin/odysseus` | **Modify.** Dispatch `setup`, parse `--as` and `--key`, document both in help. |

Zeitwerk maps `lib/odysseus/setup/escalation.rb` to `Odysseus::Setup::Escalation` — no `require` needed, and no `setup.rb` file is necessary for the namespace.

`Result` reuses the shape `HostVerifier` established, so the CLI renders both the same way. Define it once in `Preparer` as `Odysseus::Setup::Preparer::Result = Data.define(:step, :status, :detail)` with `status` in `:ok`, `:changed`, `:warn`, `:fail` — note `:changed` is new here and `HostVerifier` has no equivalent, because a diagnostic never changes anything and setup reporting "already correct" separately from "I fixed it" is most of its value on a re-run.

---

### Task 1: `Setup::Escalation`

**Files:**
- Create: `odysseus-core/lib/odysseus/setup/escalation.rb`
- Create: `odysseus-core/spec/odysseus/setup/escalation_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::Deployer::SSH#execute`.
- Produces: `Odysseus::Setup::Escalation.new(ssh:, as:)` with `#probe!` (raises `Odysseus::SetupError` when escalation is unavailable), `#run(command)` returning the command's output, and `#sudo?`. Tasks 3 and 4 use exactly these.

Also add `class SetupError < Error; end` to `odysseus-core/lib/odysseus/errors.rb`, beside the other error classes. Check the file's existing ordering and place it consistently.

- [ ] **Step 1: Write the failing spec**

Create `odysseus-core/spec/odysseus/setup/escalation_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Odysseus::Setup::Escalation do
  def ssh_double(answers: {})
    ssh = instance_double(Odysseus::Deployer::SSH)
    allow(ssh).to receive(:execute) do |cmd|
      pattern = answers.keys.find { |p| cmd.match?(p) }
      raise "spec did not anticipate: #{cmd}" unless pattern

      answers[pattern]
    end
    ssh
  end

  describe 'as root' do
    subject(:escalation) { described_class.new(ssh: ssh, as: 'root') }

    let(:ssh) { ssh_double(answers: { /whoami/ => "root\n" }) }

    it 'needs no sudo' do
      expect(escalation.sudo?).to be(false)
    end

    # Minimal images often have no sudo at all, so a root bootstrap must not
    # depend on it even to check.
    it 'probes without running sudo' do
      escalation.probe!

      expect(ssh).not_to have_received(:execute)
    end

    it 'runs a command unprefixed' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH)
      allow(ssh).to receive(:execute) { |cmd| commands << cmd; '' }

      described_class.new(ssh: ssh, as: 'root').run('apt-get update')

      expect(commands).to eq(['apt-get update'])
    end
  end

  describe 'as a sudo user' do
    subject(:escalation) { described_class.new(ssh: ssh, as: 'ubuntu') }

    let(:ssh) { ssh_double(answers: { /sudo -n true/ => "\n" }) }

    it 'needs sudo' do
      expect(escalation.sudo?).to be(true)
    end

    it 'probes with a non-interactive sudo' do
      escalation.probe!

      expect(ssh).to have_received(:execute).with(a_string_including('sudo -n true'))
    end

    it 'prefixes a command with a non-interactive sudo' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH)
      allow(ssh).to receive(:execute) { |cmd| commands << cmd; '' }

      described_class.new(ssh: ssh, as: 'ubuntu').run('apt-get update')

      expect(commands).to eq(['sudo -n apt-get update'])
    end

    # A password prompt cannot be answered: Net::SSH runs non_interactive, so
    # the prompt hangs and then fails. The probe turns that into one sentence.
    it 'refuses when passwordless sudo is unavailable, saying why' do
      ssh = ssh_double(answers: { /sudo -n true/ => nil })
      allow(ssh).to receive(:execute).and_raise(Odysseus::SSHCommandError, 'sudo: a password is required')

      expect { described_class.new(ssh: ssh, as: 'ubuntu').probe! }
        .to raise_error(Odysseus::SetupError, /passwordless sudo/i)
    end

    it 'names the identity that could not escalate' do
      ssh = instance_double(Odysseus::Deployer::SSH)
      allow(ssh).to receive(:execute).and_raise(Odysseus::SSHCommandError, 'sudo: command not found')

      expect { described_class.new(ssh: ssh, as: 'deploy').probe! }
        .to raise_error(Odysseus::SetupError, /deploy/)
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/escalation_spec.rb`
Expected: FAIL — `uninitialized constant Odysseus::Setup`.

- [ ] **Step 3: Add the error class**

In `odysseus-core/lib/odysseus/errors.rb`, add beside the existing classes:

```ruby
  class SetupError < Error; end
```

- [ ] **Step 4: Write `Escalation`**

Create `odysseus-core/lib/odysseus/setup/escalation.rb`:

```ruby
# lib/odysseus/setup/escalation.rb

module Odysseus
  module Setup
    # How `odysseus setup` gets root on the host it is preparing.
    #
    # The bootstrap identity is named by --as and defaults to `ubuntu`, so
    # needing sudo is the common path rather than the exception: Ubuntu's LTS
    # cloud images ship that user with passwordless sudo already configured.
    # A root bootstrap must not touch sudo at all — minimal images often do not
    # have it installed.
    #
    # The probe exists because a sudo password prompt cannot be answered:
    # Net::SSH runs with non_interactive: true, so a prompt hangs and then
    # fails with nothing useful said. Asking up front turns that into one
    # sentence before anything has been changed.
    class Escalation
      ROOT = 'root'.freeze

      # @param ssh [Odysseus::Deployer::SSH] connection as the bootstrap identity
      # @param as [String] that identity's username
      def initialize(ssh:, as:)
        @ssh = ssh
        @as = as
      end

      # @return [Boolean] whether commands need a sudo prefix
      def sudo?
        @as != ROOT
      end

      # @raise [Odysseus::SetupError] when escalation is not available
      def probe!
        return unless sudo?

        @ssh.execute('sudo -n true')
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "#{@as} cannot escalate with passwordless sudo, which odysseus setup requires: " \
              "#{e.message.lines.first.to_s.strip}. Odysseus cannot answer a password prompt. " \
              'Use --as root on a host where root can log in, or give this user NOPASSWD sudo.'
      end

      # @param command [String] a command that needs root
      # @return [String] its output
      def run(command)
        @ssh.execute(sudo? ? "sudo -n #{command}" : command)
      end
    end
  end
end
```

- [ ] **Step 5: Run the spec**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/escalation_spec.rb`
Expected: PASS, 8 examples.

- [ ] **Step 6: Verify the specs have teeth**

| Mutation | Must fail |
| --- | --- |
| `sudo?` returns `true` always | `needs no sudo`, `probes without running sudo`, `runs a command unprefixed` |
| `sudo?` returns `false` always | `needs sudo`, `probes with a non-interactive sudo`, `prefixes a command with a non-interactive sudo` |
| `probe!` drops its `return unless sudo?` | `probes without running sudo` |
| `run` never prefixes | `prefixes a command with a non-interactive sudo` |
| `run` always prefixes | `runs a command unprefixed` |
| the rescue drops `@as` from the message | `names the identity that could not escalate` |
| the rescue drops the phrase "passwordless sudo" | `refuses when passwordless sudo is unavailable, saying why` |

- [ ] **Step 7: Full suite and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: 628 examples, 0 failures; 79 files, no offenses (77 baseline plus the two new files).

- [ ] **Step 8: Commit**

```bash
git add odysseus-core/lib/odysseus/setup/escalation.rb \
        odysseus-core/lib/odysseus/errors.rb \
        odysseus-core/spec/odysseus/setup/escalation_spec.rb
git commit
```

The message should say why a root bootstrap must not run sudo even to probe, and why the probe exists at all — a password prompt cannot be answered, so it would hang.

---

### Task 2: `Setup::PublicKey` — finding a key locally

**Files:**
- Create: `odysseus-core/lib/odysseus/setup/public_key.rb`
- Create: `odysseus-core/spec/odysseus/setup/public_key_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks. Local filesystem and `ssh-keygen` only — **no SSH**.
- Produces: `Odysseus::Setup::PublicKey.resolve(keys:, explicit: [])` returning `Array<String>` of authorized_keys lines, raising `Odysseus::SetupError` when none can be found. Task 3 consumes exactly this.

This task is the one that prevents the worst outcome available: a created user with no way to log in. It runs entirely locally and before anything on the host is touched.

- [ ] **Step 1: Write the failing spec**

Create `odysseus-core/spec/odysseus/setup/public_key_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Odysseus::Setup::PublicKey do
  # A real keypair on disk, because the whole point of this class is reading
  # real files and shelling out to real ssh-keygen. Stubbing either would test
  # the stub.
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      system('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'test@example',
             '-f', File.join(dir, 'id_test'), out: File::NULL, err: File::NULL)
      example.run
    end
  end

  let(:private_key) { File.join(@dir, 'id_test') }
  let(:public_key)  { "#{private_key}.pub" }

  describe '.resolve' do
    it 'reads the .pub sibling of a private key' do
      lines = described_class.resolve(keys: [private_key])

      expect(lines.size).to eq(1)
      expect(lines.first).to start_with('ssh-ed25519 ')
    end

    it 'prefers an explicit path over the sibling' do
      other = File.join(@dir, 'explicit.pub')
      File.write(other, "ssh-ed25519 AAAAexplicit explicit@example\n")

      lines = described_class.resolve(keys: [private_key], explicit: [other])

      expect(lines).to eq(['ssh-ed25519 AAAAexplicit explicit@example'])
    end

    # Common on machines where keys were copied rather than generated.
    it 'derives the public half when only the private key exists' do
      File.delete(public_key)

      lines = described_class.resolve(keys: [private_key])

      expect(lines.size).to eq(1)
      expect(lines.first).to start_with('ssh-ed25519 ')
    end

    it 'refuses when it can find nothing, rather than returning empty' do
      expect { described_class.resolve(keys: [File.join(@dir, 'nonexistent')]) }
        .to raise_error(Odysseus::SetupError, /no public key/i)
    end

    it 'names the paths it looked at, so the reader can fix the config' do
      missing = File.join(@dir, 'nonexistent')

      expect { described_class.resolve(keys: [missing]) }
        .to raise_error(Odysseus::SetupError, /#{Regexp.escape(missing)}/)
    end

    it 'expands a leading tilde, as ssh.keys entries are written' do
      expect { described_class.resolve(keys: ['~/definitely-not-a-key-abc123']) }
        .to raise_error(Odysseus::SetupError, %r{#{Regexp.escape(Dir.home)}})
    end

    it 'returns one line per key, de-duplicated' do
      lines = described_class.resolve(keys: [private_key, private_key])

      expect(lines.size).to eq(1)
    end

    it 'strips trailing newlines, so a line can be appended safely' do
      lines = described_class.resolve(keys: [private_key])

      expect(lines.first).not_to end_with("\n")
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/public_key_spec.rb`
Expected: FAIL — `uninitialized constant Odysseus::Setup::PublicKey`.

- [ ] **Step 3: Write `PublicKey`**

Create `odysseus-core/lib/odysseus/setup/public_key.rb`:

```ruby
# lib/odysseus/setup/public_key.rb

require 'open3'
require 'shellwords'

module Odysseus
  module Setup
    # The public keys `odysseus setup` installs for the user it creates,
    # resolved entirely on THIS machine before the host is touched.
    #
    # Getting this wrong produces the worst outcome the command has: a created
    # user nobody can log in as. So it runs first, and it raises rather than
    # returning an empty list — there is no sensible way to continue.
    module PublicKey
      # @param keys [Array<String>] ssh.keys entries (private key paths)
      # @param explicit [Array<String>] paths given with --key, which win
      # @return [Array<String>] authorized_keys lines, newline-free
      # @raise [Odysseus::SetupError] when nothing can be resolved
      def self.resolve(keys:, explicit: [])
        looked_at = []

        lines = (explicit.any? ? explicit : Array(keys)).flat_map do |path|
          expanded = File.expand_path(path)
          looked_at << expanded
          from_path(expanded, explicit: explicit.any?)
        end.compact.uniq

        return lines if lines.any?

        raise Odysseus::SetupError,
              'Found no public key to install, so the user would be created with no way ' \
              "to log in. Looked at: #{looked_at.join(', ')}. Pass --key with a path to a " \
              'public key, or check ssh.keys in deploy.yml.'
      end

      # An explicit --key path is a public key itself; an ssh.keys entry is a
      # private key whose public half may sit beside it or may have to be
      # derived, which is common where keys were copied rather than generated.
      def self.from_path(path, explicit:)
        return read_line(path) if explicit
        return read_line("#{path}.pub") if File.file?("#{path}.pub")

        derive(path)
      end

      def self.read_line(path)
        return nil unless File.file?(path)

        line = File.read(path).strip
        line.empty? ? nil : line
      end

      # `ssh-keygen -y` prints the public half of a private key. It fails
      # loudly on an encrypted key, which is the right outcome: odysseus cannot
      # answer a passphrase prompt any more than it can answer sudo's.
      def self.derive(private_key_path)
        return nil unless File.file?(private_key_path)

        out, _err, status = Open3.capture3('ssh-keygen', '-y', '-f', private_key_path)
        return nil unless status.success?

        line = out.strip
        line.empty? ? nil : line
      end

      private_class_method :from_path, :read_line, :derive
    end
  end
end
```

- [ ] **Step 4: Run the spec**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/public_key_spec.rb`
Expected: PASS, 8 examples.

- [ ] **Step 5: Verify the specs have teeth**

| Mutation | Must fail |
| --- | --- |
| `resolve` returns `[]` instead of raising | `refuses when it can find nothing, rather than returning empty` |
| drop `looked_at` from the message | `names the paths it looked at, so the reader can fix the config` |
| drop `File.expand_path` | `expands a leading tilde, as ssh.keys entries are written` |
| drop `.uniq` | `returns one line per key, de-duplicated` |
| drop `.strip` in `read_line` | `strips trailing newlines, so a line can be appended safely` |
| `from_path` ignores `explicit` | `prefers an explicit path over the sibling` |
| `from_path` never calls `derive` | `derives the public half when only the private key exists` |

- [ ] **Step 6: Full suite and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: 636 examples, 0 failures; 81 files, no offenses.

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/setup/public_key.rb \
        odysseus-core/spec/odysseus/setup/public_key_spec.rb
git commit
```

The message should say why this raises rather than returning an empty list, and why it runs before the host is touched at all.

---

### Task 3: `Setup::Preparer` — the remote sequence

**Files:**
- Create: `odysseus-core/lib/odysseus/setup/preparer.rb`
- Create: `odysseus-core/spec/odysseus/setup/preparer_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::Setup::Escalation#probe!`, `#run(command)`, `#sudo?` (Task 1); `Odysseus::Setup::PublicKey.resolve(keys:, explicit:)` (Task 2); `Odysseus::Deployer::SSH#execute`; `Odysseus::HostPaths`.
- Produces: `Odysseus::Setup::Preparer.new(ssh:, config:, escalation:, keys:)` with `#prepare` returning `Array<Result>`, and `Result = Data.define(:step, :status, :detail)` with `status` in `:ok`, `:changed`, `:warn`, `:fail`. Task 4 renders exactly these.

`:changed` is what distinguishes setup's report from `doctor`'s: on a second run against a healthy host every step should be `:ok`, and on a first run most should be `:changed`. A reader learning which is which is most of the command's value.

This task deliberately does **not** install Docker — it checks for it and fails, naming what is missing. Plan 3b replaces that.

- [ ] **Step 1: Write the failing spec**

Create `odysseus-core/spec/odysseus/setup/preparer_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Odysseus::Setup::Preparer do
  # Commands are recorded so the specs can assert what was actually sent, and
  # an unanticipated command raises rather than silently answering ''. This
  # project has repeatedly shipped bugs where a doubled connection cheerfully
  # answered a command that could never work on a real host.
  def build(answers:, user: 'odysseus', as: 'ubuntu', keys: ['ssh-ed25519 AAAAtest test@example'])
    commands = []
    ssh = instance_double(Odysseus::Deployer::SSH, user: user)
    allow(ssh).to receive(:execute) do |cmd|
      commands << cmd
      next "/home/#{user}\n" if cmd == 'echo $HOME'

      pattern = answers.keys.find { |p| cmd.match?(p) }
      raise "spec did not anticipate: #{cmd}" unless pattern

      answers[pattern]
    end
    allow(ssh).to receive(:upload_string)

    escalation = Odysseus::Setup::Escalation.new(ssh: ssh, as: as)
    config = { service: 'myapp', ssh: { user: user } }
    preparer = described_class.new(ssh: ssh, config: config, escalation: escalation, keys: keys)

    [preparer, commands]
  end

  UBUNTU_2404 = "ID=ubuntu\nVERSION_ID=\"24.04\"\n"

  # A host that is already fully prepared: every step should report :ok, and
  # nothing should be changed.
  def healthy(user: 'odysseus')
    {
      /os-release/ => UBUNTU_2404,
      /sudo -n true/ => "\n",
      /docker info/ => "29.1.3\n",
      /id -u/ => "1000\n",
      /stat -c/ => "#{user} #{user}\n",
      /id -nG/ => "#{user} docker\n",
      /grep -qxF/ => "present\n",
      /test -d/ => "present\n"
    }
  end

  def result_for(results, step)
    results.find { |r| r.step == step } or raise "no result for #{step.inspect}"
  end

  describe 'a host that is already prepared' do
    it 'changes nothing and says so' do
      preparer, = build(answers: healthy)

      results = preparer.prepare

      expect(results.map(&:status).uniq).to eq([:ok])
    end

    it 'issues no command that would modify the host' do
      preparer, commands = build(answers: healthy)

      preparer.prepare

      expect(commands).to all(satisfy do |cmd|
        !cmd.match?(/\b(useradd|usermod|chown|chmod|mkdir|tee|install)\b/)
      end)
    end

    it 'reports one result per step, in a stable order' do
      preparer, = build(answers: healthy)

      expect(preparer.prepare.map(&:step))
        .to eq(%i[escalation distro docker user group keys state_dir self_test])
    end
  end

  describe 'the distro gate' do
    it 'refuses a distro it was not written for, naming it' do
      answers = healthy.merge(/os-release/ => "ID=debian\nVERSION_ID=\"12\"\n")
      preparer, commands = build(answers: answers)

      results = preparer.prepare
      result = result_for(results, :distro)

      expect(result.status).to eq(:fail)
      expect(result.detail).to include('debian')
      # Nothing after the gate should have run.
      expect(commands).to all(satisfy { |cmd| !cmd.match?(/useradd|usermod/) })
    end
  end

  describe 'docker' do
    # 3b replaces this with an install. Until then a missing daemon is a plain
    # refusal rather than a half-prepared host.
    it 'refuses when the daemon does not answer, naming what is missing' do
      answers = healthy.merge(/docker info/ => "command not found\n")
      preparer, = build(answers: answers)

      result = result_for(preparer.prepare, :docker)

      expect(result.status).to eq(:fail)
      expect(result.detail).to match(/docker/i)
    end
  end

  describe 'the user' do
    it 'creates one that does not exist, with a home and a locked password' do
      answers = healthy.merge(/id -u/ => nil)
      preparer, commands = build(answers: answers)
      # id -u fails for a missing user
      allow(preparer).to receive(:user_exists?).and_call_original

      results = preparer.prepare

      expect(result_for(results, :user).status).to eq(:changed)
      expect(commands).to include(a_string_matching(/useradd --create-home/))
    end

    it 'leaves an existing user alone' do
      preparer, commands = build(answers: healthy)

      expect(result_for(preparer.prepare, :user).status).to eq(:ok)
      expect(commands).to all(satisfy { |cmd| !cmd.match?(/useradd/) })
    end
  end

  describe 'the docker group' do
    it 'adds a user that is not in it' do
      answers = healthy.merge(/id -nG/ => "odysseus users\n")
      preparer, commands = build(answers: answers)

      expect(result_for(preparer.prepare, :group).status).to eq(:changed)
      expect(commands).to include(a_string_matching(/usermod -aG docker/))
    end

    it 'leaves a user that is already in it' do
      preparer, commands = build(answers: healthy)

      expect(result_for(preparer.prepare, :group).status).to eq(:ok)
      expect(commands).to all(satisfy { |cmd| !cmd.match?(/usermod/) })
    end
  end

  describe 'authorized keys' do
    # Overwriting would lock out a second operator whose key is already there.
    it 'appends a missing key rather than overwriting the file' do
      answers = healthy.merge(/grep -qxF/ => "absent\n")
      preparer, commands = build(answers: answers)

      expect(result_for(preparer.prepare, :keys).status).to eq(:changed)
      expect(commands).to include(a_string_matching(/>>/))
      expect(commands).to all(satisfy { |cmd| !cmd.match?(/authorized_keys'?\s*$/) || !cmd.include?('> ') })
    end

    it 'does not append a key that is already present' do
      preparer, commands = build(answers: healthy)

      expect(result_for(preparer.prepare, :keys).status).to eq(:ok)
      expect(commands).to all(satisfy { |cmd| !cmd.include?('>>') })
    end

    # sshd silently ignores a loose ~/.ssh or authorized_keys, with no error
    # worth finding — so the modes are asserted, not assumed.
    it 'creates ~/.ssh as 700 and authorized_keys as 600, owned by the user' do
      answers = healthy.merge(/grep -qxF/ => "absent\n")
      preparer, commands = build(answers: answers)

      preparer.prepare

      expect(commands).to include(a_string_matching(/chmod 700 .*\.ssh/))
      expect(commands).to include(a_string_matching(/chmod 600 .*authorized_keys/))
      expect(commands).to include(a_string_matching(/chown .*odysseus.*\.ssh/))
    end
  end

  describe 'the self-test' do
    # The safety argument for the whole command: never hand back a host you
    # have not proven you can reach as the new user.
    it 'connects again as the new user and reports success only if that works' do
      preparer, = build(answers: healthy)

      expect(result_for(preparer.prepare, :self_test).status).to eq(:ok)
    end

    it 'fails when the new user cannot reach docker' do
      answers = healthy.merge(/test -d/ => "absent\n")
      preparer, = build(answers: answers)

      expect(result_for(preparer.prepare, :self_test).status).to eq(:fail)
    end
  end
end
```

**Why this task gives you a specification rather than code.** Every other task
here hands you the implementation verbatim; this one does not, deliberately. Its
eight steps are shell-building, and the code I wrote into this plan's siblings
has already contained several errors this session — a private method described as
public, two fixtures contradicting their own implementations. For a task this
size an exhaustive behavioural spec plus a mutation table instructs better than
code you would have to correct first. The requirements are exact; the command
strings are yours.

**Note for the implementer:** these examples describe the *behaviour* required. The exact command strings are yours to choose, but every assertion above must hold, and the `build` helper's `answers` patterns must match whatever you issue — if you need a command the healthy fixture does not cover, add the pattern rather than loosening the double. Where an example above stubs a method (`user_exists?`) that suggests a different shape, prefer changing the example to drive real behaviour through the connection rather than stubbing the class under test.

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/preparer_spec.rb`
Expected: FAIL — `uninitialized constant Odysseus::Setup::Preparer`.

- [ ] **Step 3: Write `Preparer`**

Create `odysseus-core/lib/odysseus/setup/preparer.rb`. The sequence, in order, each step check-then-apply and each returning one `Result`:

1. **`:escalation`** — call `escalation.probe!`. A `SetupError` becomes a `:fail` result and the sequence stops.
2. **`:distro`** — read `/etc/os-release`; require `ID=ubuntu` and `VERSION_ID` in `%w[24.04 26.04]`. Anything else is `:fail`, naming what was found, and the sequence stops. Nothing after this point may run on an unsupported host.
3. **`:docker`** — `docker info --format '{{.ServerVersion}}'`. Present is `:ok`; absent is `:fail` naming that Docker is required and not installed. **Do not install it** — plan 3b does that.
4. **`:user`** — `id -u <user>`; if absent, `useradd --create-home --shell /bin/bash <user>` and report `:changed`. If present, verify the home exists and is owned by the user (`stat -c '%U %G'`), repairing ownership if not — that is the half-created-user recovery — and report `:ok` or `:changed` accordingly. Never change an existing user's shell, home or password.
5. **`:group`** — `id -nG <user>`; if `docker` is absent, `usermod -aG docker <user>` and report `:changed`. Note `usermod -aG` affects only new sessions, which is harmless here because every later connection is new — but the self-test must therefore use a fresh connection.
6. **`:keys`** — create `~<user>/.ssh` (700) and `authorized_keys` (600), both owned by the user, then for each key line check with `grep -qxF` and **append** only the missing ones. Never overwrite: a second operator's key must survive someone else's re-run.
7. **`:state_dir`** — ensure `~<user>/.odysseus` exists, owned by the user. Caddy's directory is *not* pre-created: it derives from the connection user like everything else in `HostPaths`, so it lands under this user's home and the deploy path's own `mkdir -p` creates it when Caddy first starts.
8. **`:self_test`** — over a **fresh connection as `ssh.user`**, run `docker info` and confirm `~/.odysseus` is writable. Report `:ok` only if both work. This is the safety argument for the whole command: setup only ever adds access, so a failure here leaves the bootstrap path intact and the host reachable.

Escape every interpolated value with `Shellwords.escape` — the username and key lines both come from config, and key lines contain spaces by definition.

- [ ] **Step 4: Run the spec**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/preparer_spec.rb`
Expected: PASS.

- [ ] **Step 5: Verify the specs have teeth**

| Mutation | Must fail |
| --- | --- |
| `:distro` returns `:ok` for any distro | `refuses a distro it was not written for, naming it` |
| the sequence continues past a failed distro gate | the same example's command assertion |
| `:user` always runs `useradd` | `leaves an existing user alone` |
| `:user` never runs `useradd` | `creates one that does not exist, with a home and a locked password` |
| `:group` always runs `usermod` | `leaves a user that is already in it` |
| the keys step uses `>` instead of `>>` | `appends a missing key rather than overwriting the file` |
| drop the `chmod 600` on authorized_keys | `creates ~/.ssh as 700 and authorized_keys as 600, owned by the user` |
| `:self_test` returns `:ok` unconditionally | `fails when the new user cannot reach docker` |
| every step returns `:ok` instead of `:changed` | `creates one that does not exist…`, `adds a user that is not in it`, `appends a missing key…` |
| reorder the returned results | `reports one result per step, in a stable order` |

- [ ] **Step 6: Full suite and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: both green. Report the counts you get; do not trust a number written here.

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/setup/preparer.rb \
        odysseus-core/spec/odysseus/setup/preparer_spec.rb
git commit
```

The message should say why the self-test exists (never hand back a host you have not proven reachable) and why keys are appended rather than written.

---

### Task 4: The `setup` command

**Files:**
- Create: `odysseus-cli/lib/odysseus/cli/setup_commands.rb`
- Modify: `odysseus-cli/bin/odysseus`
- Modify: `odysseus-cli/spec/odysseus/cli/cli_spec.rb`
- Modify: `odysseus-cli/spec/odysseus/cli/bin_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::Setup::Escalation.new(ssh:, as:)`, `Odysseus::Setup::PublicKey.resolve(keys:, explicit:)`, `Odysseus::Setup::Preparer.new(ssh:, config:, escalation:, keys:).prepare` returning `Array<Result>` with `#step`, `#status`, `#detail`.
- Also: `Odysseus::Deployer::Executor#host_roles` (public since 0.8.0) for the unique host list, and the CLI's private `load_config` and `connect_to_server`.
- Produces: no new public Ruby API. A new CLI verb.

**Read `odysseus-cli/lib/odysseus/cli/doctor_commands.rb` first and mirror it** — the per-host loop, the `ensure`-closed connection, the per-host rescue so one unreachable host does not abort the run, the `escalate` worst-status logic and the exit-code decision are all solved there. Extract nothing; a second module doing the same shape is correct here, but the behaviour should match.

Differences from `doctor`: connections are opened as the **`--as` identity**, not `ssh.user`; `PublicKey.resolve` runs **once, before any host is touched**, so a missing key refuses before a single user is created; and `:changed` renders differently from `:ok` so a reader can see what a re-run did.

- [ ] **Step 1: Write the failing specs**

Add to `odysseus-cli/spec/odysseus/cli/cli_spec.rb`, using whatever helpers that file already provides (`output_of`, `fixture_path` — read the top of the file and confirm):

```ruby
  describe '#setup' do
    let(:ok)      { Odysseus::Setup::Preparer::Result.new(step: :docker, status: :ok, detail: 'docker 29.1.3') }
    let(:changed) { Odysseus::Setup::Preparer::Result.new(step: :user, status: :changed, detail: 'created odysseus') }
    let(:bad)     { Odysseus::Setup::Preparer::Result.new(step: :distro, status: :fail, detail: 'debian 12') }

    def run_setup(results, options = {})
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['ssh-ed25519 AAAAtest t@e'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: results))

      cli.setup({ config: fixture_path('deploy.yml') }.merge(options))
    end

    it 'exits zero when every step is ok or changed' do
      expect { run_setup([ok, changed]) }.not_to raise_error
    end

    it 'exits non-zero when a step fails' do
      expect { run_setup([ok, bad]) }.to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    it 'shows what it changed distinctly from what was already correct' do
      output = output_of { run_setup([ok, changed]) }

      expect(output).to include('created odysseus')
      expect(output).to include('docker 29.1.3')
    end

    # The default is the Ubuntu cloud image's user, so a stock image works
    # untouched.
    it 'connects as ubuntu by default' do
      users = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        users << args[:user]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: args[:user])
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [ok]))

      cli.setup(config: fixture_path('deploy.yml'))

      expect(users.uniq).to eq(['ubuntu'])
    end

    it 'connects as the identity --as names' do
      users = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        users << args[:user]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: args[:user])
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [ok]))

      cli.setup(config: fixture_path('deploy.yml'), as: 'root')

      expect(users.uniq).to eq(['root'])
    end

    # A created user with no way to log in is the worst outcome available, so
    # the key is resolved before a single host is touched.
    it 'refuses before connecting when no public key can be resolved' do
      allow(Odysseus::Setup::PublicKey).to receive(:resolve)
        .and_raise(Odysseus::SetupError, 'Found no public key to install')
      expect(Odysseus::Deployer::SSH).not_to receive(:new)

      expect { cli.setup(config: fixture_path('deploy.yml')) }.to raise_error(SystemExit)
    end

    it 'prepares every host in the config, not only the first' do
      hosts = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        hosts << args[:host]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [ok]))

      cli.setup(config: fixture_path('deploy.yml'))

      expect(hosts).to contain_exactly('web1.example.com', 'worker1.example.com')
    end

    it 'closes every connection it opens, even when a step fails' do
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [bad]))

      begin
        cli.setup(config: fixture_path('deploy.yml'))
      rescue SystemExit
        nil
      end

      expect(ssh).to have_received(:close).at_least(:once)
    end

    it 'reports a host whose preparation raises and continues to the next' do
      hosts = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        hosts << args[:host]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new) do
        instance_double(Odysseus::Setup::Preparer).tap do |p|
          allow(p).to receive(:prepare).and_raise(IOError, 'connection dropped')
        end
      end

      output = output_of do
        begin
          cli.setup(config: fixture_path('deploy.yml'))
        rescue SystemExit
          nil
        end
      end

      expect(hosts.size).to eq(2)
      expect(output).to include('IOError')
    end
  end
```

Then add to `odysseus-cli/spec/odysseus/cli/bin_spec.rb`, matching how that file drives the real executable (`run_cli`, returning three values — confirm by reading it):

```ruby
  it 'dispatches setup' do
    stdout, stderr, status = run_cli('setup', '--config', 'nope.yml')

    expect(stdout).not_to match(/Usage: odysseus <command>/)
    expect("#{stdout}#{stderr}").not_to match(/undefined method|NoMethodError/)
    expect(status).not_to eq(0)
  end

  it 'accepts --as and --key on setup' do
    stdout, stderr, = run_cli('setup', '--as', 'root', '--key', '/tmp/nope.pub', '--config', 'nope.yml')

    expect("#{stdout}#{stderr}").not_to include('OptionParser::InvalidOption')
  end
```

Also add `'setup'` to that file's pre-existing `every command the help lists` loop, since `setup` will appear in `print_help`.

- [ ] **Step 2: Run them and watch them fail**

Run: `cd odysseus-cli && bundle exec rspec`
Expected: FAIL — `cli.setup` undefined, and the bin examples see the usage banner.

- [ ] **Step 3: Write `setup_commands.rb`**

Create `odysseus-cli/lib/odysseus/cli/setup_commands.rb`, mirroring `doctor_commands.rb`'s structure. Its `setup(options = {})` must:

- resolve the public keys **first**, via `Odysseus::Setup::PublicKey.resolve(keys: config[:ssh][:keys], explicit: Array(options[:key]))`, and exit non-zero on `Odysseus::SetupError` before opening any connection;
- default the bootstrap identity to `'ubuntu'`, overridden by `options[:as]`;
- connect to each unique host **as that identity** rather than as `config[:ssh][:user]`;
- build an `Escalation` and a `Preparer` per host and render each `Result`;
- rescue per host so one host's failure is reported and the survey continues;
- close every connection in an `ensure`;
- escalate `:ok`/`:changed` → `:warn` → `:fail` and exit non-zero only on `:fail`.

Render `:changed` distinctly from `:ok` so a re-run visibly reports "nothing to do".

**And one thing `connect_to_server` cannot give you.** It hardcodes
`use_tailscale: true` (`cli.rb:870`), which makes `SSH` append Tailscale
troubleshooting advice to every connection timeout (`deployer/ssh.rb:158`).
`setup` targets exactly the fresh hosts that do *not* have Tailscale yet, so on
the one command where a timeout is most likely, that advice is actively
misleading. The spec names this under *What could go wrong*.

Build `setup`'s connections with `use_tailscale: false` rather than reusing
`connect_to_server` — either a small private helper here, or by giving
`connect_to_server` an optional keyword and passing `false`. Prefer the keyword
if it does not disturb the other five callers, and say which you chose and why.
Add an example asserting `setup` opens its connections with
`use_tailscale: false`, and confirm by mutation that flipping it to `true` fails
that example.

**`cli.rb` is close to its `Metrics/ClassLength` budget** — `doctor_commands.rb` exists because inlining that verb exceeded it. Put this in its own module for the same reason and include it the same way.

- [ ] **Step 4: Dispatch it**

In `odysseus-cli/bin/odysseus`, add to the `commands` hash:

```ruby
    'setup' => { method: :setup, needs_server: false },
```

Add both options to the parser:

```ruby
    opts.on('--as USER', 'Bootstrap identity for setup (default: ubuntu)') { |v| options[:as] = v }
    opts.on('--key PATH', 'Public key to install (repeatable; default: ssh.keys siblings)') do |v|
      (options[:key] ||= []) << v
    end
```

And to `print_help`'s command list:

```ruby
  puts '  setup                     Prepare hosts: create the deploy user, its group, key and state dir'
```

- [ ] **Step 5: Run the specs**

Run: `cd odysseus-cli && bundle exec rspec`
Expected: PASS.

- [ ] **Step 6: Verify the specs have teeth**

| Mutation | Must fail |
| --- | --- |
| default the identity to `config[:ssh][:user]` instead of `'ubuntu'` | `connects as ubuntu by default` |
| ignore `options[:as]` | `connects as the identity --as names` |
| resolve keys after connecting | `refuses before connecting when no public key can be resolved` |
| `escalate` returns `current` always | `exits non-zero when a step fails` |
| treat `:changed` as `:fail` in the exit decision | `exits zero when every step is ok or changed` |
| render only the status, not the detail | `shows what it changed distinctly from what was already correct` |
| break out of the host loop after one host | `prepares every host in the config, not only the first` |
| remove the `ensure ssh.close` | `closes every connection it opens, even when a step fails` |
| remove the per-host rescue | `reports a host whose preparation raises and continues to the next` |
| `use_tailscale: true` on setup's connections | the Tailscale example above |
| remove `'setup'` from the `commands` hash | `dispatches setup` |

- [ ] **Step 7: Both suites and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Run: `cd ../odysseus-cli && bundle exec rspec && bundle exec rubocop`
Expected: both green. Report the counts you get.

- [ ] **Step 8: Commit**

```bash
git add odysseus-cli/lib/odysseus/cli/setup_commands.rb odysseus-cli/bin/odysseus \
        odysseus-cli/spec/odysseus/cli/cli_spec.rb odysseus-cli/spec/odysseus/cli/bin_spec.rb
git commit
```

The message should say why the key is resolved before any host is touched, and why connections are opened as the `--as` identity rather than the deploy user.

---

### Task 5: Document it

**Files:**
- Modify: `odysseus-cli/README.md`
- Modify: `odysseus-core/CHANGELOG.md`
- Modify: `odysseus-cli/CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Document the command**

Add a `### setup` section beside the other command sections. It must say:

- `odysseus setup` prepares every host in the config: creates the user `ssh.user` names, adds it to the `docker` group, installs your public key, and creates its state directory. It **adds** access and never modifies root's or the bootstrap user's configuration.
- `--as USER` names the identity it connects *as*, defaulting to `ubuntu` — the user Ubuntu's LTS cloud images ship, with passwordless sudo already configured. `--as root` needs no sudo. Passwordless sudo is a hard requirement when not root, because odysseus cannot answer a password prompt.
- It adds **no config keys**: the user comes from `ssh.user`, the keys from `ssh.keys` (their `.pub` siblings, or derived), the hosts from `servers.*.hosts`. `--key PATH` overrides the key source.
- **Docker must already be installed** — this version refuses without it, naming what is missing. Do not describe an installer as coming or name a version.
- It reports what it changed separately from what was already correct, and running it twice against a healthy host changes nothing.
- It ends by connecting again **as the new user** and proving Docker and the state directory work; it reports success only if that passes. Say why: a failure then leaves the bootstrap path intact and the host reachable.
- Ubuntu 24.04 and 26.04 only; anything else is refused by name.
- **Point at `odysseus doctor`** as the way to check a host afterwards — including one a provisioning tool built. And say plainly that preparing servers at scale belongs to OpenTofu or equivalent; `setup` is for getting a single host going.

Per `CONTRIBUTING.md`, a README that promises a feature the code doesn't have is a bug. Describe only what this ships.

- [ ] **Step 2: Changelog entries**

`odysseus-core/CHANGELOG.md` under `## [Unreleased]` → `### Added`: `Odysseus::Setup::Escalation`, `::PublicKey` and `::Preparer`, what they do, and that Docker is not installed by this version.

`odysseus-cli/CHANGELOG.md` under `## [Unreleased]` → `### Added`: `odysseus setup`, its `--as` default, that it adds no config keys, and that it refuses without Docker.

- [ ] **Step 3: Check nothing contradicts this**

Run: `grep -rn "setup" odysseus-cli/README.md odysseus-core/README.md`
Every hit must describe what this ships. Report what you found.

Then run: `grep -rn "odysseus setup" odysseus-core/lib odysseus-cli/lib`
**This grep matters more than the READMEs.** A previous phase shipped a user-facing string naming a command that did not exist, and the sweep that should have caught it only checked the READMEs. Every hit here is a string a user reads.

- [ ] **Step 4: Commit**

```bash
git add odysseus-cli/README.md odysseus-core/CHANGELOG.md odysseus-cli/CHANGELOG.md
git commit
```

---

## Deliberately not in this plan

- **The Docker install** — plan 3b. This version refuses on a host without Docker rather than half-preparing it.
- **The deploy-log migration** — plan 3c. Its failure mode is silent loss of rollback history, which deserves its own plan.
- **Per-service networks.** Decided in the spec: hosts a provisioning tool built never run `setup` and need networks too, so the deploy path must create them regardless. Two implementations of one thing, with the `setup` copy being the untested one.
- **Anything touching `sshd_config`, the firewall, swap or unattended-upgrades.** Setup only adds access.
- **Removing or modifying an existing user's shell, home or password.**

## Definition of done

- Both suites green with the counts you measured, RuboCop clean in both gems.
- Every mutation in the tables above run, failing the named example, and reverted.
- `grep -rn "odysseus setup" odysseus-core/lib odysseus-cli/lib` returns only strings that are true of what shipped.
- Branch `feat/setup` with five commits, not merged.
