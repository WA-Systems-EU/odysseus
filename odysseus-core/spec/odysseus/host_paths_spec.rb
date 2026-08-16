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
