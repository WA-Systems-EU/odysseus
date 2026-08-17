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
  # rubocop:disable Lint/ConstantDefinitionInBlock
  UBUNTU_2404 = "ID=ubuntu\nVERSION_ID=\"24.04\"\nID_LIKE=debian\n"
  UBUNTU_2604 = "ID=ubuntu\nVERSION_ID=\"26.04\"\nID_LIKE=debian\n"
  DEBIAN_12   = "ID=debian\nVERSION_ID=\"12\"\n"
  # rubocop:enable Lint/ConstantDefinitionInBlock

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
