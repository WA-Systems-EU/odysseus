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

      answer = answer.call if answer.respond_to?(:call)
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
    "ID=ubuntu\nVERSION_ID=\"24.04\"\nVERSION_CODENAME=noble\n"
  end

  # A host that is already fully prepared: every step should report :ok, and
  # nothing should be changed.
  #
  # `getent passwd`'s answer is a real, full passwd line (7 colon-delimited
  # fields) since home_dir now splits field 6 out itself, in Ruby, rather
  # than trusting a `| cut -d: -f6` in the command sent -- a fixture that
  # answered with the bare home path, as it used to, would silently stop
  # exercising that split at all.
  def healthy(user: 'odysseus', home: "/home/#{user}")
    {
      /os-release/ => ubuntu_os_release,
      /sudo -n true/ => "\n",
      /docker info/ => "29.1.3\n",
      /id -u/ => "1000\n",
      /getent passwd/ => "#{user}:x:1000:1000::#{home}:/bin/bash\n",
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

  # True if `cmd` is a chown whose target -- the last whitespace-delimited
  # token, which is where every chown call in preparer.rb puts its path --
  # canonicalizes to the filesystem root, under any spelling ("/", "//",
  # "/.", "/.."), not only the literal string "/". Mirrors the production
  # canonicalization exactly (squeeze leading slashes, then expand) so this
  # check can only be as strict as the guard it's verifying.
  def chowns_root?(cmd)
    return false unless cmd.include?('chown')

    target = cmd.split.last
    File.expand_path(target.sub(%r{\A/+}, '/')) == '/'
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
          /tee .*docker\.list/ => '',
          # Only reached when an apt-get command fails: DockerApt#apt calls
          # #lock_holder_note to attribute the failure, which runs `fuser`
          # first. An empty answer (no PID) mirrors the common case -- an
          # apt-get failure that isn't a lock contention -- and short-circuits
          # before the `ps` lookup that would otherwise also need a stub.
          /fuser/ => ''
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
        # Compare against the ESCAPED fragment. The sources line reaches the
        # shell through Shellwords.escape, which backslash-escapes both `=` and
        # spaces -- `include(' wonderfowl stable')` can never match, and an
        # assertion that can never match is one that never fails. Escaping is
        # per-character, so the escape of a fragment is a substring of the
        # escaped whole, which makes this exact and readable at once.
        expect(commands.find { |c| c.include?('docker.list') })
          .to include(Shellwords.escape('wonderfowl stable'))
      end
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

    # Both halves of the ownership check must hold independently: a home
    # owned odysseus:root (group wrong, owner right) must still be repaired.
    # `owner == @user && group == @user` weakened to `||` would report :ok
    # here and never fix the group.
    it 'repairs a home whose owner is correct but whose group is not' do
      answers = healthy.merge(/stat -c/ => "odysseus root\n")
      preparer, commands = build(answers: answers)

      result = result_for(preparer.prepare, :user)

      expect(result.status).to eq(:changed)
      expect(commands).to include(a_string_matching(/chown odysseus:odysseus/))
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

  describe 'resolving the home directory' do
    # The freshest, most common case: a brand-new host, a user this class
    # just created with useradd -m. If getent still can't report a home for
    # it, home_dir must refuse rather than let File.join("", ".ssh")
    # silently become "/.ssh" -- the false-success case the re-review
    # rated Critical, since keys_step and state_dir_step would otherwise
    # succeed at the filesystem root while /home/<user> was never touched.
    # /grep -qxF/ and /test -d/ are both overridden to "absent" so that,
    # under the bug this guards, keys_step and state_dir_step would
    # actually try to create something at "/" -- against the unmodified
    # healthy fixture, both already report :ok/:changed independent of
    # path, which would let this example pass whether or not the guard
    # exists at all.
    it 'fails loudly for a freshly created user when getent reports no home, rather than using /' do
      answers = healthy.merge(/id -u/ => nil, /getent passwd/ => "\n", /grep -qxF/ => "absent\n", /test -d/ => "absent\n")
      preparer, commands = build(answers: answers)

      results = preparer.prepare

      expect(result_for(results, :user).status).to eq(:fail)
      expect(result_for(results, :user).detail).to match(/could not resolve/)
      expect(commands).to all(satisfy { |cmd| !cmd.include?('/.ssh') && !cmd.include?('/.odysseus') })
    end

    # Before your change, /home/<user> sandboxed a wrongly-owned home; an
    # arbitrary passwd field used unvalidated removes that sandbox. A home
    # of exactly "/" would otherwise be judged "owned wrong" (stat -c
    # answers root root here, standing in for a real host's /) and
    # repaired by chowning the filesystem root to the deploy user --
    # seizing a directory setup never created, the same invariant Finding
    # 1 was raised to enforce.
    it 'refuses a home of exactly /, rather than chowning the filesystem root' do
      answers = healthy.merge(/getent passwd/ => "odysseus:x:1000:1000::/:/bin/bash\n", /stat -c/ => "root root\n")
      preparer, commands = build(answers: answers)

      results = preparer.prepare

      expect(result_for(results, :user).status).to eq(:fail)
      # A path-equivalence check, not a literal `end_with?(' /')` string
      # match: the literal match only ever caught the single spelling "/"
      # and would have let //, /. and /.. -- the near-misses below -- issue
      # their chown unnoticed.
      expect(commands).to all(satisfy { |cmd| !chowns_root?(cmd) })
    end

    # `.start_with?('/') && != '/'` rejected only the literal string "/".
    # A real host's getent can report the filesystem root under other
    # spellings just as easily, and each of these reached
    # verify_home_ownership's chown unrejected before this guard.
    it 'refuses //, /. and /.. -- other spellings of the filesystem root -- issuing no chown that names any of them' do
      %w[// /. /..].each do |root_spelling|
        answers = healthy.merge(
          /getent passwd/ => "odysseus:x:1000:1000::#{root_spelling}:/bin/bash\n",
          /stat -c/ => "root root\n"
        )
        preparer, commands = build(answers: answers)

        result = result_for(preparer.prepare, :user)

        expect(result.status).to eq(:fail), "#{root_spelling.inspect} did not refuse"
        expect(commands).to all(satisfy { |cmd| !chowns_root?(cmd) }), "#{root_spelling.inspect} let a chown through: #{commands.inspect}"
      end
    end

    # The flip side of refusing root-equivalent spellings: a legitimate
    # custom home that merely happens to be written with a doubled leading
    # slash must still work, and every downstream path must be built from
    # the canonical form -- not the raw, cosmetically-doubled one -- so a
    # second run against the same host doesn't disagree with the first
    # about which path it manages.
    it 'accepts //srv/deploy, normalising it to /srv/deploy before any path is built from it' do
      answers = healthy(user: 'deploy', home: '//srv/deploy').merge(/grep -qxF/ => "absent\n")
      preparer, commands = build(answers: answers, user: 'deploy')

      preparer.prepare

      expect(commands).to include(a_string_matching(%r{mkdir -p .*/srv/deploy/\.ssh\z}))
      expect(commands).to include(a_string_matching(%r{chown -R deploy:deploy .*/srv/deploy/\.ssh\z}))
      expect(commands).to all(satisfy { |cmd| !cmd.include?('//srv/deploy') })
    end

    it 'refuses a home that does not start with /' do
      answers = healthy.merge(/getent passwd/ => "odysseus:x:1000:1000::srv/deploy:/bin/bash\n")
      preparer, = build(answers: answers)

      result = result_for(preparer.prepare, :user)

      expect(result.status).to eq(:fail)
      expect(result.detail).to match(/could not resolve/)
    end

    # This is the third instance on this branch of the exit status being
    # observed not being the one that mattered: `getent passwd X | cut -d:
    # -f6` exited 0 (cut's status) no matter how badly getent failed. With
    # the pipe gone, a failed getent now raises through Escalation#run
    # instead of being silently swallowed as an empty home.
    it "surfaces a failed getent, with the pipe gone from the command it's sent" do
      answers = healthy.merge(/getent passwd/ => Odysseus::SSHCommandError.new('no such user'))
      preparer, commands = build(answers: answers)

      expect { preparer.prepare }.to raise_error(Odysseus::SSHCommandError)
      expect(commands.last).not_to include('|')
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
      # \bchown -R\b, not just /chown .*\.ssh/: a plain (non-recursive) chown
      # also matches the looser pattern, but leaves authorized_keys itself
      # -- created root-owned by `sudo tee` -- unowned by the user, who can
      # then neither read nor rotate their own key even though login still
      # works.
      expect(commands).to include(a_string_matching(/\bchown -R\b.*odysseus.*\.ssh/))
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

    # A run interrupted (e.g. SIGINT) between `mkdir -p` -- which runs via
    # sudo and so leaves the directory root-owned -- and the `chown` one
    # line later leaves the directory existing but owned by root. The next
    # run must repair it rather than report :ok: `exists && owner == @user`
    # weakened to just `exists` would report :ok forever and never repair,
    # so the self-test's `test -w` would fail on every subsequent run
    # against a host setup itself calls fine.
    #
    # healthy's own generic /stat -c/ answer must be removed, not merely
    # shadowed: `answers.keys.find` checks patterns in insertion order, so a
    # broader pattern already present would still match first and hide a
    # merged-in narrower one. The two replacements below don't overlap each
    # other, though: state_dir's query is `stat -c '%U' path` (one field)
    # while the user step's is `stat -c '%U %G' path` (two) -- `'%U'` alone
    # is not a substring of `'%U %G'` because a space, not a closing quote,
    # follows U there, so each pattern matches only its own command.
    it 'repairs a state directory that exists but is owned by someone else' do
      answers = healthy.reject { |pattern, _| pattern == /stat -c/ }.merge(
        /stat -c '%U %G'/ => "odysseus odysseus\n",
        /stat -c '%U'/ => "root\n"
      )
      preparer, commands = build(answers: answers)

      result = result_for(preparer.prepare, :state_dir)

      expect(result.status).to eq(:changed)
      expect(commands).to include(a_string_matching(%r{chown odysseus:odysseus .*/\.odysseus}))
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
