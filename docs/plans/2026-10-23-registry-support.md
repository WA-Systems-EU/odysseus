# Registry Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make registry mode work for a private registry — credentials from the encrypted secrets file, a host-side login confined to a throwaway docker config directory, and an explicit pull so a fetch failure is attributable.

**Architecture:** A `Registry::Credentials` value object resolves the credential from exactly one source. A `Registry::HostSession` creates a mode-700 temp directory on the host, logs in with `DOCKER_CONFIG` pointed at it, and removes it in an `ensure`. `Executor` and `DependencyManager` wrap their orchestrator calls in a session and pass its directory down; orchestrators pull explicitly before starting a container.

**Tech Stack:** Ruby >= 3.2, RSpec, RuboCop, net-ssh. No new gems.

**Spec:** `docs/specs/2026-10-23-registry-support-design.md`

## Global Constraints

- **`DOCKER_CONFIG=<dir>` env prefix, never `docker --config <dir>`.** `CommandRedaction::STDIN_PIPE` requires `docker\s+login` immediately after the pipe; `\S*` cannot span spaces, so `docker --config <dir> login` is **not redacted** and the password would print under `--debug`. The spec said `--config`; this plan corrects it.
- **The login command must be exactly `echo '<password>' | DOCKER_CONFIG=<dir> docker login <server> -u <user> --password-stdin`.** Any other shape loses redaction.
- **Every new orchestrator keyword argument must be optional with a default.** `executor.rb:374` passes `ssh:, config:, logger:, secrets_loader:` to sail plugins too, and `odysseus-sail-rolling` consumes that signature. A required argument breaks it.
- **Credentials never resolve through `Core::Environment`.** Its `secret_value` falls back to the deploy host's own environment; a host with a stray `REGISTRY_TOKEN` must not be able to authenticate a deploy. Use `Secrets::Loader#get` directly.
- **One session per role-host, not per host.** `run_deploy` opens and closes its SSH connection per role-host; a session cannot outlive its connection. The spec said "per host"; this plan corrects it.
- `bundle exec rake` in `odysseus-core` must pass (RSpec + RuboCop) at the end of every task. Line length limit 140.
- No version bump and no changelog date in these commits; releases are their own commit.
- Each new spec must be checked against a deliberate mutation of the code it covers, per this repo's practice.

---

### Task 1: Registry::Credentials and `password_secret` parsing

**Files:**
- Create: `odysseus-core/lib/odysseus/registry/credentials.rb`
- Modify: `odysseus-core/lib/odysseus/config/parser.rb:268-276` (`parse_registry`)
- Test: `odysseus-core/spec/odysseus/registry/credentials_spec.rb`
- Test: `odysseus-core/spec/odysseus/config/parser_spec.rb` (add `password_secret` cases)

**Interfaces:**
- Consumes: `Odysseus::Secrets::Loader#get(key)` returning `String` or `nil`; `Odysseus::Secrets::Loader#configured?`
- Produces: `Odysseus::Registry::Credentials.new(registry_config, secrets_loader:, env: ENV)` with `#server`, `#username`, `#password`, `#complete?`, `#configured?`. Later tasks construct it and read `#complete?` and the three readers.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/odysseus/registry/credentials_spec.rb
require 'spec_helper'

RSpec.describe Odysseus::Registry::Credentials do
  let(:loader) { instance_double(Odysseus::Secrets::Loader, configured?: true) }

  def creds(registry, env: {})
    described_class.new(registry, secrets_loader: loader, env: env)
  end

  describe 'password_secret' do
    it 'resolves the key from the encrypted file' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return('s3cr3t')
      c = creds({ server: 'ghcr.io', username: 'wa', password_secret: 'REGISTRY_TOKEN' })
      expect(c.password).to eq('s3cr3t')
    end

    # A silent fallback here authenticates the deploy with the wrong credential.
    it 'raises naming the key and the file when the secret is missing' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return(nil)
      c = creds({ server: 'ghcr.io', username: 'wa', password_secret: 'REGISTRY_TOKEN' },
                env: { 'ODYSSEUS_REGISTRY_PASSWORD' => 'ignored' })
      expect { c.password }.to raise_error(Odysseus::ConfigError, /REGISTRY_TOKEN/)
    end

    it 'never falls back to the env var when a secret key is named' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return(nil)
      c = creds({ server: 'ghcr.io', username: 'wa', password_secret: 'REGISTRY_TOKEN' },
                env: { 'ODYSSEUS_REGISTRY_PASSWORD' => 'from-env' })
      expect { c.password }.to raise_error(Odysseus::ConfigError)
    end
  end

  describe 'literal password' do
    it 'is still accepted' do
      expect(creds({ server: 'ghcr.io', username: 'wa', password: 'literal' }).password).to eq('literal')
    end
  end

  describe 'both sources set' do
    it 'raises rather than picking one' do
      c = creds({ server: 'ghcr.io', username: 'wa', password: 'literal', password_secret: 'REGISTRY_TOKEN' })
      expect { c.password }.to raise_error(Odysseus::ConfigError, /both/i)
    end
  end

  describe 'neither source set' do
    it 'reads ODYSSEUS_REGISTRY_PASSWORD, for CI' do
      c = creds({ server: 'ghcr.io', username: 'wa' }, env: { 'ODYSSEUS_REGISTRY_PASSWORD' => 'from-env' })
      expect(c.password).to eq('from-env')
    end

    it 'is incomplete with no password anywhere, which is public-image mode' do
      expect(creds({ server: 'ghcr.io', username: 'wa' }).complete?).to be false
    end
  end

  describe '#complete?' do
    it 'needs server, username and password' do
      expect(creds({ server: 'ghcr.io', username: 'wa', password: 'p' }).complete?).to be true
    end

    it 'is false without a username' do
      expect(creds({ server: 'ghcr.io', password: 'p' }).complete?).to be false
    end

    it 'is false for an empty registry config' do
      expect(creds({}).complete?).to be false
    end
  end

  describe '#configured?' do
    it 'is true when a server is set, which is what switches distribution' do
      expect(creds({ server: 'ghcr.io' }).configured?).to be true
    end

    it 'is false with no server' do
      expect(creds({}).configured?).to be false
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/registry/credentials_spec.rb`
Expected: FAIL with `NameError: uninitialized constant Odysseus::Registry::Credentials`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/odysseus/registry/credentials.rb

module Odysseus
  module Registry
    # The credential a deploy host needs to pull a private image.
    #
    # Resolved from exactly one source. Sources are not a cascade on purpose:
    # falling through from a named secret to an environment variable is how a
    # deploy authenticates with the wrong credential and reports success.
    #
    # Deliberately not routed through Core::Environment, whose secret_value
    # falls back to the deploy target's own environment -- a host that happens
    # to have REGISTRY_TOKEN set for an unrelated reason has no business
    # authenticating someone else's deploy.
    class Credentials
      ENV_VAR = 'ODYSSEUS_REGISTRY_PASSWORD'.freeze

      # @param registry [Hash] config[:registry]
      # @param secrets_loader [Odysseus::Secrets::Loader, nil]
      # @param env [Hash] the environment of the machine running odysseus,
      #   never the deploy host's
      def initialize(registry, secrets_loader:, env: ENV)
        @registry = registry || {}
        @secrets_loader = secrets_loader
        @env = env
      end

      def server = @registry[:server]
      def username = @registry[:username]

      # @raise [Odysseus::ConfigError] when both sources are set, or when a
      #   named secret is not in the file
      # @return [String, nil] nil means public-image mode, which is valid
      def password
        raise Odysseus::ConfigError, both_sources_message if literal && secret_key

        return from_secrets if secret_key
        return literal if literal

        value = @env[ENV_VAR]
        value unless value.nil? || value.empty?
      end

      # @return [Boolean] whether a server is configured at all, which is what
      #   switches distribution away from pussh
      def configured?
        !server.nil? && !server.to_s.empty?
      end

      # @return [Boolean] whether a host login is possible
      def complete?
        return false unless configured?
        return false if username.nil? || username.to_s.empty?

        pw = password
        !pw.nil? && !pw.empty?
      end

      private

      def literal = @registry[:password]
      def secret_key = @registry[:password_secret]

      def from_secrets
        value = @secrets_loader&.get(secret_key)
        raise Odysseus::ConfigError, missing_secret_message if value.nil? || value.to_s.empty?

        value.to_s
      end

      def missing_secret_message
        "registry.password_secret names '#{secret_key}', which is not in the secrets file. " \
          'Add it there, or set registry.password instead.'
      end

      def both_sources_message
        'registry has both password and password_secret set. Pick one: password_secret reads the ' \
          'encrypted secrets file, password is the literal value in deploy.yml.'
      end
    end
  end
end
```

- [ ] **Step 4: Run it and watch it pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/registry/credentials_spec.rb`
Expected: PASS, 11 examples

- [ ] **Step 5: Carry `password_secret` through the parser**

Add the failing parser test first:

```ruby
# append inside the existing registry describe in spec/odysseus/config/parser_spec.rb
it 'carries password_secret through' do
  config = described_class.new(write_config('registry' => {
                                              'server' => 'ghcr.io',
                                              'username' => 'wa',
                                              'password_secret' => 'REGISTRY_TOKEN'
                                            })).parse
  expect(config[:registry][:password_secret]).to eq('REGISTRY_TOKEN')
end
```

If `parser_spec.rb` has no registry describe block or no `write_config` helper, match whatever fixture helper that file already uses — do not invent a new one.

Then in `lib/odysseus/config/parser.rb`, `parse_registry`:

```ruby
      def parse_registry(registry)
        return {} unless registry

        {
          server: registry['server'],
          username: registry['username'],
          password: registry['password'],
          # Names a key in the encrypted secrets file. Resolved by
          # Registry::Credentials, not here: parsing must not read secrets.
          password_secret: registry['password_secret']
        }
      end
```

- [ ] **Step 6: Mutation-check the new specs**

Make each of these changes one at a time, confirm at least one example fails, then revert:
1. In `password`, delete the `raise ... if literal && secret_key` line.
2. In `from_secrets`, return `nil` instead of raising.
3. In `password`, move the `@env[ENV_VAR]` read above the `secret_key` branch.
4. In `complete?`, delete the `username` check.
5. In `parse_registry`, delete the `password_secret:` line.

Any that does not fail means the spec is not testing what it claims.

- [ ] **Step 7: Run the full suite and commit**

```bash
cd odysseus-core && bundle exec rake
cd .. && git add odysseus-core/lib/odysseus/registry/credentials.rb \
  odysseus-core/spec/odysseus/registry/credentials_spec.rb \
  odysseus-core/lib/odysseus/config/parser.rb \
  odysseus-core/spec/odysseus/config/parser_spec.rb
git commit -m "Resolve a registry credential from one named source

registry.password_secret names a key in the encrypted secrets file.
Sources are not a cascade: both set is an error, and a named key that
is missing is an error rather than a fall-through to the environment
variable, because falling through authenticates the deploy with the
wrong credential and reports success.

Not routed through Core::Environment deliberately -- its secret_value
falls back to the deploy target's own environment, and a host that
happens to have REGISTRY_TOKEN set has no business authenticating
someone else's deploy."
```

---

### Task 2: `Docker::Client#pull` takes a config directory

**Files:**
- Modify: `odysseus-core/lib/odysseus/docker/client.rb:157-159`
- Test: `odysseus-core/spec/odysseus/docker/client_spec.rb`

**Interfaces:**
- Produces: `Docker::Client#pull(image, config_dir: nil)`. Tasks 4 and 5 call it with the directory from Task 3.

- [ ] **Step 1: Write the failing test**

```ruby
# in spec/odysseus/docker/client_spec.rb, a new describe
  # DOCKER_CONFIG rather than `docker --config`: CommandRedaction's STDIN_PIPE
  # needs `docker login` directly after the pipe, so a flag between them would
  # silently stop the password being redacted under --debug.
  describe '#pull' do
    it 'pulls without a config directory by default' do
      expect(mock_ssh).to receive(:execute).with('docker pull myapp:v1')
      client.pull('myapp:v1')
    end

    it 'points DOCKER_CONFIG at the directory it is given' do
      expect(mock_ssh).to receive(:execute).with('DOCKER_CONFIG=/tmp/odys.123 docker pull myapp:v1')
      client.pull('myapp:v1', config_dir: '/tmp/odys.123')
    end

    it 'escapes a config directory containing a space' do
      expect(mock_ssh).to receive(:execute).with('DOCKER_CONFIG=/tmp/odys\ 123 docker pull myapp:v1')
      client.pull('myapp:v1', config_dir: '/tmp/odys 123')
    end
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb -e '#pull'`
Expected: FAIL — the second and third examples get `docker pull myapp:v1` with no prefix

- [ ] **Step 3: Write the implementation**

```ruby
      # Pull an image
      #
      # DOCKER_CONFIG rather than `docker --config <dir>`: the two are
      # equivalent to docker, but CommandRedaction::STDIN_PIPE matches
      # `docker login` directly after the pipe, and a flag between them would
      # stop the login password being redacted. Keeping both commands in the
      # env-prefix shape means the redactor only has to know one.
      #
      # @param image [String] image:tag
      # @param config_dir [String, nil] a docker config directory holding
      #   registry credentials, from Registry::HostSession
      def pull(image, config_dir: nil)
        prefix = config_dir ? "DOCKER_CONFIG=#{Shellwords.escape(config_dir)} " : ''
        @ssh.execute("#{prefix}docker pull #{image}")
      end
```

- [ ] **Step 4: Run it and watch it pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/docker/client_spec.rb`
Expected: PASS

- [ ] **Step 5: Mutation-check**

One at a time, confirm a failure, revert: drop the `Shellwords.escape`; make the prefix unconditional; put the prefix after `docker`.

- [ ] **Step 6: Run the full suite and commit**

```bash
cd odysseus-core && bundle exec rake
cd .. && git add odysseus-core/lib/odysseus/docker/client.rb odysseus-core/spec/odysseus/docker/client_spec.rb
git commit -m "Let a pull use a specific docker config directory

DOCKER_CONFIG rather than docker --config: equivalent to docker, but it
keeps the command in the shape CommandRedaction already matches. A flag
between 'docker' and 'login' defeats STDIN_PIPE, whose \S* cannot span
spaces -- which would print the registry password under --debug."
```

---

### Task 3: Registry::HostSession

**Files:**
- Create: `odysseus-core/lib/odysseus/registry/host_session.rb`
- Test: `odysseus-core/spec/odysseus/registry/host_session_spec.rb`

**Interfaces:**
- Consumes: `Registry::Credentials` (Task 1) for `#server`, `#username`, `#password`, `#complete?`; `Odysseus::Deployer::SSH#execute`
- Produces: `Registry::HostSession.open(ssh:, credentials:) { |config_dir| ... }`, a class method that yields a `String` directory or `nil` when credentials are incomplete, and returns the block's value.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/odysseus/registry/host_session_spec.rb
require 'spec_helper'

RSpec.describe Odysseus::Registry::HostSession do
  let(:ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:complete) do
    instance_double(Odysseus::Registry::Credentials,
                    complete?: true, server: 'ghcr.io', username: 'wa', password: 's3cr3t')
  end
  let(:incomplete) { instance_double(Odysseus::Registry::Credentials, complete?: false) }

  def stub_mktemp(dir = '/tmp/odysseus-registry.XYZ')
    allow(ssh).to receive(:execute).with(a_string_including('mktemp -d')).and_return("#{dir}\n")
    allow(ssh).to receive(:execute).with(a_string_including('docker login'))
    allow(ssh).to receive(:execute).with(a_string_including('rm -rf'))
    dir
  end

  it 'yields the directory it created' do
    dir = stub_mktemp
    expect { |b| described_class.open(ssh: ssh, credentials: complete, &b) }.to yield_with_args(dir)
  end

  it 'creates the directory mode 700, so another user on the host cannot read it' do
    stub_mktemp
    expect(ssh).to receive(:execute).with(a_string_including('chmod 700')).and_return("/tmp/d\n")
    allow(ssh).to receive(:execute)
    described_class.open(ssh: ssh, credentials: complete) { nil }
  end

  # $_ holds mktemp's last argument, not its output -- a first version of this
  # chmod'd the template and returned it as the directory.
  it 'returns the directory mktemp created, not the template it was given' do
    allow(ssh).to receive(:execute).with(a_string_including('mktemp')).and_return("/tmp/odysseus-registry.AbCdEfGh\n")
    allow(ssh).to receive(:execute)
    described_class.open(ssh: ssh, credentials: complete) do |dir|
      expect(dir).to eq('/tmp/odysseus-registry.AbCdEfGh')
    end
  end

  it 'aborts when the directory cannot be created' do
    allow(ssh).to receive(:execute).with(a_string_including('mktemp')).and_return("\n")
    expect { described_class.open(ssh: ssh, credentials: complete) { nil } }
      .to raise_error(Odysseus::DeployError, /director/i)
  end

  # Any other shape loses redaction. See CommandRedaction::STDIN_PIPE.
  it 'builds the login in the shape CommandRedaction matches' do
    stub_mktemp('/tmp/d')
    expect(ssh).to receive(:execute).with(
      "echo 's3cr3t' | DOCKER_CONFIG=/tmp/d docker login ghcr.io -u wa --password-stdin"
    )
    described_class.open(ssh: ssh, credentials: complete) { nil }
  end

  it 'redacts the password it just built' do
    stub_mktemp('/tmp/d')
    sent = nil
    allow(ssh).to receive(:execute) do |cmd|
      sent = cmd if cmd.include?('docker login')
      "/tmp/d\n"
    end
    described_class.open(ssh: ssh, credentials: complete) { nil }
    expect(Odysseus::CommandRedaction.redact(sent)).not_to include('s3cr3t')
  end

  it 'removes the directory afterwards' do
    stub_mktemp('/tmp/d')
    expect(ssh).to receive(:execute).with('rm -rf /tmp/d')
    described_class.open(ssh: ssh, credentials: complete) { nil }
  end

  # The whole point of a temp directory is that nothing is left behind, which
  # is exactly the case where the block raised.
  it 'removes the directory when the block raises' do
    stub_mktemp('/tmp/d')
    expect(ssh).to receive(:execute).with('rm -rf /tmp/d')
    expect { described_class.open(ssh: ssh, credentials: complete) { raise 'boom' } }.to raise_error('boom')
  end

  it 'returns what the block returned' do
    stub_mktemp
    expect(described_class.open(ssh: ssh, credentials: complete) { :result }).to eq(:result)
  end

  it 'yields nil and logs in nowhere when credentials are incomplete' do
    expect(ssh).not_to receive(:execute)
    expect { |b| described_class.open(ssh: ssh, credentials: incomplete, &b) }.to yield_with_args(nil)
  end

  it 'aborts when the login is rejected, before anything else runs' do
    allow(ssh).to receive(:execute).with(a_string_including('mktemp -d')).and_return("/tmp/d\n")
    allow(ssh).to receive(:execute).with(a_string_including('docker login'))
                                   .and_raise(Odysseus::SSHCommandError, 'unauthorized')
    allow(ssh).to receive(:execute).with(a_string_including('rm -rf'))
    expect { described_class.open(ssh: ssh, credentials: complete) { nil } }
      .to raise_error(Odysseus::DeployError, /ghcr.io/)
  end

  it 'does not put the password in the abort message' do
    allow(ssh).to receive(:execute).with(a_string_including('mktemp -d')).and_return("/tmp/d\n")
    allow(ssh).to receive(:execute).with(a_string_including('docker login'))
                                   .and_raise(Odysseus::SSHCommandError, 'unauthorized')
    allow(ssh).to receive(:execute).with(a_string_including('rm -rf'))
    described_class.open(ssh: ssh, credentials: complete) { nil }
  rescue Odysseus::DeployError => e
    expect(e.message).not_to include('s3cr3t')
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/registry/host_session_spec.rb`
Expected: FAIL with `NameError: uninitialized constant Odysseus::Registry::HostSession`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/odysseus/registry/host_session.rb

require 'shellwords'

module Odysseus
  module Registry
    # A registry login on one host, confined to a directory that is removed
    # again.
    #
    # Not `docker login` followed by `docker logout`, for three reasons. The
    # credential never enters ~/.docker/config.json. A deploy that dies between
    # login and logout leaves nothing, where the logout approach leaves exactly
    # what it was meant to clean up. And `docker logout` against the default
    # config would remove credentials the host already had for its own
    # purposes, which a deploy has no business doing.
    #
    # Scoped to one SSH connection, which in Executor#run_deploy means one
    # role on one host: a session cannot outlive the connection it logged in
    # over.
    class HostSession
      DIR_TEMPLATE = 'odysseus-registry.XXXXXXXX'.freeze

      # @param ssh [Odysseus::Deployer::SSH]
      # @param credentials [Odysseus::Registry::Credentials]
      # @yieldparam config_dir [String, nil] nil when there is nothing to log
      #   in with, so callers have one code path either way
      # @return [Object] whatever the block returned
      # @raise [Odysseus::DeployError] if the login is rejected
      def self.open(ssh:, credentials:, &block)
        return block.call(nil) unless credentials.complete?

        new(ssh: ssh, credentials: credentials).run(&block)
      end

      def initialize(ssh:, credentials:)
        @ssh = ssh
        @credentials = credentials
      end

      def run
        dir = create_dir
        begin
          login(dir)
          yield(dir)
        ensure
          remove(dir)
        end
      end

      private

      # Mode 700 because the file written inside holds the credential, and a
      # host may have other users on it.
      def create_dir
        # $_ would hold mktemp's last ARGUMENT, not its output, so the
        # directory has to be captured in a shell variable and echoed back.
        out = @ssh.execute("d=$(mktemp -d -t #{DIR_TEMPLATE}) && chmod 700 \"$d\" && echo \"$d\"")
        dir = out.to_s.strip.lines.last.to_s.strip
        raise Odysseus::DeployError, 'Could not create a directory for the registry credentials' if dir.empty?

        dir
      end

      # Built in exactly the shape CommandRedaction::STDIN_PIPE matches, with
      # DOCKER_CONFIG as an env prefix rather than a --config flag: the
      # redactor requires `docker login` directly after the pipe, so a flag
      # between them would print the password under --debug.
      def login(dir)
        @ssh.execute(
          "echo #{Shellwords.escape(@credentials.password)} | " \
          "DOCKER_CONFIG=#{Shellwords.escape(dir)} docker login " \
          "#{Shellwords.escape(@credentials.server)} -u #{Shellwords.escape(@credentials.username)} " \
          '--password-stdin'
        )
      rescue Odysseus::Error => e
        raise Odysseus::DeployError, "Registry login failed for #{@credentials.server}: #{e.message}"
      end

      # Never fails the deploy, but never silent either: what was left behind
      # is a credential on a host.
      def remove(dir)
        return if dir.nil? || dir.empty?

        @ssh.execute("rm -rf #{Shellwords.escape(dir)}")
      rescue StandardError => e
        warn "Could not remove the registry credentials at #{dir}: #{e.message}"
      end
    end
  end
end
```

Note on Step 3: `Shellwords.escape('s3cr3t')` returns `s3cr3t` with no quotes, which would not match `STDIN_PIPE`'s required `(['"])`. Run the "redacts the password it just built" example to find out; if it fails, quote the password explicitly as `'#{@credentials.password}'` and add a spec that a password containing a single quote still round-trips. Do not weaken the redaction spec to make it pass.

- [ ] **Step 4: Run it and watch it pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/registry/host_session_spec.rb`
Expected: PASS, 10 examples

- [ ] **Step 5: Mutation-check**

One at a time, confirm a failure, revert: remove the `ensure` around `yield`; drop `chmod 700`; change `DOCKER_CONFIG=` to `--config`; return the directory instead of yielding when credentials are incomplete; delete the `rescue` in `login`.

- [ ] **Step 6: Run the full suite and commit**

```bash
cd odysseus-core && bundle exec rake
cd .. && git add odysseus-core/lib/odysseus/registry/host_session.rb \
  odysseus-core/spec/odysseus/registry/host_session_spec.rb
git commit -m "Confine a host registry login to a directory that is removed

Not login-then-logout: the credential never enters ~/.docker/config.json,
a deploy that dies mid-flight leaves nothing, and docker logout against
the default config would remove credentials the host already had for its
own purposes.

The login is built in the one shape CommandRedaction matches, and a spec
asserts the password is redacted out of the command actually sent rather
than out of a hand-written approximation of it."
```

---

### Task 4: WebDeploy and JobDeploy pull explicitly

**Files:**
- Modify: `odysseus-core/lib/odysseus/orchestrator/web_deploy.rb:18-24`
- Modify: `odysseus-core/lib/odysseus/orchestrator/job_deploy.rb`
- Test: `odysseus-core/spec/odysseus/orchestrator/web_deploy_spec.rb`
- Test: `odysseus-core/spec/odysseus/orchestrator/job_deploy_spec.rb`

**Interfaces:**
- Consumes: `Docker::Client#pull(image, config_dir:)` from Task 2
- Produces: both orchestrators accept `registry_config_dir: nil`. Task 6 passes it.

- [ ] **Step 1: Write the failing test** (same shape in both spec files; repeat it, do not cross-reference)

```ruby
  # Without an explicit pull a fetch failure arrives later as a container that
  # would not start, which points at the wrong thing.
  describe 'pulling from a registry' do
    it 'pulls before starting a container when given a config directory' do
      expect(mock_docker).to receive(:pull).with('myapp:v1', config_dir: '/tmp/d').ordered
      expect(mock_docker).to receive(:run).ordered.and_return('a' * 64)
      # ... whatever this spec file already stubs for a successful deploy
    end

    it 'does not pull when there is no registry' do
      expect(mock_docker).not_to receive(:pull)
      # ... existing successful-deploy setup, constructed without registry_config_dir
    end

    it 'aborts naming the image when the pull fails' do
      allow(mock_docker).to receive(:pull).and_raise(Odysseus::SSHCommandError, 'denied')
      expect(mock_docker).not_to receive(:run)
      # expect the deploy to fail, matching /myapp:v1/
    end
  end
```

Fill the `# ...` lines from the successful-deploy setup that already exists in each spec file. Do not invent new doubles.

- [ ] **Step 2: Run and watch fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/web_deploy_spec.rb spec/odysseus/orchestrator/job_deploy_spec.rb`
Expected: FAIL — `pull` is never called

- [ ] **Step 3: Implement in both orchestrators**

Constructor — the new argument is optional because sails share this signature:

```ruby
      # @param registry_config_dir [String, nil] docker config directory
      #   holding registry credentials, from Registry::HostSession. Optional:
      #   executor.rb passes this signature to sail plugins too, and a required
      #   argument would break odysseus-sail-rolling.
      def initialize(ssh:, config:, logger: nil, secrets_loader: nil, registry_config_dir: nil)
        # ... existing assignments
        @registry_config_dir = registry_config_dir
      end
```

Then, immediately before the call that starts the new container:

```ruby
        pull_image(image) if @registry_config_dir
```

and privately:

```ruby
      # Explicit, so a fetch failure is attributable. docker run would pull
      # implicitly, but then an unreachable or unauthorized registry surfaces
      # as a container that would not start.
      def pull_image(image)
        log "Pulling #{image}..."
        @docker.pull(image, config_dir: @registry_config_dir)
      rescue Odysseus::Error => e
        raise Odysseus::DeployError, "Could not pull #{image}: #{e.message}"
      end
```

Use whatever local variable each orchestrator already has for the full `image:tag`; do not introduce a second way of computing it.

- [ ] **Step 4: Run and watch pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/`
Expected: PASS

- [ ] **Step 5: Mutation-check**

One at a time: make `registry_config_dir` required (the sail contract test, if any, should complain — if nothing complains, note it in your report); drop the `if @registry_config_dir` guard; move the pull after the container start; delete the `rescue`.

- [ ] **Step 6: Run the full suite and commit**

```bash
cd odysseus-core && bundle exec rake
cd .. && git add odysseus-core/lib/odysseus/orchestrator/web_deploy.rb \
  odysseus-core/lib/odysseus/orchestrator/job_deploy.rb \
  odysseus-core/spec/odysseus/orchestrator/web_deploy_spec.rb \
  odysseus-core/spec/odysseus/orchestrator/job_deploy_spec.rb
git commit -m "Pull explicitly before starting a container

docker run pulls implicitly, so an unreachable or unauthorized registry
surfaced as a container that would not start -- a failure attributed to
the wrong thing. The new argument is optional because executor.rb passes
this signature to sail plugins, and a required one breaks
odysseus-sail-rolling."
```

---

### Task 5: DependencyDeploy uses the config directory

**Files:**
- Modify: `odysseus-core/lib/odysseus/orchestrator/dependency_deploy.rb:19` and `:148`
- Test: `odysseus-core/spec/odysseus/orchestrator/dependency_deploy_spec.rb`

**Interfaces:**
- Produces: `DependencyDeploy.new(..., registry_config_dir: nil)`. Task 6 passes it.

- [ ] **Step 1: Write the failing test**

```ruby
  # This orchestrator already pulled; what it lacked was credentials.
  it 'pulls through the registry config directory when given one' do
    expect(mock_docker).to receive(:pull).with('postgres:16', config_dir: '/tmp/d')
    # ... existing successful dependency-deploy setup, with registry_config_dir: '/tmp/d'
  end

  it 'pulls without one otherwise' do
    expect(mock_docker).to receive(:pull).with('postgres:16', config_dir: nil)
    # ... existing setup
  end
```

- [ ] **Step 2: Run and watch fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/dependency_deploy_spec.rb`
Expected: FAIL — `pull` is called with one argument

- [ ] **Step 3: Implement**

Add `registry_config_dir: nil` to the constructor exactly as in Task 4, assign it, and change line 148:

```ruby
        @docker.pull(image, config_dir: @registry_config_dir)
```

- [ ] **Step 4: Run and watch pass**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/orchestrator/dependency_deploy_spec.rb`

- [ ] **Step 5: Run the full suite and commit**

```bash
cd odysseus-core && bundle exec rake
cd .. && git add odysseus-core/lib/odysseus/orchestrator/dependency_deploy.rb \
  odysseus-core/spec/odysseus/orchestrator/dependency_deploy_spec.rb
git commit -m "Give the dependency pull the registry credentials

DependencyDeploy already pulled explicitly -- it was the only one that
did. What it lacked was any way to authenticate."
```

---

### Task 6: Executor and DependencyManager open the session

**Files:**
- Modify: `odysseus-core/lib/odysseus/deployer/executor.rb:344-356` (`run_deploy`), `:374-396` (`build_orchestrator`)
- Modify: `odysseus-core/lib/odysseus/deployer/dependency_manager.rb` (`run_action`)
- Test: `odysseus-core/spec/odysseus/deployer/executor_spec.rb`
- Test: `odysseus-core/spec/odysseus/deployer/dependency_manager_spec.rb`

**Interfaces:**
- Consumes: `Registry::Credentials` (Task 1), `Registry::HostSession.open` (Task 3), the `registry_config_dir:` argument (Tasks 4 and 5)

- [ ] **Step 1: Write the failing test**

```ruby
  # One session per role-host, because run_deploy's SSH connection is per
  # role-host and a login cannot outlive the connection it was made over.
  describe 'registry sessions' do
    it 'opens a session around the orchestrator and passes the directory down' do
      # with a registry configured and complete credentials, assert
      # Registry::HostSession.open is called with ssh: and credentials:,
      # and that build_orchestrator receives registry_config_dir: the yielded dir
    end

    it 'opens no session when no registry is configured' do
      expect(Odysseus::Registry::HostSession).not_to receive(:open)
      # ... existing pussh-mode deploy setup
    end
  end
```

Write these against whatever doubles `executor_spec.rb` already uses for `connect_to_server`; that file already stubs SSH, so follow its pattern.

- [ ] **Step 2: Run and watch fail**

Run: `cd odysseus-core && bundle exec rspec spec/odysseus/deployer/executor_spec.rb`

- [ ] **Step 3: Implement**

```ruby
      def run_deploy(host:, role:, resolved:, kind: 'deployed', from: nil)
        ssh = connect_to_server(host)

        begin
          # The session is scoped to this connection, which is one role on one
          # host. It cannot be wider: a login cannot outlive the connection it
          # was made over. Closing before record_deploy means the credential is
          # gone from the host as soon as the containers are up.
          result = Odysseus::Registry::HostSession.open(ssh: ssh, credentials: registry_credentials) do |config_dir|
            orchestrator = build_orchestrator(ssh, role, resolved, registry_config_dir: config_dir)
            orchestrator.deploy(image_tag: resolved.version, role: role)
          end
          record_deploy(ssh: ssh, host: host, role: role, resolved: resolved, kind: kind, from: from)
          result
        ensure
          ssh.close
        end
      end

      def registry_credentials
        @registry_credentials ||= Odysseus::Registry::Credentials.new(
          @config[:registry], secrets_loader: @secrets_loader
        )
      end
```

`build_orchestrator` gains the argument and forwards it to all three branches, including the sail branch:

```ruby
      def build_orchestrator(ssh, role, resolved, registry_config_dir: nil)
        # ... unchanged setup
        if strategy && Odysseus::Sails.registered?(strategy)
          sail_klass.new(
            ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader,
            registry_config_dir: registry_config_dir
          )
        # ... same addition in the WebDeploy and JobDeploy branches
      end
```

**Decided: forward it to a sail only when it is non-nil.** A sail written against the old signature raises `ArgumentError: unknown keyword` if handed the argument, and `nil` is exactly the case where it would change nothing — so withholding it there keeps every existing sail working for everyone not using a registry, which is nearly everyone. Only a deploy using *both* a sail and a private registry hits the gap, and that is recorded as its own TODO entry in Task 7 rather than fixed here.

```ruby
        if strategy && Odysseus::Sails.registered?(strategy)
          args = { ssh: ssh, config: config, logger: logger, secrets_loader: @secrets_loader }
          # Withheld when nil: a sail built against the old signature raises
          # ArgumentError on an unknown keyword, and nil would not have changed
          # anything for it anyway. A sail plus a private registry still needs
          # the sail updated -- see TODO.md.
          args[:registry_config_dir] = registry_config_dir if registry_config_dir
          sail_klass.new(**args)
```

The `WebDeploy` and `JobDeploy` branches pass it unconditionally; they are in this repo and gain the argument in Task 4.

Do the same in `DependencyManager#run_action`, wrapping its orchestrator call in a session built from the same credentials.

- [ ] **Step 4: Run and watch pass**

Run: `cd odysseus-core && bundle exec rake`

- [ ] **Step 5: Mutation-check**

One at a time: have `run_deploy` not pass `registry_config_dir`; move `record_deploy` inside the session block; drop the memoization so credentials resolve per role (this should not fail a test — note that in your report rather than adding a test for a non-requirement).

- [ ] **Step 6: Commit**

```bash
cd odysseus-core && bundle exec rake
cd .. && git add odysseus-core/lib/odysseus/deployer/executor.rb \
  odysseus-core/lib/odysseus/deployer/dependency_manager.rb \
  odysseus-core/spec/odysseus/deployer/executor_spec.rb \
  odysseus-core/spec/odysseus/deployer/dependency_manager_spec.rb
git commit -m "Open a registry session around each deploy

One per role-host rather than one per host: run_deploy's SSH connection
is per role-host, and a login cannot outlive the connection it was made
over. The spec said per host; the code says otherwise.

Closed before record_deploy, so the credential is off the host as soon
as the containers are up."
```

---

### Task 7: Documentation, and the spec's two corrections

**Files:**
- Modify: `odysseus-cli/README.md` (the `### registry` section, around line 841)
- Modify: `odysseus-core/CHANGELOG.md` (`## [Unreleased]`)
- Modify: `TODO.md` (the "Finish registry support" entry)
- Modify: `docs/specs/2026-10-23-registry-support-design.md`

- [ ] **Step 1: Correct the spec**

Two statements in it are wrong, found while reading the code for this plan. Fix them in place rather than deleting them, and say they were corrected:
1. It specifies `docker --config <dir> login`. That is **not redacted** by `CommandRedaction::STDIN_PIPE`. The implementation uses `DOCKER_CONFIG=<dir>`.
2. It says one session per host. `run_deploy` opens its SSH connection per role-host, so it is one session per role-host.

- [ ] **Step 2: Replace the README's gesture with the mechanism**

The line "For better security, you can store registry credentials in your encrypted secrets file and reference them" currently promises something with no implementation. Replace it:

```markdown
```yaml
registry:
  server: ghcr.io
  username: wa-systems
  password_secret: REGISTRY_TOKEN   # a key in your encrypted secrets file
```

`password_secret` names a key in the file given by `secrets_file`. The literal
`password:` form still works and warns; it will be removed one release after
this one.

Set `ODYSSEUS_REGISTRY_PASSWORD` instead when neither is configured — for CI,
where the secrets file and its key are not available. Setting both
`password` and `password_secret` is an error rather than a precedence rule.

Hosts log in to a throwaway docker config directory that is removed when the
deploy finishes, so the credential never enters a host's `~/.docker/config.json`
and nothing is left behind if a deploy fails part-way.
```

Keep the **Experimental** warning, and give it its reason:

```markdown
> **Experimental:** every docker and SSH call in the test suite is a double, so
> nothing in it proves a real private registry accepts the login. The code is
> complete; it is the verification that is missing. The pussh path remains the
> supported one.
```

- [ ] **Step 3: Changelog entry under `## [Unreleased]`, `### Added`**

Write what changed and what it costs, in this repo's voice: what was broken (no host ever logged in, two orchestrators never pulled, no way to keep the credential out of deploy.yml), what it is now, and the limit — all doubles, so unverified against a real registry.

- [ ] **Step 4: Update the TODO entry, and add one**

Mark "Finish registry support" `[x]`, keeping the original diagnosis and adding what was done, the `DOCKER_CONFIG`-versus-`--config` discovery, and that it is unverified against a real private registry.

Then add this open entry:

```markdown
- [ ] **A sail cannot pull from a private registry.** `build_orchestrator`
      withholds `registry_config_dir:` from a sail when it is nil, which keeps
      every existing sail working — but it also means a deploy using a sail
      *and* a private registry gets no credentials on the host, and the pull
      fails. `odysseus-sail-rolling` needs the keyword added to its
      constructor, and the same goes for any other sail. Deliberately not done
      with the registry work: sails are separate gems with their own suites,
      and silently passing an argument a sail does not accept raises
      `ArgumentError: unknown keyword` on every deploy using one.
```

- [ ] **Step 5: Commit**

```bash
cd .. && git add odysseus-cli/README.md odysseus-core/CHANGELOG.md TODO.md \
  docs/specs/2026-10-23-registry-support-design.md
git commit -m "Document registry credentials, and correct the spec

The README promised that credentials could live in the encrypted secrets
file and reference them; there was no mechanism. Now there is one, and
the README describes it.

Two corrections to the spec, both found by reading the code while
planning: docker --config between 'docker' and 'login' is not redacted
by CommandRedaction, so the implementation uses DOCKER_CONFIG; and the
session is per role-host, not per host, because that is the lifetime of
run_deploy's SSH connection.

The experimental marking stays, with its reason stated: the suite is all
doubles, so nothing in it proves a real private registry accepts the
login."
```

---

## Verification before calling this done

- [ ] `cd odysseus-core && bundle exec rake` — RSpec and RuboCop both clean
- [ ] `cd odysseus-cli && bundle exec rake` — unchanged by this work, but prove it
- [ ] `grep -rn 'docker --config' odysseus-core/lib` returns nothing
- [ ] A `Registry::HostSession` spec asserts the password is redacted out of the command **actually sent**
- [ ] `grep -n 'registry_config_dir' odysseus-core/lib/odysseus/deployer/executor.rb` shows it reaching all three orchestrator branches
- [ ] Nothing in `lib/` resolves a registry credential through `Core::Environment`
- [ ] The README no longer promises a mechanism that does not exist
- [ ] The spec's two corrections are in place

**Not done by this plan, and must not be claimed:** no part of this is verified against a real private registry. The suite proves the commands are constructed; it does not prove registry mode works. Say so in any report.
