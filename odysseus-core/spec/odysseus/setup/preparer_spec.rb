# frozen_string_literal: true

require 'spec_helper'
require 'shellwords'

RSpec.describe Odysseus::Setup::Preparer do
  # Commands are recorded so the specs can assert what was actually sent, and
  # an unanticipated command raises rather than silently answering ''. This
  # project has repeatedly shipped bugs where a doubled connection cheerfully
  # answered a command that could never work on a real host.
  #
  # An answer that is itself an Exception is raised instead of returned, so
  # examples can simulate a specific command failing (`sudo -n true` for a
  # denied escalation, say) without every other command on the same
  # connection needing to fail too.
  #
  # @param fresh_answers [Hash, nil] answers for the self-test's own, separate
  #   connection; defaults to `answers` so most examples don't need to think
  #   about it.
  # @param fresh_error [Exception, nil] when set, the self-test's connection
  #   raises this instead of answering -- simulating a user who cannot log in.
  # @return [Array(Preparer, Array<String>, Array<String>, RSpec::Mocks::Double)]
  #   the preparer, the bootstrap connection's commands, the self-test
  #   connection's commands, and that connection's own double (so specs can
  #   assert it was closed).
  def build(answers:, user: 'odysseus', as: 'ubuntu', keys: ['ssh-ed25519 AAAAtest test@example'],
            fresh_answers: nil, fresh_error: nil)
    commands = []
    # Port is deliberately not SSH's default (22): a self-test that hardcoded
    # a port instead of reading it from the bootstrap connection would still
    # pass a test fixed at 22, but not one fixed here.
    ssh = instance_double(Odysseus::Deployer::SSH, user: user, host: 'target.example', port: 2201)
    allow(ssh).to receive(:execute) do |cmd|
      commands << cmd
      pattern = answers.keys.find { |p| cmd.match?(p) }
      raise "spec did not anticipate: #{cmd}" unless pattern

      answer = answers[pattern]
      raise answer if answer.is_a?(Exception)

      answer
    end
    allow(ssh).to receive(:upload_string)

    # The self-test opens a second, genuinely separate connection as the
    # deploy user rather than reusing the bootstrap one. Stubbing
    # Odysseus::Deployer::SSH.new is legitimate here -- unlike stubbing a
    # method on Preparer itself -- because what's under test is that a real
    # second connection gets opened with the right identity, not what it
    # would do if it existed.
    fresh_commands = []
    fresh = instance_double(Odysseus::Deployer::SSH)
    allow(Odysseus::Deployer::SSH).to receive(:new).and_return(fresh)
    if fresh_error
      allow(fresh).to receive(:execute).and_raise(fresh_error)
    else
      resolved = fresh_answers || answers
      allow(fresh).to receive(:execute) do |cmd|
        fresh_commands << cmd
        pattern = resolved.keys.find { |p| cmd.match?(p) }
        raise "spec did not anticipate on the self-test connection: #{cmd}" unless pattern

        resolved[pattern]
      end
    end
    allow(fresh).to receive(:close)

    escalation = Odysseus::Setup::Escalation.new(ssh: ssh, as: as)
    config = { service: 'myapp', ssh: { user: user, keys: ['id_ed25519'] } }
    preparer = described_class.new(ssh: ssh, config: config, escalation: escalation, keys: keys)

    [preparer, commands, fresh_commands, fresh]
  end

  def ubuntu_os_release
    "ID=ubuntu\nVERSION_ID=\"24.04\"\n"
  end

  # A host that is already fully prepared: every step should report :ok, and
  # nothing should be changed.
  def healthy(user: 'odysseus', home: "/home/#{user}")
    {
      /os-release/ => ubuntu_os_release,
      /sudo -n true/ => "\n",
      /docker info/ => "29.1.3\n",
      /id -u/ => "1000\n",
      /getent passwd/ => "#{home}\n",
      /stat -c/ => "#{user} #{user}\n",
      /id -nG/ => "#{user} docker\n",
      /grep -qxF/ => "present\n",
      /test -d/ => "present\n",
      # The mutating commands themselves: their output is never read, only
      # whether they ran at all, which the `commands` array already answers.
      /\b(useradd|usermod|mkdir|touch|chown|chmod)\b/ => '',
      /tee -a/ => ''
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
        !cmd.match?(/\b(useradd|usermod|chown|chmod|mkdir|install)\b/) &&
          # tee itself isn't what must never happen -- overwriting the file
          # is. `tee -a` appends, so it's the only form allowed; a healthy
          # host issues none of this at all, but the property this pins is
          # "never overwrites", not "never uses tee".
          (!cmd.include?('tee') || cmd.include?('tee -a'))
      end)
    end

    it 'reports one result per step, in a stable order' do
      preparer, = build(answers: healthy)

      expect(preparer.prepare.map(&:step))
        .to eq(%i[escalation distro docker user group keys state_dir self_test])
    end
  end

  describe 'the escalation gate' do
    # Nothing before this point has touched the host, so a denied escalation
    # must stop the whole sequence rather than let later steps try their own
    # sudo calls and fail in a more confusing way one at a time.
    it 'stops immediately when passwordless sudo is not available' do
      answers = healthy.merge(/sudo -n true/ => Odysseus::SSHCommandError.new('Permission denied'))
      preparer, commands = build(answers: answers)

      results = preparer.prepare

      expect(results.map(&:step)).to eq([:escalation])
      expect(result_for(results, :escalation).status).to eq(:fail)
      expect(commands).to eq(['sudo -n true'])
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
      # Nothing after the gate should have run. Checking for useradd/usermod
      # alone would not catch a gate that failed to stop the sequence: the
      # healthy fixture's user and group are already correct, so those two
      # steps would issue no mutating command even if they ran. Asserting the
      # step list itself is what actually proves the sequence stopped.
      expect(results.map(&:step)).to eq(%i[escalation distro])
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

      results = preparer.prepare

      expect(result_for(results, :user).status).to eq(:changed)
      expect(commands).to include(a_string_matching(/useradd --create-home/))
    end

    it 'leaves an existing user alone' do
      preparer, commands = build(answers: healthy)

      expect(result_for(preparer.prepare, :user).status).to eq(:ok)
      expect(commands).to all(satisfy { |cmd| !cmd.match?(/useradd/) })
    end

    # The half-created-user recovery the brief names: a user that exists but
    # whose home does not (made some other way, or emptied out afterward).
    # `chown` on a path that isn't there fails outright, so this must create
    # the home rather than raise trying to fix its ownership.
    it 'creates a missing home instead of raising when the user exists without one' do
      answers = healthy.merge(/test -d/ => "absent\n", /stat -c/ => "\n")
      preparer, commands = build(answers: answers)

      results = nil
      expect { results = preparer.prepare }.not_to raise_error

      expect(result_for(results, :user).status).to eq(:changed)
      expect(commands).to include(a_string_matching(%r{mkdir -p .*/home/odysseus\z}))
      expect(commands).to include(a_string_matching(%r{chown odysseus:odysseus .*/home/odysseus\z}))
    end

    # The false comment this replaces claimed /home/<user> held for every
    # user this class either creates or verifies -- false for a pre-existing
    # user with a custom home. The fixture's home is deliberately NOT
    # /home/deploy: a fixture where the real home happened to equal the
    # assumed one could not tell this fix from the bug it replaces.
    it "creates .ssh and the state directory under a pre-existing user's real home, not /home/<user>" do
      answers = healthy(user: 'deploy', home: '/srv/deploy').merge(/grep -qxF/ => "absent\n")
      preparer, commands = build(answers: answers, user: 'deploy')

      results = preparer.prepare

      expect(commands).to include(a_string_matching(%r{mkdir -p .*/srv/deploy/\.ssh\z}))
      expect(commands).to include(a_string_matching(%r{chown -R deploy:deploy .*/srv/deploy/\.ssh\z}))
      expect(result_for(results, :state_dir).detail).to include('/srv/deploy/.odysseus')
      expect(commands).to all(satisfy { |cmd| !cmd.include?('/home/deploy') })
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
      expect(commands).to include(a_string_matching(/tee -a/))
      expect(commands).to all(satisfy { |cmd| !cmd.include?('tee') || cmd.include?('tee -a') })
    end

    it 'does not append a key that is already present' do
      preparer, commands = build(answers: healthy)

      expect(result_for(preparer.prepare, :keys).status).to eq(:ok)
      expect(commands).to all(satisfy { |cmd| !cmd.include?('tee') })
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

    # The append goes through the connection directly (not escalation.run),
    # so only its writer -- `tee`, not `printf` -- gets a sudo prefix; a
    # `>>` redirect would be opened by the bootstrap identity's own shell
    # before sudo ever ran, which is exactly the bug this pins against a
    # regression of.
    it 'elevates only the write into authorized_keys, not the whole append pipeline' do
      answers = healthy.merge(/grep -qxF/ => "absent\n")
      preparer, commands = build(answers: answers, as: 'ubuntu')

      preparer.prepare

      append = commands.find { |cmd| cmd.include?('tee -a') }
      expect(append).to match(/\Aprintf /)
      expect(append).to include('| sudo -n tee -a')
    end

    it 'does not sudo the append under --as root, since the connection is already root' do
      answers = healthy.merge(/grep -qxF/ => "absent\n")
      preparer, commands = build(answers: answers, as: 'root')

      preparer.prepare

      append = commands.find { |cmd| cmd.include?('tee -a') }
      expect(append).not_to include('sudo')
    end

    # Escaping is the whole reason this repo requires Shellwords.escape at
    # every call site: a live bug elsewhere (docker/client.rb's unescaped
    # `-v` values) came from exactly this omission. Nothing here would
    # notice if grep or the append stopped escaping, so both are pinned
    # directly against a key line built to break an unescaped shell.
    it 'escapes a key line containing shell metacharacters before it ever reaches a shell' do
      malicious_key = 'ssh-ed25519 AAAAtest evil; rm -rf / #pwned'
      answers = healthy.merge(/grep -qxF/ => "absent\n")
      preparer, commands = build(answers: answers, keys: [malicious_key])

      preparer.prepare

      escaped = Shellwords.escape(malicious_key)
      expect(commands).to include(a_string_including(escaped))
      # The raw line, unescaped, must never appear as a contiguous
      # substring of any command -- escaping inserts backslashes between
      # exactly the characters that would otherwise make it one.
      expect(commands).to all(satisfy { |cmd| !cmd.include?(malicious_key) })
    end
  end

  describe 'escaping a hostile username' do
    # The username becomes part of every path and several command
    # arguments across every step, not just the keys step -- a single
    # example driving the whole sequence checks all of them at once.
    it 'never lets a metacharacter in the deploy user reach a shell unescaped' do
      malicious_user = 'bad;rm -rf /'
      preparer, commands = build(answers: healthy, user: malicious_user)

      preparer.prepare

      expect(commands).not_to be_empty
      expect(commands).to all(satisfy { |cmd| !cmd.include?(malicious_user) })
    end
  end

  describe 'the state directory' do
    it 'creates and owns a missing state directory' do
      answers = healthy.merge(/test -d/ => "absent\n")
      preparer, commands = build(answers: answers)

      expect(result_for(preparer.prepare, :state_dir).status).to eq(:changed)
      expect(commands).to include(a_string_matching(%r{mkdir -p .*/\.odysseus}))
      expect(commands).to include(a_string_matching(%r{chown odysseus:odysseus .*/\.odysseus}))
    end

    it 'leaves an already-owned state directory alone' do
      preparer, commands = build(answers: healthy)

      expect(result_for(preparer.prepare, :state_dir).status).to eq(:ok)
      expect(commands).to all(satisfy { |cmd| !cmd.match?(%r{mkdir -p .*/\.odysseus}) })
    end
  end

  describe 'the self-test' do
    # The safety argument for the whole command: never hand back a host you
    # have not proven you can reach as the new user.
    it 'connects again as the new user and reports success only if that works' do
      preparer, = build(answers: healthy)

      expect(result_for(preparer.prepare, :self_test).status).to eq(:ok)
    end

    it 'fails when the writability check comes back negative' do
      answers = healthy.merge(/test -d/ => "absent\n")
      preparer, = build(answers: answers)

      expect(result_for(preparer.prepare, :self_test).status).to eq(:fail)
    end

    # Distinct from the writability example above: docker and the directory
    # check are two independent legs, both required for :ok. Failing only
    # via the directory check (as the example above does) would never
    # notice docker's result being ignored.
    it 'fails specifically because docker did not answer, independently of the directory check' do
      fresh_answers = healthy.merge(/docker info/ => "command not found\n")
      preparer, = build(answers: healthy, fresh_answers: fresh_answers)

      result = result_for(preparer.prepare, :self_test)

      expect(result.status).to eq(:fail)
      expect(result.detail).to match(/docker/i)
    end

    # Reusing the bootstrap connection would only prove the bootstrap
    # identity's access -- a different account, and usually a more
    # privileged one. --as ubuntu can read a docker socket the deploy user
    # cannot yet, and vice versa, so nothing short of logging in as the
    # deploy user proves what this step claims to prove.
    it 'opens the second connection as the deploy user, against the bootstrap host and port, ' \
       'with configured keys and Tailscale off' do
      preparer, = build(answers: healthy, user: 'odysseus', as: 'ubuntu')

      preparer.prepare

      expect(Odysseus::Deployer::SSH).to have_received(:new).with(
        hash_including(
          user: 'odysseus',
          host: 'target.example',
          port: 2201,
          keys: ['id_ed25519'],
          use_tailscale: false
        )
      )
    end

    it 'runs its checks over the fresh connection, never the bootstrap one' do
      preparer, commands, fresh_commands, = build(answers: healthy)

      preparer.prepare

      expect(fresh_commands).to include(a_string_matching(/docker info/))
      expect(fresh_commands).to include(a_string_matching(/test -d/))
      # The only command that ever reaches the bootstrap connection without a
      # sudo prefix is the world-readable distro read -- the self-test's
      # checks must not land there too.
      expect(commands.reject { |cmd| cmd.start_with?('sudo -n') })
        .to eq(['cat /etc/os-release 2>/dev/null || true'])
    end

    it 'closes the fresh connection even when a check fails' do
      answers = healthy.merge(/test -d/ => "absent\n")
      preparer, _commands, _fresh_commands, fresh = build(answers: answers)

      preparer.prepare

      expect(fresh).to have_received(:close)
    end

    # The bricked-host case this step exists to catch: a new user who cannot
    # actually log in must be reported by name, not left to raise out of
    # #prepare and hide which step failed.
    it 'reports failure by name, rather than raising, when the new user cannot log in' do
      preparer, = build(answers: healthy, fresh_error: Odysseus::SSHConnectionError.new('Connection refused'))

      result = result_for(preparer.prepare, :self_test)

      expect(result.status).to eq(:fail)
      expect(result.detail).to include('odysseus')
    end
  end
end
