# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Odysseus::Setup::Preparer do
  # Commands are recorded so the specs can assert what was actually sent, and
  # an unanticipated command raises rather than silently answering ''. This
  # project has repeatedly shipped bugs where a doubled connection cheerfully
  # answered a command that could never work on a real host.
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
    ssh = instance_double(Odysseus::Deployer::SSH, user: user, host: 'target.example', port: 22)
    allow(ssh).to receive(:execute) do |cmd|
      commands << cmd
      next "/home/#{user}\n" if cmd == 'echo $HOME'

      pattern = answers.keys.find { |p| cmd.match?(p) }
      raise "spec did not anticipate: #{cmd}" unless pattern

      answers[pattern]
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
  def healthy(user: 'odysseus')
    {
      /os-release/ => ubuntu_os_release,
      /sudo -n true/ => "\n",
      /docker info/ => "29.1.3\n",
      /id -u/ => "1000\n",
      /stat -c/ => "#{user} #{user}\n",
      /id -nG/ => "#{user} docker\n",
      /grep -qxF/ => "present\n",
      /test -d/ => "present\n",
      # The mutating commands themselves: their output is never read, only
      # whether they ran at all, which the `commands` array already answers.
      /\b(useradd|usermod|mkdir|touch|chown|chmod)\b/ => '',
      />>/ => ''
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

    # Reusing the bootstrap connection would only prove the bootstrap
    # identity's access -- a different account, and usually a more
    # privileged one. --as ubuntu can read a docker socket the deploy user
    # cannot yet, and vice versa, so nothing short of logging in as the
    # deploy user proves what this step claims to prove.
    it 'opens the second connection as the deploy user, not the bootstrap identity, with Tailscale off' do
      preparer, = build(answers: healthy, user: 'odysseus', as: 'ubuntu')

      preparer.prepare

      expect(Odysseus::Deployer::SSH).to have_received(:new)
        .with(hash_including(user: 'odysseus', host: 'target.example', use_tailscale: false))
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
