# HostPaths and non-root host state — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make odysseus's host state location depend on the SSH user, so a non-root deploy user writes under its own `$HOME` instead of failing at the first container start.

**Architecture:** One new class, `Odysseus::HostPaths`, derives a base directory from the connection's user: `/var/lib/odysseus` for root (unchanged), `$HOME/.odysseus` otherwise. `Docker::Client` and `DeployLog` each build one from the `ssh` object they already hold, so no constructor or call site changes. Caddy's certificate directory is deliberately excluded and stays at its fixed path for every user.

**Tech Stack:** Ruby 3.2+ (developed on 4.0.6), Zeitwerk autoloading, RSpec with `verify_partial_doubles` and `config.warnings = true`, RuboCop.

**Spec:** `docs/specs/2026-08-16-user-model-and-setup.md` — read it before starting, particularly *Verified ground truth* and *Host state*.

## Global Constraints

- Ruby `>= 3.2.0` (gemspec floor); developed against 4.0.6.
- **Root installs must be bit-for-bit unchanged.** A config with `ssh.user: root` — or none — must produce the exact same remote paths and the exact same number of SSH round trips as today. This is the whole back-compat story.
- **Caddy's directory does not move.** `/var/lib/odysseus/caddy` is the Let's Encrypt certificate store, root-owned and written by the container. It stays fixed for every user. — **Reversed 2026-08-17**, after a real deploy failed: a non-root user cannot create that parent, so no non-root web deploy could succeed. It now derives from the deploy user like everything else, with root still resolving to the old path. See the spec's correction note.
- Every spec must be verified against a deliberate mutation of the code under test (`CONTRIBUTING.md`). A spec that passes under its own mutation is not a spec.
- **Do not edit `.rubocop_todo.yml`** in either gem — they are debt snapshots.
- Both suites and RuboCop stay green. Baselines: odysseus-core 559 examples / 0 failures / 73 files clean; odysseus-cli 155 / 0 / 13 files clean.
- Work on branch `feat/host-paths`, branched from `trunk`. Do not merge.
- Commit messages explain *why*, matching `git log --oneline -12`. No "Generated with Claude Code" trailers.

## File Structure

| File | Responsibility |
| --- | --- |
| `odysseus-core/lib/odysseus/host_paths.rb` | **New.** Derives the base directory and the paths under it from an SSH connection. Single authority; the deploy lock will consume it later. |
| `odysseus-core/lib/odysseus/deployer/ssh.rb` | **Modify.** Expose `user` so `HostPaths` can read it. |
| `odysseus-core/lib/odysseus/docker/client.rb` | **Modify.** Env file paths come from `HostPaths` instead of the `ENV_FILE_DIR` constant. |
| `odysseus-core/lib/odysseus/deploy_log.rb` | **Modify.** Log path comes from `HostPaths`; reads fall back to the legacy location. |
| `odysseus-core/spec/odysseus/host_paths_spec.rb` | **New.** |

Zeitwerk maps `lib/odysseus/host_paths.rb` to `Odysseus::HostPaths` — no `require` needed.

---

### Task 1: `HostPaths`, and the SSH reader it needs

**Files:**
- Create: `odysseus-core/lib/odysseus/host_paths.rb`
- Create: `odysseus-core/spec/odysseus/host_paths_spec.rb`
- Modify: `odysseus-core/lib/odysseus/deployer/ssh.rb` (add reader near line 23)

**Interfaces:**
- Consumes: `Odysseus::Deployer::SSH#user` (added here), `#execute`.
- Produces: `Odysseus::HostPaths.new(ssh)` with `#base`, `#service_dir(service)`, `#env_dir`, `#legacy_base`, and the constant `HostPaths::CADDY_DIR`. Tasks 2 and 3 rely on exactly these names.

- [ ] **Step 1: Write the failing spec**

Create `odysseus-core/spec/odysseus/host_paths_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Odysseus::HostPaths do
  # A non-root fixture whose home is NOT under /var/lib/odysseus, so a mutation
  # that ignores the user entirely cannot pass by coincidence.
  def ssh_double(user:, home: '/home/odysseus')
    instance_double(Odysseus::Deployer::SSH, user: user).tap do |ssh|
      allow(ssh).to receive(:execute).with('echo $HOME').and_return("#{home}\n")
    end
  end

  describe '#base' do
    it 'is the system location for root' do
      expect(described_class.new(ssh_double(user: 'root')).base).to eq('/var/lib/odysseus')
    end

    it 'never asks the host where root lives' do
      ssh = ssh_double(user: 'root')
      described_class.new(ssh).base
      expect(ssh).not_to have_received(:execute)
    end

    it 'is under the home directory for any other user' do
      expect(described_class.new(ssh_double(user: 'odysseus')).base)
        .to eq('/home/odysseus/.odysseus')
    end

    it 'reads the home the host actually reports, not one built from the name' do
      ssh = ssh_double(user: 'deploy', home: '/srv/deploy')
      expect(described_class.new(ssh).base).to eq('/srv/deploy/.odysseus')
    end

    it 'asks the host only once, however many paths are built' do
      ssh = ssh_double(user: 'odysseus')
      paths = described_class.new(ssh)
      3.times { paths.service_dir('myapp') }
      expect(ssh).to have_received(:execute).with('echo $HOME').once
    end

    it 'refuses a host that reports no home rather than writing to /.odysseus' do
      ssh = ssh_double(user: 'odysseus', home: '')
      expect { described_class.new(ssh).base }
        .to raise_error(Odysseus::DeployError, /home directory/i)
    end
  end

  describe '#service_dir' do
    it 'is the service inside the base' do
      expect(described_class.new(ssh_double(user: 'root')).service_dir('myapp'))
        .to eq('/var/lib/odysseus/myapp')
    end

    it 'follows the user for a non-root connection' do
      expect(described_class.new(ssh_double(user: 'odysseus')).service_dir('myapp'))
        .to eq('/home/odysseus/.odysseus/myapp')
    end
  end

  describe '#env_dir' do
    it 'is env inside the base' do
      expect(described_class.new(ssh_double(user: 'root')).env_dir)
        .to eq('/var/lib/odysseus/env')
    end

    it 'follows the user for a non-root connection' do
      expect(described_class.new(ssh_double(user: 'odysseus')).env_dir)
        .to eq('/home/odysseus/.odysseus/env')
    end
  end

  describe '#legacy_base' do
    it 'is the system location whoever is connected' do
      expect(described_class.new(ssh_double(user: 'odysseus')).legacy_base)
        .to eq('/var/lib/odysseus')
    end
  end

  describe 'CADDY_DIR' do
    # Not derived from the user on purpose: it holds issued Let's Encrypt
    # certificates, is written by the Caddy container as root, and re-issuing
    # costs rate limit against a real domain.
    it 'is fixed regardless of who connects' do
      expect(described_class::CADDY_DIR).to eq('/var/lib/odysseus/caddy')
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/host_paths_spec.rb`
Expected: FAIL — `uninitialized constant Odysseus::HostPaths`.

- [ ] **Step 3: Add the SSH reader**

In `odysseus-core/lib/odysseus/deployer/ssh.rb`, immediately after the `initialize` method (which ends at line 23 with `end`), add:

```ruby
      # The user this connection authenticates as. Read by HostPaths, which
      # puts host state under /var/lib for root and under $HOME for anyone
      # else.
      attr_reader :user
```

- [ ] **Step 4: Write `HostPaths`**

Create `odysseus-core/lib/odysseus/host_paths.rb`:

```ruby
# lib/odysseus/host_paths.rb

module Odysseus
  # Where odysseus keeps its state on a target host.
  #
  # Root writes /var/lib/odysseus, which is where every install has always
  # written and where existing hosts still have their deploy history. Any other
  # user cannot create that directory, so their state goes under their own
  # home. One class answers this so the deploy log, the env files and — later —
  # the deploy lock cannot disagree about where they live.
  #
  # Caddy's directory is deliberately NOT here as a method: see CADDY_DIR.
  class HostPaths
    SYSTEM_BASE = '/var/lib/odysseus'.freeze
    USER_DIRNAME = '.odysseus'.freeze
    ROOT = 'root'.freeze

    # Caddy's /data mount: issued certificates, written by the container as
    # root, shared by every service on the host. It does not follow the deploy
    # user — moving it would mean copying live certificates or re-issuing
    # against Let's Encrypt rate limits, for no benefit.
    CADDY_DIR = "#{SYSTEM_BASE}/caddy".freeze

    # @param ssh [Odysseus::Deployer::SSH] connection whose user decides the base
    def initialize(ssh)
      @ssh = ssh
      @base = nil
    end

    # @return [String] the directory all odysseus state lives under
    def base
      @base ||= @ssh.user == ROOT ? SYSTEM_BASE : File.join(home, USER_DIRNAME)
    end

    # @param service [String] the service: value from deploy.yml
    # @return [String] that service's state directory
    def service_dir(service)
      File.join(base, service)
    end

    # @return [String] where env files are written for the length of a docker run
    def env_dir
      File.join(base, 'env')
    end

    # Where a root install wrote, whoever is connected now. Used to read the
    # deploy history of a host that has since moved to a deploy user.
    # @return [String]
    def legacy_base
      SYSTEM_BASE
    end

    private

    # Asked once per connection and cached. A host that reports nothing is an
    # error rather than a path of "/.odysseus", which would be unwritable and
    # would only be noticed later, as a failed deploy.
    def home
      value = @ssh.execute('echo $HOME').to_s.strip
      raise Odysseus::DeployError, "Could not determine the home directory of #{@ssh.user}" if value.empty?

      value
    end
  end
end
```

- [ ] **Step 5: Run the spec**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/host_paths_spec.rb`
Expected: PASS, 12 examples.

- [ ] **Step 6: Verify the specs have teeth**

Run each mutation, confirm the named example fails, then revert it.

| Mutation | Must fail |
| --- | --- |
| `@ssh.user == ROOT` → `true` | `is under the home directory for any other user` |
| `@ssh.user == ROOT` → `false` | `is the system location for root`, `never asks the host where root lives` |
| `File.join(home, USER_DIRNAME)` → `File.join('/home', @ssh.user, USER_DIRNAME)` | `reads the home the host actually reports, not one built from the name` |
| `@base ||=` → `@base =` | `asks the host only once, however many paths are built` |
| delete the `raise` in `home` | `refuses a host that reports no home rather than writing to /.odysseus` |
| `CADDY_DIR` → `"#{base}/caddy"` (make it a method) | `is fixed regardless of who connects` |

- [ ] **Step 7: Run the full suite and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: 571 examples, 0 failures; 74 files, no offenses.

- [ ] **Step 8: Commit**

```bash
git add odysseus-core/lib/odysseus/host_paths.rb \
        odysseus-core/lib/odysseus/deployer/ssh.rb \
        odysseus-core/spec/odysseus/host_paths_spec.rb
git commit
```

Message body should say why root keeps `/var/lib` (existing hosts have their history there, and root can write it) and why Caddy's directory is a constant rather than a method.

---

### Task 2: Env files follow the user

**Files:**
- Modify: `odysseus-core/lib/odysseus/docker/client.rb` (constant at line 13, uses at 381 and 393)
- Modify: `odysseus-core/spec/odysseus/docker/client_spec.rb`

**Interfaces:**
- Consumes: `HostPaths#env_dir` from Task 1.
- Produces: no new public API. `Docker::Client.new(ssh)` is unchanged — there are a dozen call sites and none of them move.

This is the change that makes non-root deploys possible at all: `write_env_file` runs `chmod 700` on the env directory, and a non-owner cannot chmod a root-owned directory, so today a non-root deploy dies at the first container start.

- [ ] **Step 1: Write the failing specs**

Add to `odysseus-core/spec/odysseus/docker/client_spec.rb`, inside the top-level describe:

```ruby
  describe 'where env files are written' do
    it 'uses the system directory for root' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'root')
      allow(ssh).to receive(:execute) { |cmd| commands << cmd; '' }
      allow(ssh).to receive(:upload_string)

      described_class.new(ssh).with_env_file({ 'A' => '1' }) { |path| commands << "used #{path}" }

      expect(commands).to include(a_string_matching(%r{mkdir -p /var/lib/odysseus/env}))
      expect(commands).to include(a_string_matching(%r{used /var/lib/odysseus/env/}))
    end

    it 'uses the home directory for a deploy user' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'odysseus')
      allow(ssh).to receive(:execute) do |cmd|
        commands << cmd
        cmd == 'echo $HOME' ? "/home/odysseus\n" : ''
      end
      allow(ssh).to receive(:upload_string)

      described_class.new(ssh).with_env_file({ 'A' => '1' }) { |path| commands << "used #{path}" }

      expect(commands).to include(a_string_matching(%r{mkdir -p /home/odysseus/\.odysseus/env}))
      expect(commands).to include(a_string_matching(%r{used /home/odysseus/\.odysseus/env/}))
      expect(commands).not_to include(a_string_matching(%r{/var/lib/odysseus}))
    end
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb -e 'where env files are written'`
Expected: the root example passes (that is today's behaviour); the deploy-user example FAILS, because the path is still `/var/lib/odysseus/env`.

- [ ] **Step 3: Replace the constant with the derived directory**

In `odysseus-core/lib/odysseus/docker/client.rb`, delete the `ENV_FILE_DIR` constant (line 13, plus its comment) and add a private memoised accessor beside the other private methods:

```ruby
      # Where this connection's env files go. Derived rather than constant
      # because a deploy user cannot write — or chmod — the system directory.
      def host_paths
        @host_paths ||= Odysseus::HostPaths.new(@ssh)
      end
```

Then at the two use sites:

```ruby
      # was: "#{ENV_FILE_DIR}/#{name}.env"
      "#{host_paths.env_dir}/#{name}.env"
```

```ruby
      # was: @ssh.execute("mkdir -p #{ENV_FILE_DIR} && chmod 700 #{ENV_FILE_DIR}")
      dir = host_paths.env_dir
      @ssh.execute("mkdir -p #{Shellwords.escape(dir)} && chmod 700 #{Shellwords.escape(dir)}")
```

`Shellwords` is already required at the top of the file. Escaping matters now that the path contains a home directory rather than a fixed literal.

- [ ] **Step 4: Run the specs**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb`
Expected: PASS, including both new examples.

- [ ] **Step 5: Check for other references to the removed constant**

Run: `grep -rn "ENV_FILE_DIR" odysseus-core odysseus-cli --include=*.rb`
Expected: no matches. If a spec referenced it, update that spec to assert the path instead of the constant — a spec that reads the constant it is testing proves nothing.

- [ ] **Step 6: Verify the specs have teeth**

| Mutation | Must fail |
| --- | --- |
| `host_paths.env_dir` → `'/var/lib/odysseus/env'` at both sites | `uses the home directory for a deploy user` |
| drop `chmod 700` | the existing `chmod` example added in 0.7.0 |

- [ ] **Step 7: Full suite and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: 573 examples, 0 failures; no offenses.

- [ ] **Step 8: Commit**

```bash
git add odysseus-core/lib/odysseus/docker/client.rb \
        odysseus-core/spec/odysseus/docker/client_spec.rb
git commit
```

Say in the message that this is the change that unblocks non-root deploys, and why: `chmod` on a root-owned directory fails for a non-owner, so the first container start was the first failure.

---

### Task 3: The deploy log follows the user, and still reads the old one

**Files:**
- Modify: `odysseus-core/lib/odysseus/deploy_log.rb` (constant at line 12, `#path` at 26, `#entries` at 50)
- Modify: `odysseus-core/spec/odysseus/deploy_log_spec.rb`

**Interfaces:**
- Consumes: `HostPaths#service_dir`, `#legacy_base` from Task 1.
- Produces: `DeployLog#path` (unchanged name, now user-dependent) and `#legacy_path`. `DeployLog.new(ssh:, service:)` is unchanged — its three call sites do not move.

A host that has been deploying as root has real history at `/var/lib/odysseus/<service>/deploys.log`, which `rollback --list` reads via `host_versions.rb:30`. Once that host moves to a deploy user, the new path is empty. Losing the history is silent — `rollback` simply offers fewer versions — so reads fall back to the old location. Appends always go to the new one.

- [ ] **Step 1: Write the failing specs**

Add to `odysseus-core/spec/odysseus/deploy_log_spec.rb`:

```ruby
  describe 'where the log lives' do
    it 'is the system location for root' do
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'root')
      expect(described_class.new(ssh: ssh, service: 'myapp').path)
        .to eq('/var/lib/odysseus/myapp/deploys.log')
    end

    it 'is under the home directory for a deploy user' do
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'odysseus')
      allow(ssh).to receive(:execute).with('echo $HOME').and_return("/home/odysseus\n")

      expect(described_class.new(ssh: ssh, service: 'myapp').path)
        .to eq('/home/odysseus/.odysseus/myapp/deploys.log')
    end

    it 'knows the location a root install used, whoever is connected' do
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'odysseus')
      allow(ssh).to receive(:execute).with('echo $HOME').and_return("/home/odysseus\n")

      expect(described_class.new(ssh: ssh, service: 'myapp').legacy_path)
        .to eq('/var/lib/odysseus/myapp/deploys.log')
    end
  end

  describe 'reading a host that used to deploy as root' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, user: 'odysseus') }
    let(:log) { described_class.new(ssh: ssh, service: 'myapp') }
    let(:record) { '2026-08-16T10:00:00Z abc123 web - thomas@imfiny.com deployed' }

    before { allow(ssh).to receive(:execute).with('echo $HOME').and_return("/home/odysseus\n") }

    it 'still reads the location a root install wrote, so history survives the move' do
      command = nil
      allow(ssh).to receive(:execute) do |cmd|
        cmd == 'echo $HOME' ? "/home/odysseus\n" : (command = cmd; "#{record}\n")
      end

      log.entries

      # The fallback itself happens in the shell (`cat a || cat b`), not in
      # Ruby, so a doubled connection cannot exercise it. What IS testable —
      # and what actually fails if the fallback is dropped — is that the legacy
      # path appears in the command at all. Asserting on the parsed entries
      # instead would pass whether or not the fallback were there, because the
      # double answers every cat identically.
      expect(command).to include('/var/lib/odysseus/myapp/deploys.log')
    end

    it 'reads the new location in preference to the old' do
      command = nil
      allow(ssh).to receive(:execute) do |cmd|
        cmd == 'echo $HOME' ? "/home/odysseus\n" : (command = cmd; "#{record}\n")
      end

      log.entries

      # The new path must be attempted before the legacy one, or a migrated
      # host would keep reading its frozen history forever.
      expect(command.index('/home/odysseus/.odysseus/myapp/deploys.log'))
        .to be < command.index('/var/lib/odysseus/myapp/deploys.log')
    end

    it 'appends only to the new location' do
      written = nil
      allow(ssh).to receive(:execute) do |cmd|
        written = cmd if cmd.start_with?('printf')
        cmd == 'echo $HOME' ? "/home/odysseus\n" : ''
      end

      log.append(version: 'abc123', role: :web, ref: nil, deployer: 'thomas@imfiny.com')

      expect(written).to include('/home/odysseus/.odysseus/myapp/deploys.log')
      expect(written).not_to include('/var/lib/odysseus')
    end
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/deploy_log_spec.rb`
Expected: the root example passes; the deploy-user examples FAIL on the path, and the fallback examples FAIL because `entries` reads one location.

- [ ] **Step 3: Derive both paths and fall back on read**

In `odysseus-core/lib/odysseus/deploy_log.rb`, delete the `PATH_ROOT` constant (line 12) and change `#path`, add `#legacy_path`, and change `#entries`:

```ruby
    # @return [String] absolute path of this service's log on the host
    def path
      File.join(host_paths.service_dir(@service), FILENAME)
    end

    # Where a root install wrote this log. A host that has since moved to a
    # deploy user still has its history here, and nothing ever deletes it.
    # @return [String]
    def legacy_path
      File.join(host_paths.legacy_base, @service, FILENAME)
    end
```

```ruby
    # @return [Array<Entry>] parsed entries, oldest first; empty when absent
    def entries
      # Prefer the current location, then the one a root install used. No
      # merging: a host deploying as two different users is not a supported
      # shape, and merging two histories would invent an ordering.
      raw = @ssh.execute(
        "cat #{Shellwords.escape(path)} 2>/dev/null || " \
        "cat #{Shellwords.escape(legacy_path)} 2>/dev/null || true"
      )

      raw.to_s.lines.filter_map { |line| parse_line(line) }
    end
```

And add beside the other private methods:

```ruby
    def host_paths
      @host_paths ||= Odysseus::HostPaths.new(@ssh)
    end
```

`#append` needs no change: it already builds from `path`, which now derives.

- [ ] **Step 4: Run the specs**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/deploy_log_spec.rb`
Expected: PASS.

- [ ] **Step 5: Check for other references to the removed constant**

Run: `grep -rn "PATH_ROOT" odysseus-core odysseus-cli --include=*.rb`
Expected: no matches.

- [ ] **Step 6: Verify the specs have teeth**

| Mutation | Must fail |
| --- | --- |
| `path` built from `legacy_base` | `is under the home directory for a deploy user` |
| swap the two `cat`s in `entries` | `reads the new location in preference to the old` |
| drop the legacy `cat` entirely | `still reads the location a root install wrote, so history survives the move` |
| `append` writing to `legacy_path` | `appends only to the new location` |

- [ ] **Step 7: Full suite and RuboCop, both gems**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Run: `cd ../odysseus-cli && bundle exec rspec && bundle exec rubocop`
Expected: core 580 / 0 and clean; cli 155 / 0 and clean. The CLI suite must be unchanged — if anything there moves, a path leaked into a CLI expectation and that is a finding, not something to patch over.

- [ ] **Step 8: Commit**

```bash
git add odysseus-core/lib/odysseus/deploy_log.rb \
        odysseus-core/spec/odysseus/deploy_log_spec.rb
git commit
```

Explain in the message that losing the history is silent — rollback offers fewer versions rather than erroring — which is why reads fall back and appends do not.

---

### Task 4: Say what changed

**Files:**
- Modify: `odysseus-core/CHANGELOG.md`
- Modify: `odysseus-cli/README.md` (the `ssh` config section)

**Interfaces:** none.

- [ ] **Step 1: Add the changelog entry**

Under a new `## [Unreleased]` heading in `odysseus-core/CHANGELOG.md`, with an `### Added` and a `### Changed`. It must say:

- Host state now depends on the SSH user: root keeps `/var/lib/odysseus` exactly as before; any other user gets `$HOME/.odysseus`.
- Non-root deploys previously could not work at all — the env directory `chmod` fails for a non-owner — so this is the change that makes them possible on a host you have configured yourself.
- Caddy's certificate directory does not move. (**Reversed 2026-08-17** — see above.)
- A host that deployed as root and later moves to a deploy user keeps its rollback history: reads fall back to the old location, appends go to the new one.
- Nothing changes for a root install.

- [ ] **Step 2: Document the deploy user in the README**

In the `ssh` section of `odysseus-cli/README.md`, state what `user` now implies for where state lives, and that a non-root user must already exist on the host with docker group membership and a writable home — because `odysseus setup` does not exist yet.

Do **not** write anything about `setup`, and do not imply non-root is the recommended path. Per `CONTRIBUTING.md`, a README that promises a feature the code doesn't have is a bug — and phases 2 to 4 are what make this comfortable.

- [ ] **Step 3: Verify no other doc contradicts this**

Run: `grep -rn "/var/lib/odysseus" odysseus-cli/README.md odysseus-core/README.md docs/`
Every hit must be either about Caddy's directory (which is correct as written) or updated to say it is the root-install location. Report what you found.

- [ ] **Step 4: Commit**

```bash
git add odysseus-core/CHANGELOG.md odysseus-cli/README.md
git commit
```

---

## Deliberately not in this phase

The spec notes that `Executor#record_deploy` rescues `StandardError` and only
warns (`deployer/executor.rb:343-350`), so a permissions failure erodes
rollback history invisibly, and says it is worth fixing "in the same phase".
It is not a task here, on purpose.

Making it fatal is a real behaviour decision — should a deploy that succeeded
report failure because its log could not be written? — and it deserves to be
taken deliberately rather than folded into a path change. The phase-1 work
also reduces the exposure rather than adding to it: for a non-root user the
log now lives under a home directory it owns, which is the case that could not
have worked before. Left for phase 2, where `setup --verify` checks
writability and gives the failure somewhere to be reported.

## Definition of done

- `odysseus-core` 580 examples / 0 failures, RuboCop clean; `odysseus-cli` 155 / 0, clean.
- `grep -rn "ENV_FILE_DIR\|PATH_ROOT" odysseus-core odysseus-cli --include=*.rb` returns nothing.
- Every mutation in the tables above was run, failed the named example, and was reverted.
- A root-connected `Docker::Client` makes no `echo $HOME` call — verified by a spec, not by reading.
- Branch `feat/host-paths` with four commits, not merged.
