# `odysseus doctor` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tell an operator, read-only, whether a host is configured for odysseus to deploy to it as the user their config names — before a deploy finds out the hard way.

**Architecture:** A new core class `Odysseus::HostVerifier` runs a fixed list of checks over one SSH connection and returns structured results; a new `odysseus doctor` command renders them per host and sets the exit code. Nothing is written to the host, and nothing is repaired — this phase diagnoses only.

**Tech Stack:** Ruby 3.2+ (developed on 4.0.6), Zeitwerk autoloading, RSpec with `verify_partial_doubles` and `config.warnings = true`, RuboCop.

**Spec:** `docs/specs/2026-08-16-user-model-and-setup.md` — phase 2 of its Phasing section. Read *Verified ground truth*, *Host state*, *What `setup` is for, and what it is not*, and the `odysseus doctor` paragraph before starting. Note the spec's filename still says `setup`: it covers both this diagnostic and the later bootstrap.

## Global Constraints

- Ruby `>= 3.2.0` (gemspec floor); developed against 4.0.6.
- **Read-only. Nothing on the host is created, modified or removed** — not a directory, not a file, not a container. A check that needs to write to learn something must instead infer it, or report that it cannot tell.
- **Every check runs as `ssh.user`**, the deploy identity from the config. Verifying as root would report a host as healthy that the deploy user cannot use, which is the whole failure this command exists to catch.
- **Caddy's directory is deliberately NOT checked.** It does not exist until the first deploy starts Caddy, so checking for it would report a correctly configured host that has not deployed yet as broken. The spec says so explicitly; do not add it.
- The supported distros are **Ubuntu 26.04 and 24.04**, named explicitly rather than computed, so supporting a new LTS is a deliberate edit with a tested host behind it.
- Every spec must be verified against a deliberate mutation of the code under test (`CONTRIBUTING.md`). A spec that passes when its code is broken is not a spec.
- **Do not edit `.rubocop_todo.yml`** in either gem — they are debt snapshots.
- Both suites and RuboCop stay green. Baselines: odysseus-core **604 examples / 0 failures / 75 files clean**; odysseus-cli **156 / 0 / 13 files clean**.
- Work on branch `feat/doctor`, branched from `trunk`. Do not merge.
- Commit messages explain *why*, matching `git log --oneline -12`. No "Generated with Claude Code" trailers, no Co-Authored-By lines.

## File Structure

| File | Responsibility |
| --- | --- |
| `odysseus-core/lib/odysseus/host_verifier.rb` | **New.** Runs the checks over one connection, returns `Result` values. Knows nothing about rendering or exit codes. |
| `odysseus-core/spec/odysseus/host_verifier_spec.rb` | **New.** |
| `odysseus-cli/lib/odysseus/cli/cli.rb` | **Modify.** Add `doctor`, which renders results per host and sets the exit code. |
| `odysseus-cli/bin/odysseus` | **Modify.** Dispatch `doctor` and document it in help. |
| `odysseus-cli/spec/odysseus/cli/cli_spec.rb` | **Modify.** |
| `odysseus-cli/spec/bin_spec.rb` | **Modify.** Dispatch coverage, as every other verb has. |

Zeitwerk maps `lib/odysseus/host_verifier.rb` to `Odysseus::HostVerifier` — no `require` needed.

---

### Task 1: `HostVerifier` and its checks

**Files:**
- Create: `odysseus-core/lib/odysseus/host_verifier.rb`
- Create: `odysseus-core/spec/odysseus/host_verifier_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::Deployer::SSH#execute` and `#user`; `Odysseus::HostPaths#base`, `#service_dir(service)`, `#legacy_base`.
- Produces: `Odysseus::HostVerifier.new(ssh:, config:)` with `#verify` returning `Array<HostVerifier::Result>`, and `HostVerifier::Result = Data.define(:check, :status, :detail)` where `status` is one of `:ok`, `:warn`, `:fail`. Task 2 renders exactly these.

- [ ] **Step 1: Write the failing spec**

Create `odysseus-core/spec/odysseus/host_verifier_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Odysseus::HostVerifier do
  # A recording connection: `answers` maps a regex to what the host replies.
  # Anything unmatched raises, so a check that runs a command this spec did not
  # anticipate fails loudly rather than silently reading ''.
  def ssh_double(user: 'odysseus', home: '/home/odysseus', answers: {})
    ssh = instance_double(Odysseus::Deployer::SSH, user: user)
    allow(ssh).to receive(:execute) do |cmd|
      next "#{home}\n" if cmd == 'echo $HOME'

      match = answers.keys.find { |pattern| cmd.match?(pattern) }
      raise "spec did not anticipate: #{cmd}" unless match

      answers[match]
    end
    ssh
  end

  let(:config) { { service: 'myapp', ssh: { user: 'odysseus' } } }

  # Ubuntu 24.04's real /etc/os-release keys, trimmed to what is read.
  UBUNTU_2404 = "ID=ubuntu\nVERSION_ID=\"24.04\"\nID_LIKE=debian\n".freeze
  UBUNTU_2604 = "ID=ubuntu\nVERSION_ID=\"26.04\"\nID_LIKE=debian\n".freeze
  DEBIAN_12   = "ID=debian\nVERSION_ID=\"12\"\n".freeze

  def healthy_answers(os: UBUNTU_2404)
    {
      /os-release/ => os,
      /docker info/ => "Server Version: 29.1.3\n",
      /\bid -nG\b/ => "odysseus docker\n",
      /test -w/ => "writable\n",
      /test -e/ => "absent\n"
    }
  end

  def verify(ssh)
    described_class.new(ssh: ssh, config: config).verify
  end

  def result_for(results, check)
    results.find { |r| r.check == check } or raise "no result for #{check.inspect}"
  end

  describe 'a correctly configured host' do
    it 'passes every check' do
      results = verify(ssh_double(answers: healthy_answers))

      expect(results.map(&:status).uniq).to eq([:ok])
    end

    it 'reports one result per check, in a stable order' do
      results = verify(ssh_double(answers: healthy_answers))

      expect(results.map(&:check))
        .to eq(%i[distro docker docker_group state_dir deploy_log])
    end
  end

  describe 'the distro check' do
    it 'accepts the two supported LTS releases' do
      %w[24.04 26.04].each do |version|
        os = version == '24.04' ? UBUNTU_2404 : UBUNTU_2604
        results = verify(ssh_double(answers: healthy_answers(os: os)))
        expect(result_for(results, :distro).status).to eq(:ok)
      end
    end

    # A warning, not a failure: odysseus deploys to any host with Docker. Only
    # `setup`'s installer needs apt, and this command is not that.
    it 'warns rather than fails on an unsupported distro, and names it' do
      results = verify(ssh_double(answers: healthy_answers(os: DEBIAN_12)))
      result = result_for(results, :distro)

      expect(result.status).to eq(:warn)
      expect(result.detail).to include('debian')
    end

    it 'warns on an Ubuntu that is not one of the supported releases' do
      old = "ID=ubuntu\nVERSION_ID=\"20.04\"\n"
      results = verify(ssh_double(answers: healthy_answers(os: old)))

      expect(result_for(results, :distro).status).to eq(:warn)
      expect(result_for(results, :distro).detail).to include('20.04')
    end
  end

  describe 'the docker check' do
    it 'fails when the daemon does not answer for this user' do
      answers = healthy_answers.merge(/docker info/ => "permission denied\n")
      results = verify(ssh_double(answers: answers))

      expect(result_for(results, :docker).status).to eq(:fail)
    end
  end

  describe 'the docker group check' do
    it 'fails when the deploy user is not in the docker group' do
      answers = healthy_answers.merge(/\bid -nG\b/ => "odysseus users\n")
      results = verify(ssh_double(answers: answers))

      result = result_for(results, :docker_group)
      expect(result.status).to eq(:fail)
      expect(result.detail).to include('docker')
    end

    # root needs no group membership, and reporting a missing one would be a
    # false alarm on every root install — which is still the default.
    it 'does not require the group of root' do
      root_config = { service: 'myapp', ssh: { user: 'root' } }
      answers = healthy_answers.merge(/\bid -nG\b/ => "root\n")
      ssh = ssh_double(user: 'root', answers: answers)

      results = described_class.new(ssh: ssh, config: root_config).verify

      expect(result_for(results, :docker_group).status).to eq(:ok)
    end
  end

  describe 'the state directory check' do
    it 'names the directory it checked, so the reader can see which it was' do
      results = verify(ssh_double(answers: healthy_answers))

      expect(result_for(results, :state_dir).detail).to include('/home/odysseus/.odysseus')
    end

    it 'fails when the deploy user cannot write there' do
      answers = healthy_answers.merge(/test -w/ => "not writable\n")
      results = verify(ssh_double(answers: answers))

      expect(result_for(results, :state_dir).status).to eq(:fail)
    end
  end

  describe 'the deploy log check' do
    it 'reports where the log will be written' do
      results = verify(ssh_double(answers: healthy_answers))
      result = result_for(results, :deploy_log)

      expect(result.status).to eq(:ok)
      expect(result.detail).to include('/home/odysseus/.odysseus/myapp/deploys.log')
    end

    # The migration case: a host that used to deploy as root has history the
    # deploy user can read but never write. Worth saying out loud, because
    # losing it is silent — rollback simply offers fewer versions.
    it 'warns when root-era history exists at the legacy path' do
      answers = healthy_answers.merge(/test -e/ => "present\n")
      results = verify(ssh_double(answers: answers))
      result = result_for(results, :deploy_log)

      expect(result.status).to eq(:warn)
      expect(result.detail).to include('/var/lib/odysseus/myapp/deploys.log')
    end

    # For root the two paths are the same file, so "legacy history exists"
    # would fire on every healthy root host.
    it 'does not warn for root, whose log is already at that path' do
      root_config = { service: 'myapp', ssh: { user: 'root' } }
      answers = healthy_answers.merge(/test -e/ => "present\n")
      ssh = ssh_double(user: 'root', answers: answers)

      results = described_class.new(ssh: ssh, config: root_config).verify

      expect(result_for(results, :deploy_log).status).to eq(:ok)
    end
  end

  describe 'reading nothing and writing nothing' do
    it 'issues no command that could change the host' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'odysseus')
      allow(ssh).to receive(:execute) do |cmd|
        commands << cmd
        next "/home/odysseus\n" if cmd == 'echo $HOME'

        pattern = healthy_answers.keys.find { |p| cmd.match?(p) }
        raise "spec did not anticipate: #{cmd}" unless pattern

        healthy_answers[pattern]
      end

      described_class.new(ssh: ssh, config: config).verify

      expect(commands).to all(satisfy do |cmd|
        !cmd.match?(/\b(mkdir|touch|rm|chmod|chown|docker run|docker rm|useradd|usermod)\b/)
      end)
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/host_verifier_spec.rb`
Expected: FAIL — `uninitialized constant Odysseus::HostVerifier`.

- [ ] **Step 3: Write `HostVerifier`**

Create `odysseus-core/lib/odysseus/host_verifier.rb`:

```ruby
# lib/odysseus/host_verifier.rb

require 'shellwords'

module Odysseus
  # Read-only diagnosis of whether one host is ready for odysseus to deploy to
  # it AS THE USER THE CONFIG NAMES.
  #
  # That last part is the point. Verifying as root would pass on a host the
  # deploy user cannot use, which is the failure this exists to catch — a deploy
  # that dies at the first container start because a directory is not writable.
  #
  # Nothing here writes to the host. A check that would need to write in order
  # to learn something reports that it cannot tell instead.
  #
  # Caddy's data directory is deliberately absent from these checks: it does not
  # exist until the first deploy starts Caddy, so a correctly configured host
  # that has not deployed yet would be reported broken.
  class HostVerifier
    # Named explicitly rather than computed, so supporting a new LTS is a
    # deliberate edit with a tested host behind it, not something that becomes
    # true on a date.
    SUPPORTED_UBUNTU = %w[24.04 26.04].freeze
    ROOT = 'root'.freeze

    # @param check [Symbol] which check this is
    # @param status [Symbol] :ok, :warn or :fail
    # @param detail [String] one line a reader can act on
    Result = Data.define(:check, :status, :detail)

    def initialize(ssh:, config:)
      @ssh = ssh
      @config = config
    end

    # @return [Array<Result>] one per check, in a stable order
    def verify
      [distro, docker, docker_group, state_dir, deploy_log]
    end

    private

    def root?
      @ssh.user == ROOT
    end

    def host_paths
      @host_paths ||= Odysseus::HostPaths.new(@ssh)
    end

    def distro
      os = read_os_release
      id = os['ID']
      version = os['VERSION_ID']

      if id == 'ubuntu' && SUPPORTED_UBUNTU.include?(version)
        Result.new(check: :distro, status: :ok, detail: "ubuntu #{version}")
      else
        # A warning, not a failure: deploys work on any host with Docker. Only
        # `odysseus setup`'s installer is apt-specific.
        Result.new(
          check: :distro, status: :warn,
          detail: "#{id || 'unknown'} #{version}".strip +
                  " — deploys work here, but `odysseus setup` supports only ubuntu #{SUPPORTED_UBUNTU.join(', ')}"
        )
      end
    end

    def docker
      output = @ssh.execute("docker info --format '{{.ServerVersion}}' 2>&1 || true")
      version = output.to_s.strip

      if version.match?(/\A\d+\./)
        Result.new(check: :docker, status: :ok, detail: "docker #{version}")
      else
        Result.new(
          check: :docker, status: :fail,
          detail: "the docker daemon did not answer as #{@ssh.user}: #{version.lines.first.to_s.strip}"
        )
      end
    end

    def docker_group
      # root does not need the group, and saying it is missing would be a false
      # alarm on every root install — still the default.
      return Result.new(check: :docker_group, status: :ok, detail: 'not needed for root') if root?

      groups = @ssh.execute("id -nG #{Shellwords.escape(@ssh.user)} 2>/dev/null || true").to_s.split

      if groups.include?('docker')
        Result.new(check: :docker_group, status: :ok, detail: "#{@ssh.user} is in the docker group")
      else
        Result.new(
          check: :docker_group, status: :fail,
          detail: "#{@ssh.user} is not in the docker group (has: #{groups.join(' ')})"
        )
      end
    end

    def state_dir
      dir = host_paths.base
      # Check the nearest existing ancestor: the directory itself may legitimately
      # not exist yet on a host that has never deployed, and creating it to find
      # out is exactly what this command must not do.
      probe = Shellwords.escape(dir)
      output = @ssh.execute(
        "d=#{probe}; while [ ! -e \"$d\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " \
        'if [ -w "$d" ]; then echo writable; else echo "not writable:$d"; fi'
      ).to_s.strip

      if output == 'writable'
        Result.new(check: :state_dir, status: :ok, detail: "#{dir} is writable")
      else
        Result.new(
          check: :state_dir, status: :fail,
          detail: "#{dir} is not writable by #{@ssh.user} (#{output.split(':').last} is not)"
        )
      end
    end

    def deploy_log
      path = File.join(host_paths.service_dir(@config[:service]), Odysseus::DeployLog::FILENAME)
      legacy = File.join(host_paths.legacy_base, @config[:service], Odysseus::DeployLog::FILENAME)

      return Result.new(check: :deploy_log, status: :ok, detail: path) if root? || legacy == path

      present = @ssh.execute("test -e #{Shellwords.escape(legacy)} && echo present || echo absent").to_s.strip

      if present == 'present'
        # Losing this is silent — rollback just offers fewer versions — so it is
        # worth a warning rather than a note.
        Result.new(
          check: :deploy_log, status: :warn,
          detail: "#{path}; root-era history still at #{legacy}, readable but not writable by #{@ssh.user}"
        )
      else
        Result.new(check: :deploy_log, status: :ok, detail: path)
      end
    end

    def read_os_release
      raw = @ssh.execute('cat /etc/os-release 2>/dev/null || true').to_s

      raw.lines.each_with_object({}) do |line, acc|
        key, value = line.strip.split('=', 2)
        next if key.nil? || value.nil?

        acc[key] = value.delete('"')
      end
    end
  end
end
```

- [ ] **Step 4: Run the spec**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/host_verifier_spec.rb`
Expected: PASS, 15 examples.

- [ ] **Step 5: Verify the specs have teeth**

Run each mutation, confirm the named example fails, revert it.

| Mutation | Must fail |
| --- | --- |
| `SUPPORTED_UBUNTU` → `%w[24.04]` | `accepts the two supported LTS releases` |
| distro `:warn` → `:fail` | `warns rather than fails on an unsupported distro, and names it` |
| `docker` status always `:ok` | `fails when the daemon does not answer for this user` |
| `docker_group` skips the `root?` early return | `does not require the group of root` |
| `groups.include?('docker')` → `true` | `fails when the deploy user is not in the docker group` |
| `state_dir` status always `:ok` | `fails when the deploy user cannot write there` |
| `deploy_log` skips the `root?` early return | `does not warn for root, whose log is already at that path` |
| `deploy_log` never checks `legacy` | `warns when root-era history exists at the legacy path` |
| `verify` returns the checks in a different order | `reports one result per check, in a stable order` |
| add a `mkdir -p` to `state_dir` | `issues no command that could change the host` |

- [ ] **Step 6: Full suite and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Expected: 619 examples, 0 failures; 76 files, no offenses.

- [ ] **Step 7: Commit**

```bash
git add odysseus-core/lib/odysseus/host_verifier.rb \
        odysseus-core/spec/odysseus/host_verifier_spec.rb
git commit
```

The message should say why the checks run as the deploy user rather than root, and why the distro check warns rather than fails.

---

### Task 2: `odysseus doctor`

**Files:**
- Modify: `odysseus-cli/lib/odysseus/cli/cli.rb`
- Modify: `odysseus-cli/bin/odysseus`
- Modify: `odysseus-cli/spec/odysseus/cli/cli_spec.rb`
- Modify: `odysseus-cli/spec/bin_spec.rb`

**Interfaces:**
- Consumes: `Odysseus::HostVerifier.new(ssh:, config:).verify` returning `Array<Result>` with `#check`, `#status` (`:ok`/`:warn`/`:fail`) and `#detail`, from Task 1. Also `Executor#host_roles` (`odysseus-core/lib/odysseus/deployer/executor.rb:427`), which returns `{ host => [roles] }` for every unique host in the config.
- Produces: no new public Ruby API. A new CLI verb.

- [ ] **Step 1: Write the failing specs**

Add to `odysseus-cli/spec/odysseus/cli/cli_spec.rb`, following the file's existing style of stubbing `Odysseus::Deployer::SSH.new`:

```ruby
  describe '#doctor' do
    let(:ok)   { Odysseus::HostVerifier::Result.new(check: :docker, status: :ok, detail: 'docker 29.1.3') }
    let(:warn) { Odysseus::HostVerifier::Result.new(check: :distro, status: :warn, detail: 'debian 12 — deploys work here') }
    let(:bad)  { Odysseus::HostVerifier::Result.new(check: :state_dir, status: :fail, detail: '/home/odysseus/.odysseus is not writable') }

    def run_setup(results, options = {})
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      verifier = instance_double(Odysseus::HostVerifier, verify: results)
      allow(Odysseus::HostVerifier).to receive(:new).and_return(verifier)

      cli.doctor({ config: fixture_path('deploy.yml') }.merge(options))
    end

    it 'reports each check and exits zero when all pass' do
      expect { run_setup([ok]) }.not_to raise_error
    end

    it 'exits non-zero when any check fails' do
      expect { run_setup([ok, bad]) }.to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    # A warning is information, not a broken host: deploys work on a distro
    # `setup` cannot bootstrap.
    it 'exits zero when the worst result is a warning' do
      expect { run_setup([ok, warn]) }.not_to raise_error
    end

    it 'names the failing check and its detail, so the reader can act' do
      output = capture_output { run_setup([ok, bad]) rescue SystemExit }

      expect(output).to include('state_dir')
      expect(output).to include('not writable')
    end

    it 'verifies every host in the config, not only the first' do
      hosts = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        hosts << args[:host]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus')
      end
      allow(Odysseus::HostVerifier).to receive(:new)
        .and_return(instance_double(Odysseus::HostVerifier, verify: [ok]))

      cli.doctor(config: fixture_path('deploy.yml'))

      expect(hosts.uniq.size).to be >= 1
      expect(hosts).to eq(hosts.uniq) # each host visited once, not once per role
    end

    it 'closes every connection it opens, even when a check fails' do
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::HostVerifier).to receive(:new)
        .and_return(instance_double(Odysseus::HostVerifier, verify: [bad]))

      begin
        cli.doctor(config: fixture_path('deploy.yml'))
      rescue SystemExit
        nil
      end

      expect(ssh).to have_received(:close).at_least(:once)
    end
  end
```

Adapt `capture_output` and `fixture_path` to whatever the file already uses for those — read the top of `cli_spec.rb` first and follow it rather than introducing new helpers.

Add to `odysseus-cli/spec/bin_spec.rb`, matching how that file drives the real executable for other verbs:

```ruby
  it 'dispatches doctor' do
    output, status = run_odysseus('doctor', '--config', 'nope.yml')

    # Reaches the command and fails on the missing config, rather than printing
    # the global usage banner or raising NoMethodError.
    expect(output).not_to match(/Usage: odysseus <command>/)
    expect(output).not_to include('NoMethodError')
    expect(status).not_to eq(0)
  end

  it 'needs no server argument for doctor' do
    output, = run_odysseus('doctor', '--config', 'nope.yml')

    expect(output).not_to match(/Server (name|argument) required/i)
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd odysseus-cli && bundle exec rspec`
Expected: FAIL — `cli.doctor` is undefined, and the bin examples see the usage banner.

- [ ] **Step 3: Add the command to the CLI**

In `odysseus-cli/lib/odysseus/cli/cli.rb`, add `setup` near `status` (which it resembles — per-host, read-only). Follow that method's shape: load config, header, connect, work in a `begin`, `ensure` the connection closes.

```ruby
      # Read-only diagnosis of every host in the config, as the user the config
      # names. Its own command rather than a mode of `setup`, because it lasts:
      # "is this host usable by odysseus as my deploy user" is worth asking on
      # any host, including one a provisioning tool built.
      def doctor(options = {})
        config = load_config(options[:config] || 'deploy.yml')

        @ui.header 'Odysseus Doctor'
        @ui.info 'Service', config[:service]
        @ui.info 'Deploy user', config[:ssh][:user]
        @ui.blank

        worst = :ok

        executor = Odysseus::Deployer::Executor.new(options[:config] || 'deploy.yml')

        executor.host_roles.each_key do |host|
          @ui.section host
          ssh = connect_to_server(host, config)

          begin
            Odysseus::HostVerifier.new(ssh: ssh, config: config).verify.each do |result|
              worst = escalate(worst, result.status)
              render_check(result)
            end
          ensure
            ssh.close
          end
        end

        @ui.blank
        case worst
        when :fail then exit 1
        when :warn then @ui.warn 'Deploys will work, but read the warnings above.'
        else @ui.success 'This host is ready.'
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end
```

And the two private helpers, beside the other private methods:

```ruby
      def render_check(result)
        line = "#{result.check}: #{result.detail}"

        case result.status
        when :ok then @ui.step_ok line
        when :warn then @ui.warn line
        else @ui.step_fail line
        end
      end

      # :fail beats :warn beats :ok, so one bad check decides the exit code
      # however many good ones surround it.
      def escalate(current, status)
        order = { ok: 0, warn: 1, fail: 2 }
        order[status] > order[current] ? status : current
      end
```

There is no shared helper for this: `cli.rb` constructs `Odysseus::Deployer::Executor.new(config_file)` inline at each call site (lines 31, 82, 115, 310, 324), some passing `verbose:`. The code above follows that existing pattern rather than introducing a helper, since extracting one would touch five unrelated methods. `#host_roles` is public on `Executor` (`deployer/executor.rb:427`) and returns `{ host => [roles] }` for every unique host, which is why this visits a host once rather than once per role.

- [ ] **Step 4: Dispatch it**

In `odysseus-cli/bin/odysseus`, add to the `commands` hash (around line 36):

```ruby
    'doctor' => { method: :doctor, needs_server: false },
```

No new option is needed — `doctor` reads only `--config`, which the parser
already handles. Add it to `print_help`'s command list, worded so the reader knows what it does and does not do yet:

```ruby
  puts '  doctor                    Check that hosts are ready to deploy to (changes nothing)'
```

- [ ] **Step 5: Run the specs**

Run: `cd odysseus-cli && bundle exec rspec`
Expected: PASS.

- [ ] **Step 6: Verify the specs have teeth**

| Mutation | Must fail |
| --- | --- |
| `escalate` returns `current` always | `exits non-zero when any check fails` |
| treat `:warn` as `:fail` in the exit decision | `exits zero when the worst result is a warning` |
| break out of the host loop after the first host | `verifies every host in the config, not only the first` |
| remove the `ensure ssh.close` | `closes every connection it opens, even when a check fails` |
| `render_check` prints only the status, not the detail | `names the failing check and its detail, so the reader can act` |
| remove `'doctor'` from the `commands` hash | `dispatches doctor` |

- [ ] **Step 7: Both suites and RuboCop**

Run: `cd odysseus-core && bundle exec rspec && bundle exec rubocop`
Run: `cd ../odysseus-cli && bundle exec rspec && bundle exec rubocop`
Expected: core 619 / 0 and clean; cli 164 / 0 and clean.

- [ ] **Step 8: Commit**

```bash
git add odysseus-cli/lib/odysseus/cli/cli.rb odysseus-cli/bin/odysseus \
        odysseus-cli/spec/odysseus/cli/cli_spec.rb odysseus-cli/spec/bin_spec.rb
git commit
```

Say in the message why this is its own command rather than a mode of `setup` — the diagnostic lasts, the bootstrap is a trial convenience — and why a warning does not fail the command.

---

### Task 3: Document it

**Files:**
- Modify: `odysseus-cli/README.md`
- Modify: `odysseus-core/CHANGELOG.md`
- Modify: `odysseus-cli/CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Document the command in the README**

Add a `### doctor` section beside the other command sections. It must say:

- `odysseus doctor` checks every host in the config, read-only, **as the user `ssh.user` names** — and that this is the point, because a host that is fine for root can be unusable for a deploy user.
- **What it is for.** Preparing servers is not odysseus's job — that belongs to
  OpenTofu, Terraform or equivalent, which does it declaratively and at scale.
  `--verify` is the half that lasts: it answers whether a host is usable by
  odysseus as the configured user, which is worth asking however the host was
  prepared, and serves as the acceptance test for a tofu-built one. Say this
  plainly and point at provisioning tools; do not position odysseus as one.
- What each check reports: distro, docker reachable, docker group membership, state directory writable, deploy-log location.
- That an unsupported distro is a **warning**, not a failure: deploys work anywhere Docker does. Explain it that way without invoking a bootstrap — the next bullet forbids mentioning one, and an earlier draft of this bullet contradicted it.
- That Caddy's directory is deliberately not checked, because it does not exist until the first deploy.
- Nothing about `odysseus setup`, which does not exist. Do not describe a bootstrap as coming, or name a version.

Per `CONTRIBUTING.md`, a README that promises a feature the code lacks is a bug. Describe only `doctor`.

- [ ] **Step 2: Changelog entries**

`odysseus-core/CHANGELOG.md` under `## [Unreleased]` → `### Added`: `Odysseus::HostVerifier`, what it checks and that it writes nothing.

`odysseus-cli/CHANGELOG.md` under `## [Unreleased]` → `### Added`: `odysseus doctor`, what it checks, and that it changes nothing on the host.

- [ ] **Step 3: Check no doc contradicts this**

Run: `grep -rn "setup" odysseus-cli/README.md odysseus-core/README.md`
Every hit that describes an `odysseus setup` command must be corrected or removed — that command does not exist. The spec under `docs/` is a design record and stays as-is. Report what you found.

- [ ] **Step 4: Commit**

```bash
git add odysseus-cli/README.md odysseus-core/CHANGELOG.md odysseus-cli/CHANGELOG.md
git commit
```

---

## Deliberately not in this phase

- **No repair.** Nothing is created or fixed, even when the fix is obvious. That is phase 3, and a diagnostic that sometimes mutates is one nobody can run safely on a live host.
- **Caddy's directory is not checked**, per the spec: it does not exist until the first deploy starts Caddy.
- **The `odysseus` network is not checked.** `JobDeploy` and `Caddy::Client` both create it now, so its absence on a fresh host is not a fault.
- **No `setup.connect_as` handling.** That key belongs to the bootstrap, which connects as a different identity; `doctor` deliberately connects as the deploy user.

## Definition of done

- `odysseus-core` 619 examples / 0 failures, RuboCop clean; `odysseus-cli` 164 / 0, clean.
- Every mutation in the tables above was run, failed the named example, and was reverted.
- `odysseus doctor` run against a real host reports every check; run against a host whose deploy user lacks the docker group, it fails that check and exits non-zero.
- Branch `feat/doctor` with three commits, not merged.
