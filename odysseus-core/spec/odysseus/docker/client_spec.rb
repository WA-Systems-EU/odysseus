# spec/odysseus/docker/client_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Docker::Client do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:client) { described_class.new(mock_ssh) }
  let(:container_id) { 'a' * 64 } # Valid 64-char hex container ID

  describe '#run' do
    it 'builds and executes docker run command' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker run -d')
        expect(cmd).to include('--name test-container')
        expect(cmd).to include('myapp:latest')
        "#{container_id}\n"
      end

      result = client.run(name: 'test-container', image: 'myapp:latest')
      expect(result).to eq(container_id)
    end

    it 'includes service label' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--label odysseus.service=myservice')
        "#{container_id}\n"
      end

      client.run(
        name: 'test',
        image: 'myapp:latest',
        options: { service: 'myservice' }
      )
    end

    it 'includes memory limits' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--memory 1g')
        expect(cmd).to include('--memory-reservation 512m')
        "#{container_id}\n"
      end

      client.run(
        name: 'test',
        image: 'myapp:latest',
        options: { memory: '1g', memory_reservation: '512m' }
      )
    end

    it 'includes environment variables' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-e RAILS_ENV=production')
        "#{container_id}\n"
      end

      client.run(
        name: 'test',
        image: 'myapp:latest',
        options: { env: { 'RAILS_ENV' => 'production' } }
      )
    end

    it 'includes network setting' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--network odysseus')
        "#{container_id}\n"
      end

      client.run(
        name: 'test',
        image: 'myapp:latest',
        options: { network: 'odysseus' }
      )
    end

    it 'extracts container ID from output with warnings' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        "WARNING: some docker warning\n#{container_id}\n"
      end

      result = client.run(name: 'test', image: 'myapp:latest')
      expect(result).to eq(container_id)
    end
  end

  describe '#stop' do
    it 'stops container with timeout' do
      expect(mock_ssh).to receive(:execute).with('docker stop --time 10 abc123')
      client.stop('abc123')
    end

    it 'uses custom timeout' do
      expect(mock_ssh).to receive(:execute).with('docker stop --time 30 abc123')
      client.stop('abc123', timeout: 30)
    end
  end

  describe '#remove' do
    it 'removes container' do
      expect(mock_ssh).to receive(:execute).with('docker rm  abc123')
      client.remove('abc123')
    end

    it 'force removes when specified' do
      expect(mock_ssh).to receive(:execute).with('docker rm -f abc123')
      client.remove('abc123', force: true)
    end
  end

  describe '#list' do
    it 'lists containers for service' do
      json_output = '{"ID":"abc123","State":"running"}'
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker ps')
        expect(cmd).to include('--filter label=odysseus.service=myapp')
        json_output
      end

      result = client.list(service: 'myapp')
      expect(result).to eq([{ 'ID' => 'abc123', 'State' => 'running' }])
    end

    it 'includes stopped containers when all: true' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-a')
        ''
      end

      client.list(service: 'myapp', all: true)
    end
  end

  describe '#health_status' do
    it 'returns healthy status' do
      expect(mock_ssh).to receive(:execute).and_return("healthy\n")
      expect(client.health_status('abc123')).to eq('healthy')
    end

    it 'returns unhealthy status' do
      expect(mock_ssh).to receive(:execute).and_return("unhealthy\n")
      expect(client.health_status('abc123')).to eq('unhealthy')
    end

    it 'returns none when no healthcheck' do
      expect(mock_ssh).to receive(:execute).and_return("none\n")
      expect(client.health_status('abc123')).to eq('none')
    end
  end

  describe '#running?' do
    it 'returns true when running' do
      expect(mock_ssh).to receive(:execute).and_return("true\n")
      expect(client.running?('abc123')).to be true
    end

    it 'returns false when not running' do
      expect(mock_ssh).to receive(:execute).and_return("false\n")
      expect(client.running?('abc123')).to be false
    end
  end

  describe '#container_ip' do
    it 'returns IP address' do
      expect(mock_ssh).to receive(:execute).and_return("172.17.0.2\n")
      expect(client.container_ip('abc123')).to eq('172.17.0.2')
    end

    it 'returns nil when no IP' do
      expect(mock_ssh).to receive(:execute).and_return("\n")
      expect(client.container_ip('abc123')).to be_nil
    end
  end

  describe '#pull' do
    it 'pulls the image' do
      expect(mock_ssh).to receive(:execute).with('docker pull myapp:v1.0')
      client.pull('myapp:v1.0')
    end
  end

  describe '#image_exists?' do
    it 'returns true when image exists' do
      expect(mock_ssh).to receive(:execute).and_return("sha256:abc123\n")
      expect(client.image_exists?('myapp:v1.0')).to be true
    end

    it 'returns false when image does not exist' do
      expect(mock_ssh).to receive(:execute).and_return("\n")
      expect(client.image_exists?('myapp:v1.0')).to be false
    end
  end

  describe '#wait_healthy' do
    before do
      allow(client).to receive(:sleep) # Don't actually sleep in tests
    end

    it 'returns true when container becomes healthy' do
      allow(mock_ssh).to receive(:execute)
        .and_return("starting\n", "starting\n", "healthy\n")

      expect(client.wait_healthy('abc123')).to be true
    end

    it 'returns false when container is unhealthy' do
      allow(mock_ssh).to receive(:execute).and_return("unhealthy\n")

      expect(client.wait_healthy('abc123')).to be false
    end
  end

  describe '#logs' do
    it 'gets container logs' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker logs')
        expect(cmd).to include('--tail 100')
        expect(cmd).to include('abc123')
        "log line 1\nlog line 2\n"
      end

      result = client.logs('abc123')
      expect(result).to eq("log line 1\nlog line 2\n")
    end

    it 'supports follow mode with streaming' do
      expect(mock_ssh).to receive(:stream) do |cmd, &block|
        expect(cmd).to include('docker logs')
        expect(cmd).to include('--follow')
        block.call("log line 1\n")
        block.call("log line 2\n")
      end

      lines = []
      client.logs('abc123', follow: true) { |line| lines << line }
      expect(lines).to eq(["log line 1\n", "log line 2\n"])
    end

    it 'supports since parameter' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--since 10m')
        ""
      end

      client.logs('abc123', since: '10m')
    end

    it 'supports timestamps option' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--timestamps')
        ""
      end

      client.logs('abc123', timestamps: true)
    end
  end

  describe '#exec' do
    it 'executes command in container' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker exec')
        expect(cmd).to include('abc123')
        expect(cmd).to include('ls -la')
        "file1\nfile2\n"
      end

      result = client.exec('abc123', 'ls -la')
      expect(result).to eq("file1\nfile2\n")
    end

    it 'supports interactive mode' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-i')
        ""
      end

      client.exec('abc123', 'bash', interactive: true)
    end

    it 'supports tty mode' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-t')
        ""
      end

      client.exec('abc123', 'bash', tty: true)
    end
  end

  describe '#run_once' do
    it 'runs command in ephemeral container' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker run --rm')
        expect(cmd).to include('myapp:latest')
        expect(cmd).to include('rake db:migrate')
        "Migrated!\n"
      end

      result = client.run_once(image: 'myapp:latest', command: 'rake db:migrate')
      expect(result).to eq("Migrated!\n")
    end

    it 'includes environment variables' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-e RAILS_ENV=production')
        ""
      end

      client.run_once(
        image: 'myapp:latest',
        command: 'rails console',
        options: { env: { 'RAILS_ENV' => 'production' } }
      )
    end

    it 'includes network option' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--network odysseus')
        ""
      end

      client.run_once(
        image: 'myapp:latest',
        command: 'bash',
        options: { network: 'odysseus' }
      )
    end

    it 'includes volume mounts' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-v /data:/app/data')
        ""
      end

      client.run_once(
        image: 'myapp:latest',
        command: 'bash',
        options: { volumes: ['/data:/app/data'] }
      )
    end
  end
end
