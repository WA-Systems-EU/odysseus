# Docker install from apt — Phase 3b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `odysseus setup` installs Docker from Docker's official apt repository when a host doesn't have it, instead of refusing.

**Architecture:** The install is its own unit, `Odysseus::Setup::DockerApt`, driven by `Preparer#docker_step`, which keeps its existing check-first shape: if `docker info` answers, skip and report `:ok`; otherwise install, re-check, and report `:changed` or `:fail`. Both files it writes on the host — the keyring and the sources list — are written *whole* every run rather than appended, so an interrupted run leaves a stale file the next run overwrites rather than a corrupt one with two repo lines. Every apt invocation carries a bounded lock wait, and a timeout names the process holding the lock.

**Tech Stack:** Ruby 3.2+ (developed on 4.0.6), Zeitwerk autoloading, RSpec with `verify_partial_doubles` and `config.warnings = true`, RuboCop with a frozen `.rubocop_todo.yml` per gem.

**Spec:** `docs/specs/2026-08-16-user-model-and-setup.md` — phase 3 step 2, the "An interrupted Docker install" risk, and the phasing note deciding this lands with `setup` rather than after it.

**Branch:** `feat/setup`, on top of phase 3a (head `c2bf669`). 3a and 3b merge together; 3c (deploy-log migration) does not.

## Global Constraints

- Ubuntu **24.04 and 26.04** only. `SUPPORTED_UBUNTU` already gates this; do not widen it, and do not add Debian — the spec refuses it for lack of a host to test against, not unsuitability.
- **Do not pin Docker's GPG key fingerprint.** The spec leaves this open and decides against for now: pinning turns Docker's key rotation into every user's outage. Trust TLS to `download.docker.com`, which is what Docker's own instructions do.
- Setup **only ever adds access**. It never modifies root's or the bootstrap user's configuration, never touches the firewall, swap, `sshd_config` or unattended-upgrades, and **never attempts to repair an apt or dpkg state it did not create**. A broken apt state is reported, not fixed.
- Every file written on the host is written **whole**, never appended.
- A sudo password prompt can never be answered (`non_interactive: true`), so nothing may prompt. Non-interactive apt is mandatory.
- Baselines to beat: `odysseus-core` **690/0**, `odysseus-cli` **190/0**, RuboCop clean in both (**83** and **15** files).
- Neither `.rubocop_todo.yml` may be edited. They are debt snapshots.
- Per `CONTRIBUTING.md`, every spec is checked against a deliberate mutation, and a README promising what the code lacks is a bug.

## File Structure

| File | Responsibility |
|---|---|
| `odysseus-core/lib/odysseus/setup/escalation.rb` | Gains `#elevate(command)` — the single place that decides the sudo prefix |
| `odysseus-core/lib/odysseus/setup/docker_apt.rb` | **New.** The apt install: keyring, sources, packages, lock handling |
| `odysseus-core/lib/odysseus/setup/preparer.rb` | `#docker_step` drives it; `#read_os_release` memoized so the codename is free |
| `odysseus-core/spec/odysseus/setup/escalation_spec.rb` | `#elevate` under both identities |
| `odysseus-core/spec/odysseus/setup/docker_apt_spec.rb` | **New.** Command sequence, whole-file writes, lock timeout |
| `odysseus-core/spec/odysseus/setup/preparer_spec.rb` | The three docker outcomes |
| `odysseus-cli/README.md`, both `CHANGELOG.md` | The claims this phase inverts |

`DockerApt` is a separate file rather than more methods on `Preparer` because `Preparer` is already ~340 lines and near the size where this project has previously been forced to extract, and because the install is a cohesive unit with its own failure modes worth testing directly.

---

### Task 1: `Escalation#elevate` — one place that decides the sudo prefix

The whole-branch reviewer of 3a accepted the duplicated sudo-prefix logic (`Escalation#run` and `Preparer#append_key`) and set the trigger explicitly: *"A fourth builder or third prefix site is the trigger."* Task 2 needs a third site — writing the sources file through `tee` — so the trigger fires here, before that site exists.

**Files:**
- Modify: `odysseus-core/lib/odysseus/setup/escalation.rb`
- Modify: `odysseus-core/lib/odysseus/setup/preparer.rb` (`#append_key` only)
- Test: `odysseus-core/spec/odysseus/setup/escalation_spec.rb`

**Interfaces:**
- Produces: `Escalation#elevate(command) -> String` — the command with `sudo -n ` prefixed when `sudo?`, unchanged when running as root. Pure string building; it executes nothing.
- `Escalation#run(command)` keeps its exact current behaviour and signature.

- [ ] **Step 1: Write the failing tests**

Add to `odysseus-core/spec/odysseus/setup/escalation_spec.rb`:

```ruby
describe '#elevate' do
  it 'prefixes sudo for a non-root bootstrap identity' do
    ssh = instance_double(Odysseus::Deployer::SSH)
    escalation = described_class.new(ssh: ssh, as: 'ubuntu')

    expect(escalation.elevate('tee /etc/apt/sources.list.d/docker.list'))
      .to eq('sudo -n tee /etc/apt/sources.list.d/docker.list')
  end

  it 'leaves the command alone as root, which may not have sudo installed' do
    ssh = instance_double(Odysseus::Deployer::SSH)
    escalation = described_class.new(ssh: ssh, as: 'root')

    expect(escalation.elevate('tee /etc/apt/sources.list.d/docker.list'))
      .to eq('tee /etc/apt/sources.list.d/docker.list')
  end

  # The point of extracting this: #run must be the same decision, not a
  # second one that happens to agree today.
  it 'is the same decision #run makes' do
    ssh = instance_double(Odysseus::Deployer::SSH)
    allow(ssh).to receive(:execute)
    escalation = described_class.new(ssh: ssh, as: 'ubuntu')

    escalation.run('whoami')

    expect(ssh).to have_received(:execute).with(escalation.elevate('whoami'))
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/escalation_spec.rb`
Expected: FAIL — `undefined method 'elevate'`.

- [ ] **Step 3: Implement**

In `escalation.rb`, add `#elevate` and make `#run` compose it:

```ruby
      # The one place that decides whether a command needs a sudo prefix.
      # Exposed rather than kept inside #run because a command whose
      # privileged half is only *part* of a pipeline cannot go through #run:
      # `sudo -n printf ... | tee file` would elevate printf and leave tee
      # unprivileged, which is the defect that made the first authorized_keys
      # append fail under the documented default identity. Callers in that
      # position build the pipeline themselves and elevate the writer alone.
      #
      # @param command [String] a command that needs root
      # @return [String] it, prefixed when a prefix is needed
      def elevate(command)
        sudo? ? "sudo -n #{command}" : command
      end

      # @param command [String] a command that needs root
      # @return [String] its output
      def run(command)
        @ssh.execute(elevate(command))
      end
```

In `preparer.rb`, `#append_key` composes it instead of re-deciding. Replace the two `writer` lines with:

```ruby
        writer = @escalation.elevate("tee -a #{Shellwords.escape(authorized_keys)}")
```

Keep the entire existing comment block above `#append_key` — it explains *why* the pipeline is built by hand, which is still true — but replace its last sentence ("Nothing here needs escalation at all under --as root, so the sudo prefix is applied to the writer alone, and only when it's needed.") with:

```ruby
      # Nothing here needs escalation at all under --as root, so the prefix is
      # applied to the writer alone and only when needed -- via
      # Escalation#elevate, so this is not a second opinion about when sudo is
      # required.
```

- [ ] **Step 4: Run the full core suite**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: 693/0 (690 + 3 new), 83 files clean. `#append_key`'s behaviour is unchanged, so every existing preparer example must still pass untouched — if any fails, the refactor changed behaviour and is wrong.

- [ ] **Step 5: Mutation check**

| Mutation | Example that must fail |
|---|---|
| `elevate` returns `command` unconditionally | `prefixes sudo for a non-root bootstrap identity` |
| `elevate` returns `"sudo -n #{command}"` unconditionally | `leaves the command alone as root, which may not have sudo installed` |
| `run` reverts to `@ssh.execute(sudo? ? "sudo -n #{command}" : command)` inline | *None — this is behaviour-identical.* Instead mutate `elevate` to `"sudo #{command}"` (dropping `-n`) and confirm `is the same decision #run makes` still passes while the first example fails: that proves the third example pins agreement, not the prefix's content. |

Run each, confirm the named example fails, revert.

- [ ] **Step 6: Commit**

```bash
git add odysseus-core/lib/odysseus/setup/escalation.rb odysseus-core/lib/odysseus/setup/preparer.rb odysseus-core/spec/odysseus/setup/escalation_spec.rb
git commit -m "Give Escalation one place that decides the sudo prefix"
```

---

### Task 2: `Setup::DockerApt` — the install itself

**Files:**
- Create: `odysseus-core/lib/odysseus/setup/docker_apt.rb`
- Test: `odysseus-core/spec/odysseus/setup/docker_apt_spec.rb`

**Interfaces:**
- Consumes: `Escalation#run(command) -> String`, `Escalation#elevate(command) -> String` (Task 1).
- Produces: `DockerApt.new(ssh:, escalation:, codename:)` and `#install!`, which returns `nil` on success and raises `Odysseus::SetupError` on any failure. It does **not** verify Docker afterwards — `Preparer` owns the re-check, because it owns the `docker info` probe already.

`codename` is Ubuntu's `VERSION_CODENAME` from `/etc/os-release` (`noble` for 24.04). Task 3 passes it in.

- [ ] **Step 1: Write the failing tests**

Create `odysseus-core/spec/odysseus/setup/docker_apt_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'shellwords'

RSpec.describe Odysseus::Setup::DockerApt do
  # Same recording harness as preparer_spec: an unanticipated command raises
  # rather than silently answering '', because this project has repeatedly
  # shipped bugs where a doubled connection cheerfully answered a command that
  # could never work on a real host.
  def build(answers:, as: 'ubuntu', codename: 'noble')
    commands = []
    ssh = instance_double(Odysseus::Deployer::SSH)
    allow(ssh).to receive(:execute) do |cmd|
      commands << cmd
      pattern = answers.keys.find { |p| cmd.match?(p) }
      raise "spec did not anticipate: #{cmd}" unless pattern

      answer = answers[pattern]
      raise answer if answer.is_a?(Exception)

      answer
    end

    escalation = Odysseus::Setup::Escalation.new(ssh: ssh, as: as)
    [described_class.new(ssh: ssh, escalation: escalation, codename: codename), commands]
  end

  let(:healthy) do
    {
      /dpkg --print-architecture/ => "amd64\n",
      /apt-get .*update/ => '',
      /apt-get .*install/ => '',
      /install -m 0755 -d/ => '',
      /curl -fsSL/ => '',
      /chmod a\+r/ => '',
      /tee/ => ''
    }
  end

  it 'writes the keyring with curl, so the file is opened by the elevated process' do
    apt, commands = build(answers: healthy)

    apt.install!

    keyring = commands.find { |c| c.include?('curl -fsSL') }
    expect(keyring).to eq(
      'sudo -n curl -fsSL https://download.docker.com/linux/ubuntu/gpg ' \
      '-o /etc/apt/keyrings/docker.asc'
    )
  end

  # The whole-file rule. `tee -a` here would append a second identical repo
  # line on every run, and a redirect would be opened by the unprivileged
  # bootstrap shell rather than by sudo.
  it 'writes the sources file whole, through a tee that is itself elevated' do
    apt, commands = build(answers: healthy)

    apt.install!

    sources = commands.find { |c| c.include?('docker.list') }
    expect(sources).to eq(
      "printf '%s\n' " \
      "#{Shellwords.escape('deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] ' \
                           'https://download.docker.com/linux/ubuntu noble stable')} " \
      '| sudo -n tee /etc/apt/sources.list.d/docker.list >/dev/null'
    )
    expect(sources).not_to include('tee -a')
  end

  it 'takes the architecture from the host rather than assuming amd64' do
    apt, commands = build(answers: healthy.merge(/dpkg --print-architecture/ => "arm64\n"))

    apt.install!

    expect(commands.find { |c| c.include?('docker.list') }).to include('arch=arm64')
  end

  it 'takes the codename from the caller rather than assuming one' do
    apt, commands = build(answers: healthy, codename: 'plucky')

    apt.install!

    expect(commands.find { |c| c.include?('docker.list') }).to include(' plucky stable')
  end

  it 'runs apt non-interactively and with a bounded wait for the dpkg lock' do
    apt, commands = build(answers: healthy)

    apt.install!

    apt_calls = commands.select { |c| c.include?('apt-get') }
    expect(apt_calls).to all(include('env DEBIAN_FRONTEND=noninteractive'))
    expect(apt_calls).to all(include('-o DPkg::Lock::Timeout=300'))
  end

  it 'installs the plugins, not only the daemon' do
    apt, commands = build(answers: healthy)

    apt.install!

    install = commands.find { |c| c.include?('apt-get') && c.include?('docker-ce') }
    %w[docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin].each do |pkg|
      expect(install).to include(pkg)
    end
  end

  it 'refreshes the package lists after adding the repository, not only before' do
    apt, commands = build(answers: healthy)

    apt.install!

    sources_at = commands.index { |c| c.include?('docker.list') }
    update_after = commands.each_index.select { |i| commands[i].match?(/apt-get.*update/) && i > sources_at }
    expect(update_after).not_to be_empty
  end

  # NOTE ON PATTERN ORDER, and it matters: the harness resolves an answer with
  # `answers.keys.find { |p| cmd.match?(p) }` -- the FIRST matching key wins,
  # and Hash#merge appends new keys at the end. So a specific pattern must be
  # placed BEFORE the general one it refines, or `/apt-get .*install/` from
  # `healthy` answers the docker-ce install and the failure never fires,
  # leaving the example green while testing nothing.
  it 'names the process holding the dpkg lock when apt times out' do
    answers = {
      /apt-get .*install -y docker-ce/ =>
        Odysseus::SSHCommandError.new('exit status 100: Could not get lock'),
      /fuser/ => "1234\n",
      /ps -o comm=/ => "unattended-upgrade\n"
    }.merge(healthy)
    apt, = build(answers: answers)

    expect { apt.install! }
      .to raise_error(Odysseus::SetupError, /unattended-upgrade.*1234/m)
  end

  # A "never do this" guard rather than a mutation target: nothing in the
  # current implementation issues `dpkg --configure`, so this example cannot
  # fail today. It is here to fail the day someone adds a repair step, which
  # the spec forbids. Recorded honestly in the mutation table as having no
  # mutation, rather than given a fabricated one.
  it 'does not try to repair an apt state it did not create' do
    answers = {
      /apt-get .*install -y docker-ce/ =>
        Odysseus::SSHCommandError.new('exit status 100: dpkg was interrupted'),
      /fuser/ => '',
      /ps -o comm=/ => ''
    }.merge(healthy)
    apt, commands = build(answers: answers)

    expect { apt.install! }.to raise_error(Odysseus::SetupError)
    expect(commands).to all(satisfy { |c| !c.include?('dpkg --configure') })
  end

  it 'refuses rather than building a repository line with a blank codename' do
    apt, commands = build(answers: healthy, codename: '')

    expect { apt.install! }.to raise_error(Odysseus::SetupError, /codename/i)
    expect(commands).to be_empty
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/docker_apt_spec.rb`
Expected: FAIL — `uninitialized constant Odysseus::Setup::DockerApt`.

- [ ] **Step 3: Implement**

Create `odysseus-core/lib/odysseus/setup/docker_apt.rb`:

```ruby
# lib/odysseus/setup/docker_apt.rb

require 'shellwords'

module Odysseus
  module Setup
    # Installs Docker from Docker's official apt repository, following Docker's
    # own published instructions for Ubuntu.
    #
    # Every file this writes on the host is written WHOLE rather than appended,
    # so a run interrupted anywhere leaves a stale file that the next run
    # overwrites -- never a corrupt one with the repository listed twice.
    #
    # It repairs nothing it did not create: a broken dpkg state, a held lock, a
    # third-party repository that fails to refresh are all reported and raised,
    # not worked around. Guessing at someone else's apt state is how a bootstrap
    # leaves a machine worse than it found it.
    #
    # The GPG key's fingerprint is deliberately not pinned. Pinning defends
    # against a CA-level compromise of download.docker.com, but turns Docker's
    # key rotation into an outage for everyone using this command; Docker's own
    # instructions trust TLS, and so does this.
    class DockerApt
      KEYRING = '/etc/apt/keyrings/docker.asc'
      SOURCES = '/etc/apt/sources.list.d/docker.list'
      GPG_URL = 'https://download.docker.com/linux/ubuntu/gpg'
      REPO_URL = 'https://download.docker.com/linux/ubuntu'
      LOCK_FILE = '/var/lib/dpkg/lock-frontend'

      # Long enough to outlast cloud-init and unattended-upgrades on a
      # minutes-old host, which is the normal state of a machine someone is
      # running setup against; short enough that a genuinely stuck lock is an
      # error rather than a session that never returns.
      LOCK_TIMEOUT = 300

      PACKAGES = %w[
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ].freeze

      # @param ssh [Odysseus::Deployer::SSH] connection as the bootstrap identity
      # @param escalation [Odysseus::Setup::Escalation] how root is reached
      # @param codename [String] Ubuntu's VERSION_CODENAME, e.g. "noble"
      def initialize(ssh:, escalation:, codename:)
        @ssh = ssh
        @escalation = escalation
        @codename = codename.to_s.strip
      end

      # @return [nil]
      # @raise [Odysseus::SetupError] on any failure, with the apt output's
      #   first line and, for a lock timeout, the process holding it
      def install!
        if @codename.empty?
          raise Odysseus::SetupError,
                '/etc/os-release reported no VERSION_CODENAME, so the apt repository line ' \
                'cannot name a release. Refusing to guess one.'
        end

        apt('update')
        apt('install -y ca-certificates curl')
        @escalation.run('install -m 0755 -d /etc/apt/keyrings')
        # curl -o, not a redirect: the file is opened by the process sudo
        # elevated, not by the bootstrap identity's own shell.
        @escalation.run("curl -fsSL #{GPG_URL} -o #{KEYRING}")
        @escalation.run("chmod a+r #{KEYRING}")
        write_sources
        # The repository is only visible to apt after a refresh that follows
        # the sources file, so this update is not the same as the one above.
        apt('update')
        apt("install -y #{PACKAGES.join(' ')}")

        nil
      end

      private

      def arch
        @arch ||= @escalation.run('dpkg --print-architecture').to_s.strip
      end

      def sources_line
        "deb [arch=#{arch} signed-by=#{KEYRING}] #{REPO_URL} #{@codename} stable"
      end

      # `tee`, not `tee -a`: this file is replaced, not added to. The prefix
      # goes on the writer alone via Escalation#elevate -- prefixing the whole
      # pipeline would elevate printf and leave tee unprivileged, which is the
      # defect that made setup's first authorized_keys append fail under the
      # documented default identity.
      def write_sources
        writer = @escalation.elevate("tee #{Shellwords.escape(SOURCES)}")
        @ssh.execute("printf '%s\n' #{Shellwords.escape(sources_line)} | #{writer} >/dev/null")
      end

      # `env DEBIAN_FRONTEND=noninteractive` rather than a bare assignment:
      # sudoers may refuse to pass an environment variable through, and a
      # prompt cannot be answered on a non-interactive connection at all.
      def apt(args)
        @escalation.run(
          "env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=#{LOCK_TIMEOUT} #{args}"
        )
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "apt-get #{args.split.first} failed#{lock_holder_note}: " \
              "#{e.message.lines.first.to_s.strip}"
      end

      # Best-effort attribution, never a second failure: if fuser or ps is
      # missing the message simply says less.
      def lock_holder_note
        pid = @escalation.run("fuser #{LOCK_FILE} 2>/dev/null | tr -d ' '").to_s.strip
        return '' if pid.empty?

        name = @escalation.run("ps -o comm= -p #{Shellwords.escape(pid)} 2>/dev/null || true").to_s.strip
        name.empty? ? " (pid #{pid} holds #{LOCK_FILE})" : " (#{name}, pid #{pid}, holds #{LOCK_FILE})"
      rescue Odysseus::Error
        ''
      end
    end
  end
end
```

- [ ] **Step 4: Run them and watch them pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/docker_apt_spec.rb && bundle exec rubocop`
Expected: 10 examples, 0 failures; RuboCop clean (84 files now).

- [ ] **Step 5: Mutation check**

| Mutation | Example that must fail |
|---|---|
| `tee` → `tee -a` in `write_sources` | `writes the sources file whole, through a tee that is itself elevated` |
| `@escalation.elevate("tee ...")` → `"tee ..."` (writer not elevated) | same example — the expected string contains `sudo -n tee` |
| `curl -fsSL ... -o KEYRING` → `curl -fsSL ... > KEYRING` | `writes the keyring with curl, so the file is opened by the elevated process` |
| `arch` hardcoded to `'amd64'` | `takes the architecture from the host rather than assuming amd64` |
| Drop the second `apt('update')` | `refreshes the package lists after adding the repository, not only before` |
| Drop `env DEBIAN_FRONTEND=noninteractive` | `runs apt non-interactively and with a bounded wait for the dpkg lock` |
| `LOCK_TIMEOUT` 300 → 30 | same example (it pins the literal `300`) |
| `PACKAGES` reduced to `%w[docker-ce]` | `installs the plugins, not only the daemon` |
| `lock_holder_note` returns `''` unconditionally | `names the process holding the dpkg lock when apt times out` |
| The blank-codename guard removed | `refuses rather than building a repository line with a blank codename` |
| *(none)* | `does not try to repair an apt state it did not create` — a forward-looking guard with no mutation, by design. Listed so its absence is deliberate rather than an oversight; do not invent one for it. |

Run each, confirm the named example fails, revert. Report the failure message for each.

- [ ] **Step 6: Commit**

```bash
git add odysseus-core/lib/odysseus/setup/docker_apt.rb odysseus-core/spec/odysseus/setup/docker_apt_spec.rb
git commit -m "Add Setup::DockerApt, the install from Docker's apt repository"
```

---

### Task 3: Drive it from `Preparer#docker_step`

**Files:**
- Modify: `odysseus-core/lib/odysseus/setup/preparer.rb`
- Test: `odysseus-core/spec/odysseus/setup/preparer_spec.rb`

**Interfaces:**
- Consumes: `DockerApt.new(ssh:, escalation:, codename:)` and `#install!` (Task 2).
- Produces: `docker_step` returning `:ok` (already present), `:changed` (installed), or `:fail` (install raised, or the daemon still doesn't answer).

- [ ] **Step 1: Write the failing tests**

Add to `odysseus-core/spec/odysseus/setup/preparer_spec.rb`. The existing healthy fixture already answers `docker info` with a version, so the install never runs there — that is the `:ok` path and needs no new example beyond what exists.

```ruby
  # The three docker outcomes. The fixture answers `docker info` with a
  # failure first and a version second, because that is what a real install
  # looks like from the outside: the same probe, a different answer.
  context 'when the host has no docker' do
    def docker_answers(second_probe:)
      probes = ["Cannot connect to the Docker daemon\n", second_probe]
      {
        /docker info/ => -> { probes.shift },
        /apt-get/ => '',
        /dpkg --print-architecture/ => "amd64\n",
        /install -m 0755 -d/ => '',
        /curl -fsSL/ => '',
        /chmod a\+r/ => '',
        /tee .*docker\.list/ => ''
      }
    end

    it 'installs it and reports what it changed' do
      preparer, commands = build(answers: healthy.merge(docker_answers(second_probe: "29.1.3\n")))

      result = preparer.prepare.find { |r| r.step == :docker }

      expect(result.status).to eq(:changed)
      expect(result.detail).to include('29.1.3')
      expect(commands).to include(a_string_matching(/apt-get.*install -y docker-ce/))
    end

    it 'fails when the daemon still does not answer after installing' do
      preparer, = build(
        answers: healthy.merge(docker_answers(second_probe: "Cannot connect to the Docker daemon\n"))
      )

      result = preparer.prepare.find { |r| r.step == :docker }

      expect(result.status).to eq(:fail)
      expect(result.detail).to match(/installed/i)
    end

    # The specific pattern goes FIRST: the harness takes the first key that
    # matches, so appending this would let docker_answers' general `/apt-get/`
    # answer it and the failure would never fire.
    it 'reports the install failing without attempting the steps after it' do
      answers = { /apt-get .*install -y docker-ce/ => Odysseus::SSHCommandError.new('exit status 100') }
                .merge(healthy)
                .merge(docker_answers(second_probe: "29.1.3\n"))
      preparer, commands = build(answers: answers)

      results = preparer.prepare

      expect(results.last.step).to eq(:docker)
      expect(results.last.status).to eq(:fail)
      expect(commands).not_to include(a_string_matching(/useradd/))
    end

    # The codename comes from the host's os-release, and os-release is read
    # once for both the distro gate and this.
    #
    # `wonderfowl` is deliberately not a real Ubuntu codename. A fixture using
    # `noble` could not tell a genuine read from an implementation that
    # hardcoded the codename of the release it was written against -- the
    # fixture-too-uniform defect this project keeps shipping. A synthetic value
    # cannot coincide with anything the implementation might hardcode.
    it 'builds the repository line from the host os-release codename' do
      answers = healthy.merge(docker_answers(second_probe: "29.1.3\n"))
      answers[/os-release/] = "ID=ubuntu\nVERSION_ID=\"24.04\"\nVERSION_CODENAME=wonderfowl\n"
      preparer, commands = build(answers: answers)

      preparer.prepare

      expect(commands.grep(%r{cat /etc/os-release}).size).to eq(1)
      expect(commands.find { |c| c.include?('docker.list') }).to include(' wonderfowl stable')
    end
  end
```

**The `healthy` fixture has no `VERSION_CODENAME` today** — it is `"ID=ubuntu\nVERSION_ID=\"24.04\"\n"` at `preparer_spec.rb:76`. Add `VERSION_CODENAME=noble` to it, so the install path in the other three examples has a codename to work with. Note the helper is `healthy(user:, home:)`, a method, not a `let`.

The recording double answers with values, not lambdas, so add lambda support to `build`'s `execute` stub: after resolving `answer`, `answer = answer.call if answer.respond_to?(:call)`.

- [ ] **Step 2: Run them and watch them fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/setup/preparer_spec.rb`
Expected: FAIL — the first example reports `:fail` with "docker is required", since nothing installs yet.

- [ ] **Step 3: Implement**

Replace `#docker_step` in `preparer.rb`:

```ruby
      # Check, then install, then check again. The second probe is the only
      # thing that decides success: apt exiting 0 says a package was unpacked,
      # not that a daemon answers, and it is the daemon every deploy needs.
      def docker_step
        version = docker_version
        return Result.new(step: :docker, status: :ok, detail: "docker #{version}") if version

        DockerApt.new(ssh: @ssh, escalation: @escalation, codename: read_os_release['VERSION_CODENAME']).install!

        version = docker_version
        unless version
          return Result.new(
            step: :docker, status: :fail,
            detail: 'installed docker from apt, but its daemon still does not answer. ' \
                    'The host may need a reboot, or the daemon may have failed to start.'
          )
        end

        Result.new(step: :docker, status: :changed, detail: "installed docker #{version}")
      end

      # @return [String, nil] the running daemon's version, or nil if it does
      #   not answer -- which does not distinguish "not installed" from
      #   "installed, stopped", and does not need to: both are a host without
      #   a usable Docker until this step has run.
      def docker_version
        output = @escalation.run("docker info --format '{{.ServerVersion}}' 2>&1 || true").to_s.strip
        output.match?(/\A\d+\./) ? output : nil
      end
```

Memoize `#read_os_release` so the codename costs nothing extra — `distro_step` has already read it by the time this runs:

```ruby
      def read_os_release
        @read_os_release ||= begin
          raw = @ssh.execute('cat /etc/os-release 2>/dev/null || true').to_s

          raw.lines.each_with_object({}) do |line, acc|
            key, value = line.strip.split('=', 2)
            next if key.nil? || value.nil?

            acc[key] = value.delete('"')
          end
        end
      end
```

Update the class comment — it currently says *"Docker is checked for, never installed: a plan later than this one adds that. A host without it is refused rather than half-prepared."* Replace with:

```ruby
    # Docker is installed from Docker's own apt repository when the host does
    # not have it (see DockerApt); a host whose daemon still does not answer
    # afterwards fails the step rather than being handed back half-prepared.
```

- [ ] **Step 4: Run the full core suite**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: **707/0** (690 baseline + 3 from Task 1 + 10 from Task 2 + 4 here), 84 files clean. If your count differs because you added an example, say so and report the number you measured — do not adjust the number to match a guess.

- [ ] **Step 5: Mutation check**

| Mutation | Example that must fail |
|---|---|
| Return `:changed` without the second `docker_version` probe | `fails when the daemon still does not answer after installing` |
| Report `:ok` instead of `:changed` after installing | `installs it and reports what it changed` |
| `codename: 'noble'` hardcoded instead of read from os-release | `builds the repository line from the host os-release codename` — its fixture uses the synthetic `wonderfowl`, so a hardcode of any real codename is distinguishable |
| Drop the memoization on `read_os_release` | `builds the repository line from the host os-release codename` (the `.size).to eq(1)` assertion) |
| `rescue Odysseus::SetupError` in `run_step` widened to `rescue StandardError` | *None — do not add this row.* `run_step` already catches only `SetupError` and `DockerApt` raises exactly that; there is no mutation here worth naming. |

The third row is the important one: **verify the fixture's codename differs from any value hardcoded in the implementation**, or the example cannot distinguish the two. This is the defect class this project keeps shipping.

Run each, confirm the named example fails, revert.

- [ ] **Step 6: Commit**

```bash
git add odysseus-core/lib/odysseus/setup/preparer.rb odysseus-core/spec/odysseus/setup/preparer_spec.rb
git commit -m "Install docker when the host has none, instead of refusing"
```

---

### Task 4: Invert every claim that says setup will not install Docker

Phase 3a shipped documentation stating the opposite of what now ships. The spec names one of these lines explicitly: *"`odysseus-cli/README.md:670` ('your target servers only need Docker installed') changes in the phase that makes it true, not before."* This is that phase.

**Files:**
- Modify: `odysseus-cli/README.md`
- Modify: `odysseus-cli/CHANGELOG.md`
- Modify: `odysseus-core/CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Find every claim**

Run and record the output:

```bash
grep -rn -i "must already be installed\|does not install Docker\|only need\|daemon did not answer\|daemon does not answer\|refuses a host" odysseus-cli/README.md odysseus-cli/CHANGELOG.md odysseus-core/CHANGELOG.md
grep -rn "odysseus setup" odysseus-core/lib odysseus-cli/lib
```

The second grep matters more than the first. A previous phase shipped a user-facing string naming a command that did not exist; every hit here is a string a user reads, and `preparer.rb`'s docker refusal detail is one of them.

Known sites, all of which must change:
- `odysseus-cli/README.md` — the `**Docker's daemon must already be reachable.**` paragraph in `### setup` (~line 287)
- `odysseus-cli/README.md` — the `ssh` section's "it does not install Docker itself, which still has to be there first" (~line 749)
- `odysseus-cli/README.md` — "Your target servers only need **Docker** installed" (~line 822), the line the spec names
- `odysseus-cli/CHANGELOG.md:19` — "It refuses a host whose Docker daemon does not…"
- `odysseus-core/CHANGELOG.md:27` — "a host whose Docker daemon does not answer is refused, naming…"

- [ ] **Step 2: Rewrite them**

The `### setup` section must now say:

- Docker is installed from **Docker's official apt repository** when the host doesn't have it, following Docker's own published instructions.
- The keyring and sources file are written **whole every run**, so an interrupted run leaves a stale file the next run replaces rather than a corrupt one.
- apt runs non-interactively with a **bounded wait for the dpkg lock** (300 seconds — long enough to outlast cloud-init and unattended-upgrades on a minutes-old host), and a timeout **names the process holding it**.
- Setup **does not repair an apt or dpkg state it did not create**. A host with a broken apt is reported, not fixed.
- The GPG key fingerprint is **not pinned**, matching Docker's own instructions — say why in one clause: pinning would turn Docker's key rotation into an outage.
- Success is decided by the daemon answering **after** the install, not by apt exiting zero.

Keep everything else in that section true and unchanged — in particular the Ubuntu 24.04/26.04 restriction, the setup-refuses/doctor-warns asymmetry, and the OpenTofu positioning, which this change makes *more* important rather than less: setup now does more to a host, and is still not a provisioning tool.

For the `ssh` section and line ~822, state what is now true: a target host needs a supported Ubuntu and SSH access; `odysseus setup` can install Docker, and a host prepared by a provisioning tool needs Docker present.

CHANGELOG entries under `## [Unreleased]` → `### Added` in both gems: `Odysseus::Setup::DockerApt` and the install in core; the behaviour change in the CLI. State plainly that `setup` no longer refuses a host without Docker.

- [ ] **Step 3: Verify no claim survives that the code contradicts**

Re-run both greps from Step 1. Every remaining hit must be true of what ships. Read `preparer.rb`'s and `docker_apt.rb`'s user-facing message strings and confirm the README describes the same behaviour, in the same terms.

- [ ] **Step 4: Both suites**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop` then the same in `odysseus-cli`.
Expected: core 707/0 and 84 files clean; cli 190/0 and 15 files clean. Docs-only changes, so any failure is a real signal.

- [ ] **Step 5: Commit**

```bash
git add odysseus-cli/README.md odysseus-cli/CHANGELOG.md odysseus-core/CHANGELOG.md
git commit -m "Document the Docker install, replacing the claim that setup refuses without it"
```

---

## Deliberately not in this plan

- **The deploy-log migration** — plan 3c. Its failure mode is silent loss of rollback history, which deserves its own plan and its own review. 3a and 3b merge without it.
- **Debian, or any non-Ubuntu distro.** Refused for lack of a host to test against.
- **Pinning the GPG key fingerprint.** Decided against above; revisit only with a story for key rotation.
- **`systemctl enable --now docker`.** Installing `docker-ce` from this repository enables and starts the unit through systemd on the cloud images this supports. The post-install probe is what decides success, so an explicit start would be an unverified extra command that hides a real failure.
- **Repairing a broken apt state**, retrying past the lock timeout, or removing a conflicting third-party Docker repository. All are "repair what we did not create".
- **`keys_step`'s non-repair of a pre-existing loose `~/.ssh`** — a known deferred item from 3a's review recorded in that plan's ledger. It lives in `preparer.rb`, which this plan touches, but it is behaviour change with its own risk and belongs with 3c or later. Do not fix it here.

## Definition of done

- `odysseus-core` 707/0 and RuboCop clean across 84 files; `odysseus-cli` 190/0 and clean across 15. (690 + 3 + 10 + 4; report the number you measure rather than the number written here.)
- Every mutation in the three tables run, failing the named example, and reverted.
- `grep -rn "odysseus setup" odysseus-core/lib odysseus-cli/lib` returns only strings true of what shipped.
- No claim anywhere in either README or CHANGELOG says setup refuses a host without Docker.
- Branch `feat/setup` carries 3a's 18 commits plus four more, unmerged.

## What the doubled suite cannot verify — for the acceptance run

The recording double answers commands by regex; it never runs a shell, and every defect on this branch that reached a real host was invisible to it. On the rebuilt host, confirm:

- The keyring lands readable and apt actually accepts the repository's signature — a wrong `signed-by` path fails only against real apt.
- `printf '%s\n' … | sudo -n tee` writes the sources file with the elevated half doing the open, under `--as ubuntu`.
- The lock wait behaves: run `setup` against a host while `unattended-upgrades` holds the lock, and confirm it waits rather than failing instantly, then names the holder if it times out.
- `docker info` answers **as the deploy user** in a fresh session after the group is added — the self-test's whole purpose.
- The install is genuinely idempotent: a second `setup` reports `:ok` for docker and issues no apt command at all.
