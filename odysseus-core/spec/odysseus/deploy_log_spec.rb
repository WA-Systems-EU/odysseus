# spec/odysseus/deploy_log_spec.rb

require 'spec_helper'
require 'shellwords'

RSpec.describe Odysseus::DeployLog do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:log) { described_class.new(ssh: mock_ssh, service: 'myapp') }
  let(:path) { '/var/lib/odysseus/myapp/deploys.log' }

  describe '#append' do
    it 'creates the directory and appends one line' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc123def456', role: :web, ref: 'main', deployer: 'dev@example.com')

      expect(commands.first).to include('mkdir -p /var/lib/odysseus/myapp')
      expect(commands.last).to include(">> #{path}")
      expect(commands.last).to include('abc123def456')
      expect(commands.last).to include('web')
      expect(commands.last).to include('deployed')
    end

    it 'records a rollback with the version it came from' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(
        version: '9f8e7d6c5b4a', role: :web, ref: 'main', deployer: 'dev@example.com',
        kind: 'rolled-back', from: 'abc123def456'
      )

      expect(commands.last).to include('rolled-back')
      # The whole entry is one escaped shell argument (see the "one line" spec
      # below), so "from=..." is backslash-escaped in the raw command text.
      # Decode it the way a real shell would before asserting on its content.
      decoded = Shellwords.split(commands.last.sub(/\s*>>.*\z/, '')).last
      expect(decoded).to include('from=abc123def456')
    end

    it 'escapes values so a hostile ref cannot inject a command' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc', role: :web, ref: 'main; rm -rf /', deployer: 'dev@example.com')

      # Parse the command the way a real shell would: the hostile ref must not
      # produce extra shell words (which is what would let `rm` run as its own
      # command), and the data itself must survive unmangled inside the single
      # payload argument.
      tokens = Shellwords.split(commands.last.sub(/\s*>>.*\z/, ''))
      expect(tokens.length).to eq(3)
      expect(tokens).not_to include('rm')
      expect(tokens.last).to include('main; rm -rf /')
    end

    it 'writes the whole entry as one line rather than one line per field' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc123def456', role: :web, ref: 'main', deployer: 'dev@example.com')

      # printf reuses its format for each argument, so the data must arrive as a
      # single argument. Drop the redirection, then count the words a shell sees.
      tokens = Shellwords.split(commands.last.sub(/\s*>>.*\z/, ''))
      expect(tokens.length).to eq(3)
      expect(tokens[0]).to eq('printf')
      expect(tokens[2]).to match(/\A\S+ abc123def456 web main dev@example\.com deployed\z/)
    end

    it 'uses a timestamp in the format the log defines' do
      commands = []
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        ''
      }

      log.append(version: 'abc', role: :web, ref: 'main', deployer: 'dev@example.com')

      expect(commands.last).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    end
  end

  describe '#entries' do
    it 'parses the log newest last' do
      allow(mock_ssh).to receive(:execute).and_return(
        "2026-08-12T11:27:59Z abc123def456 web main dev@example.com deployed\n" \
        "2026-08-12T14:02:11Z 9f8e7d6c5b4a web main dev@example.com rolled-back from=abc123def456\n"
      )

      entries = log.entries

      expect(entries.map(&:version)).to eq(%w[abc123def456 9f8e7d6c5b4a])
      expect(entries.last.kind).to eq('rolled-back')
      expect(entries.last.from).to eq('abc123def456')
      expect(entries.first.role).to eq('web')
      expect(entries.first.deployer).to eq('dev@example.com')
    end

    it 'is empty when the log does not exist' do
      allow(mock_ssh).to receive(:execute).and_return('')

      expect(log.entries).to eq([])
    end

    it 'skips lines it cannot parse rather than raising' do
      allow(mock_ssh).to receive(:execute).and_return("garbage\n2026-08-12T11:27:59Z abc web main d deployed\n")

      expect(log.entries.map(&:version)).to eq(['abc'])
    end
  end
end
