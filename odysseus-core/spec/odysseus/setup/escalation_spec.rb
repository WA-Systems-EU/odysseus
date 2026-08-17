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
      allow(ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

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
      allow(ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

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

    # The wrapper text alone (checked above) can't tell "sudo: command not
    # found" apart from "sudo: a password is required" — only the
    # underlying error's own detail can. Assert on that detail specifically
    # so dropping e.message from the raised message (e.g. swapping it for
    # e.class.name) fails this spec even though it satisfies every other one.
    it "carries the underlying sudo failure's own detail, not just its class" do
      ssh = instance_double(Odysseus::Deployer::SSH)
      allow(ssh).to receive(:execute).and_raise(Odysseus::SSHCommandError, 'sudo: command not found')

      expect { described_class.new(ssh: ssh, as: 'deploy').probe! }
        .to raise_error(Odysseus::SetupError, /sudo: command not found/)
    end
  end
end
