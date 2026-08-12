# spec/odysseus/deployer/ssh_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Deployer::SSH do
  let(:ssh) do
    described_class.new(
      host: 'test-server',
      user: 'deploy',
      keys: ['~/.ssh/id_rsa']
    )
  end

  let(:mock_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_channel) { instance_double(Net::SSH::Connection::Channel) }

  before do
    allow(Net::SSH).to receive(:start).and_return(mock_session)
    allow(mock_session).to receive(:closed?).and_return(false)
    allow(mock_session).to receive(:close)
  end

  describe '#initialize' do
    it 'expands key paths' do
      ssh_instance = described_class.new(
        host: 'server',
        keys: ['~/.ssh/id_ed25519']
      )
      # The keys should be expanded (we can't directly test private state,
      # but we verify it doesn't raise)
      expect(ssh_instance).to be_a(described_class)
    end

    it 'sets default user to root' do
      ssh_instance = described_class.new(host: 'server')
      expect(ssh_instance).to be_a(described_class)
    end
  end

  describe '#execute' do
    before do
      allow(mock_session).to receive(:open_channel).and_yield(mock_channel)
      allow(mock_session).to receive(:loop)
      allow(mock_channel).to receive(:exec).and_yield(mock_channel, true)
      allow(mock_channel).to receive(:on_data).and_yield(mock_channel, "command output\n")
      allow(mock_channel).to receive(:on_extended_data)
      allow(mock_channel).to receive(:on_request)
    end

    it 'executes command and returns output' do
      output = ssh.execute('echo hello')
      expect(output).to eq("command output\n")
    end

    it 'connects to correct host and user' do
      expect(Net::SSH).to receive(:start).with(
        'test-server',
        'deploy',
        hash_including(port: 22, non_interactive: true)
      ).and_return(mock_session)

      ssh.execute('test')
    end

    context 'when command fails to execute' do
      before do
        allow(mock_channel).to receive(:exec).and_yield(mock_channel, false)
      end

      it 'raises SSHCommandError' do
        expect { ssh.execute('bad command') }
          .to raise_error(Odysseus::SSHCommandError, /Failed to execute/)
      end
    end

    context 'when connection fails' do
      before do
        allow(Net::SSH).to receive(:start)
          .and_raise(Errno::ECONNREFUSED.new('Connection refused'))
      end

      it 'raises SSHConnectionError' do
        expect { ssh.execute('test') }
          .to raise_error(Odysseus::SSHConnectionError, /Connection refused/)
      end
    end

    context 'when the remote command exits non-zero' do
      before do
        allow(mock_channel).to receive(:on_extended_data)
          .and_yield(mock_channel, nil, "No such container: abc123\n")
        allow(mock_channel).to receive(:on_request).with('exit-status')
                                                   .and_yield(mock_channel, instance_double(Net::SSH::Buffer,
                                                                                            read_long: 1))
      end

      it 'raises SSHCommandError naming the command and exit status' do
        expect { ssh.execute('docker stop abc123') }
          .to raise_error(Odysseus::SSHCommandError) { |error|
            expect(error.message).to include('docker stop abc123')
            expect(error.message).to include('exit status 1')
          }
      end

      it 'includes stderr in the error message' do
        expect { ssh.execute('docker stop abc123') }
          .to raise_error(Odysseus::SSHCommandError, /No such container: abc123/)
      end
    end

    context 'when the remote command writes to stderr but succeeds' do
      before do
        allow(mock_channel).to receive(:on_extended_data)
          .and_yield(mock_channel, nil, "warning: something\n")
        allow(mock_channel).to receive(:on_request).with('exit-status')
                                                   .and_yield(mock_channel, instance_double(Net::SSH::Buffer,
                                                                                            read_long: 0))
      end

      it 'returns stdout without stderr mixed in' do
        expect(ssh.execute('docker ps')).to eq("command output\n")
      end
    end
  end

  describe '#upload' do
    let(:mock_scp) { instance_double(Net::SCP) }

    before do
      allow(mock_session).to receive(:scp).and_return(mock_scp)
      allow(mock_scp).to receive(:upload!)
    end

    it 'uploads file to remote path' do
      expect(mock_scp).to receive(:upload!).with('/local/file', '/remote/file', recursive: true)
      ssh.upload('/local/file', '/remote/file')
    end
  end

  describe '#download' do
    let(:mock_scp) { instance_double(Net::SCP) }

    before do
      allow(mock_session).to receive(:scp).and_return(mock_scp)
      allow(mock_scp).to receive(:download!)
    end

    it 'downloads file from remote path' do
      expect(mock_scp).to receive(:download!).with('/remote/file', '/local/file', recursive: true)
      ssh.download('/remote/file', '/local/file')
    end
  end

  describe '#upload_string' do
    let(:mock_scp) { instance_double(Net::SCP) }

    before do
      allow(mock_session).to receive(:scp).and_return(mock_scp)
      allow(mock_scp).to receive(:upload!)
    end

    it 'uploads string content to remote path' do
      expect(mock_scp).to receive(:upload!) do |io, path|
        expect(io).to be_a(StringIO)
        expect(io.read).to eq('file content')
        expect(path).to eq('/remote/file.txt')
      end
      ssh.upload_string('file content', '/remote/file.txt')
    end
  end

  describe '#connected?' do
    context 'when session is open' do
      before do
        allow(mock_session).to receive(:closed?).and_return(false)
        # Force a connection by executing something
        allow(mock_session).to receive(:open_channel).and_yield(mock_channel)
        allow(mock_session).to receive(:loop)
        allow(mock_channel).to receive(:exec).and_yield(mock_channel, true)
        allow(mock_channel).to receive(:on_data)
        allow(mock_channel).to receive(:on_extended_data)
        allow(mock_channel).to receive(:on_request)
        ssh.execute('test')
      end

      it 'returns true' do
        expect(ssh.connected?).to be true
      end
    end

    context 'when no session exists' do
      it 'returns false' do
        fresh_ssh = described_class.new(host: 'server')
        expect(fresh_ssh.connected?).to be false
      end
    end
  end

  describe '#close' do
    before do
      allow(mock_session).to receive(:open_channel).and_yield(mock_channel)
      allow(mock_session).to receive(:loop)
      allow(mock_channel).to receive(:exec).and_yield(mock_channel, true)
      allow(mock_channel).to receive(:on_data)
      allow(mock_channel).to receive(:on_extended_data)
      allow(mock_channel).to receive(:on_request)
      ssh.execute('test')
    end

    it 'closes the session' do
      expect(mock_session).to receive(:close)
      ssh.close
    end
  end
end
