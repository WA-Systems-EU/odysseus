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

    # The sources command is built via Shellwords.escape (see the exact-match
    # example above), which also escapes `=`, so the literal substring is
    # `arch\=arm64`, not `arch=arm64`.
    expect(commands.find { |c| c.include?('docker.list') }).to include('arch\=arm64')
  end

  it 'takes the codename from the caller rather than assuming one' do
    apt, commands = build(answers: healthy, codename: 'plucky')

    apt.install!

    # Same escaping caveat as the architecture example above: the space
    # before the codename survives as `\ ` in the Shellwords.escape output.
    expect(commands.find { |c| c.include?('docker.list') }).to include('\ plucky\ stable')
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

  # NOTE: pattern order matters here. The harness resolves an answer with
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
