# spec/odysseus/deployer/executor_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Deployer::Executor do
  let(:fixture_file) { fixture_path('deploy.yml') }
  let(:executor) { described_class.new(fixture_file) }

  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }

  before do
    allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
    allow(mock_ssh).to receive(:execute).and_return('')
    allow(mock_ssh).to receive(:upload_string)
    allow(mock_ssh).to receive(:close)
  end

  describe '#initialize' do
    it 'parses the config file' do
      expect { executor }.not_to raise_error
    end

    it 'raises error for missing config' do
      expect { described_class.new('/nonexistent/deploy.yml') }
        .to raise_error(Odysseus::ConfigError)
    end
  end

  describe '#deploy' do
    context 'with dry_run: true' do
      it 'generates files but does not connect to server' do
        expect(Odysseus::Deployer::SSH).not_to receive(:new)
        executor.deploy(server: 'test-server', image_tag: 'v1.0', dry_run: true)
      end

      it 'outputs generation messages' do
        expect { executor.deploy(server: 'test-server', image_tag: 'v1.0', dry_run: true) }
          .to output(/Generated docker-compose.yml/).to_stdout
      end
    end

    context 'with dry_run: false' do
      it 'connects to the server with correct config' do
        expect(Odysseus::Deployer::SSH).to receive(:new).with(
          host: 'test-server',
          user: 'root',
          keys: ['~/.ssh/id_ed25519'],
          use_tailscale: true
        ).and_return(mock_ssh)

        executor.deploy(server: 'test-server', image_tag: 'v1.0')
      end

      it 'creates deploy directory' do
        expect(mock_ssh).to receive(:execute).with('mkdir -p /tmp/odysseus')
        executor.deploy(server: 'test-server', image_tag: 'v1.0')
      end

      it 'uploads docker-compose.yml' do
        expect(mock_ssh).to receive(:upload_string)
          .with(a_string_including('version'), '/tmp/odysseus/docker-compose.yml')
          .ordered

        expect(mock_ssh).to receive(:upload_string)
          .with(anything, '/tmp/odysseus/Caddyfile')
          .ordered

        executor.deploy(server: 'test-server', image_tag: 'v1.0')
      end

      it 'uploads Caddyfile' do
        expect(mock_ssh).to receive(:upload_string)
          .with(anything, '/tmp/odysseus/docker-compose.yml')
          .ordered

        expect(mock_ssh).to receive(:upload_string)
          .with(a_string_including('reverse_proxy'), '/tmp/odysseus/Caddyfile')
          .ordered

        executor.deploy(server: 'test-server', image_tag: 'v1.0')
      end

      it 'executes docker-compose commands in order' do
        commands = []
        allow(mock_ssh).to receive(:execute) do |cmd|
          commands << cmd
          ''
        end

        executor.deploy(server: 'test-server', image_tag: 'v1.0')

        expect(commands).to include('mkdir -p /tmp/odysseus')
        expect(commands).to include('cd /tmp/odysseus && docker-compose pull')
        expect(commands).to include('cd /tmp/odysseus && docker-compose down')
        expect(commands).to include('cd /tmp/odysseus && docker-compose up -d')
      end

      it 'reloads Caddy' do
        expect(mock_ssh).to receive(:execute)
          .with('docker exec caddy caddy reload --config /etc/caddy/Caddyfile')

        executor.deploy(server: 'test-server', image_tag: 'v1.0')
      end

      it 'closes SSH connection when done' do
        expect(mock_ssh).to receive(:close)
        executor.deploy(server: 'test-server', image_tag: 'v1.0')
      end

      it 'closes SSH connection even on error' do
        allow(mock_ssh).to receive(:execute).with(/docker-compose pull/)
          .and_raise(Odysseus::SSHCommandError.new('Command failed'))

        expect(mock_ssh).to receive(:close)

        expect { executor.deploy(server: 'test-server', image_tag: 'v1.0') }
          .to raise_error(Odysseus::SSHCommandError)
      end
    end
  end
end
