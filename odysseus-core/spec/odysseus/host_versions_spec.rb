# spec/odysseus/host_versions_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::HostVersions do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
  let(:mock_log) { instance_double(Odysseus::DeployLog) }

  let(:entry) do
    Odysseus::DeployLog::Entry.new(
      at: '2026-08-12T11:27:59Z', version: 'abc123def456', role: 'web',
      ref: 'main', deployer: 'dev@example.com', kind: 'deployed', from: nil
    )
  end

  before do
    allow(Odysseus::Docker::Client).to receive(:new).with(mock_ssh).and_return(mock_docker)
    allow(Odysseus::DeployLog).to receive(:new).and_return(mock_log)
    allow(mock_docker).to receive(:list).and_return([])
    allow(mock_docker).to receive(:image_tags).and_return([])
    allow(mock_log).to receive(:entries).and_return([])
  end

  def read
    described_class.read(host: 'host1', ssh: mock_ssh, service: 'myapp', image: 'myapp-production')
  end

  describe '.read' do
    it 'reports the version label of the running container as current' do
      allow(mock_docker).to receive(:list).with(service: 'myapp').and_return(
        [
          { 'ID' => 'abc', 'Labels' => 'odysseus.service=myapp,odysseus.version=abc123def456' },
          { 'ID' => 'def', 'Labels' => 'odysseus.service=myapp,odysseus.version=9f8e7d6c5b4a' }
        ]
      )

      expect(read.current).to eq('abc123def456')
    end

    it 'reports current as nil when nothing is running' do
      expect(read.current).to be_nil
    end

    # A container deployed before 0.4.2 carries a timestamp here, not a SHA.
    # Whatever the label says is what is serving, so it is reported verbatim
    # and the planner decides whether an image exists for it.
    it 'reports a legacy timestamp label verbatim' do
      allow(mock_docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.version=20260101120000' }]
      )

      expect(read.current).to eq('20260101120000')
    end

    it 'reports the tags present for the repository as available' do
      allow(mock_docker).to receive(:image_tags).with('myapp-production')
                                                .and_return(%w[abc123def456 9f8e7d6c5b4a])

      expect(read.available).to eq(%w[abc123def456 9f8e7d6c5b4a])
    end

    it 'reads the deploy log of that service on that host' do
      expect(Odysseus::DeployLog).to receive(:new).with(ssh: mock_ssh, service: 'myapp')
                                                  .and_return(mock_log)
      allow(mock_log).to receive(:entries).and_return([entry])

      expect(read.history).to eq([entry])
    end

    it 'carries the host name through for reporting' do
      expect(read.host).to eq('host1')
    end
  end

  describe '#available?' do
    subject(:versions) do
      described_class.new(host: 'host1', current: nil, available: %w[abc123 def456], history: [])
    end

    it 'is true for a tag the host has' do
      expect(versions).to be_available('abc123')
    end

    it 'is false for a tag it does not' do
      expect(versions).not_to be_available('999999')
    end
  end
end
