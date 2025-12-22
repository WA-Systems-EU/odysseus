# spec/odysseus/builder/client_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Builder::Client do
  let(:builder_config) do
    {
      strategy: :local,
      dockerfile: 'Dockerfile',
      context: '.',
      arch: 'amd64',
      platforms: [],
      build_args: {},
      cache: true,
      push: false,
      multiarch: false
    }
  end

  let(:ssh_config) do
    {
      user: 'root',
      keys: ['~/.ssh/id_ed25519']
    }
  end

  let(:mock_logger) do
    double('logger').tap do |l|
      allow(l).to receive(:info)
      allow(l).to receive(:warn)
      allow(l).to receive(:error)
      allow(l).to receive(:debug)
    end
  end

  let(:client) do
    described_class.new(
      config: builder_config,
      ssh_config: ssh_config,
      logger: mock_logger,
      verbose: false
    )
  end

  describe '#initialize' do
    it 'normalizes config with defaults' do
      client = described_class.new(config: {}, logger: mock_logger)

      expect(client.strategy).to eq(:local)
      expect(client.build_host).to be_nil
    end

    it 'accepts string keys in config' do
      client = described_class.new(
        config: { 'strategy' => 'remote', 'host' => 'build-host' },
        logger: mock_logger
      )

      expect(client.strategy).to eq(:remote)
      expect(client.build_host).to eq('build-host')
    end
  end

  describe '#strategy' do
    it 'returns :local by default' do
      expect(client.strategy).to eq(:local)
    end

    it 'returns :remote when configured' do
      client = described_class.new(
        config: { strategy: :remote, host: 'build-host' },
        logger: mock_logger
      )
      expect(client.strategy).to eq(:remote)
    end
  end

  describe '#build_host' do
    it 'returns nil for local strategy' do
      expect(client.build_host).to be_nil
    end

    it 'returns host for remote strategy' do
      client = described_class.new(
        config: { strategy: :remote, host: 'build-server' },
        logger: mock_logger
      )
      expect(client.build_host).to eq('build-server')
    end
  end

  describe '#build' do
    context 'with local strategy' do
      let(:context_path) { '/path/to/app' }
      let(:image) { 'myregistry/myapp:v1.0.0' }

      it 'builds locally with docker build command' do
        allow(client).to receive(:execute_local) do |cmd, _path|
          expect(cmd).to include('docker build')
          expect(cmd).to include("-t #{image}")
          expect(cmd).to include("-f #{context_path}/Dockerfile")
          "Successfully built abc123\n"
        end

        result = client.build(context_path: context_path, image: image)
        expect(result[:success]).to be true
        expect(result[:strategy]).to eq(:local)
        expect(result[:image]).to eq(image)
      end

      it 'includes platform when arch is specified' do
        allow(client).to receive(:execute_local) do |cmd, _path|
          expect(cmd).to include('--platform linux/amd64')
          "Successfully built\n"
        end

        client.build(context_path: context_path, image: image)
      end

      it 'adds --no-cache when cache is disabled' do
        client = described_class.new(
          config: builder_config.merge(cache: false),
          logger: mock_logger
        )

        allow(client).to receive(:execute_local) do |cmd, _path|
          expect(cmd).to include('--no-cache')
          "Successfully built\n"
        end

        client.build(context_path: context_path, image: image)
      end

      it 'includes build args' do
        client = described_class.new(
          config: builder_config.merge(build_args: { RUBY_VERSION: '3.2', NODE_VERSION: '18' }),
          logger: mock_logger
        )

        allow(client).to receive(:execute_local) do |cmd, _path|
          expect(cmd).to include('--build-arg RUBY_VERSION=3.2')
          expect(cmd).to include('--build-arg NODE_VERSION=18')
          "Successfully built\n"
        end

        client.build(context_path: context_path, image: image)
      end

      it 'returns failure result when build fails' do
        allow(client).to receive(:execute_local).and_raise(
          Odysseus::BuildError.new("Build failed")
        )

        result = client.build(context_path: context_path, image: image)
        expect(result[:success]).to be false
        expect(result[:strategy]).to eq(:local)
        expect(result[:error]).not_to be_nil
      end
    end

    context 'with remote strategy' do
      let(:remote_config) do
        builder_config.merge(strategy: :remote, host: 'build-server')
      end

      let(:client) do
        described_class.new(
          config: remote_config,
          ssh_config: ssh_config,
          logger: mock_logger
        )
      end

      let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
      let(:context_path) { '/path/to/app' }
      let(:image) { 'myregistry/myapp:v1.0.0' }

      before do
        allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
        allow(mock_ssh).to receive(:execute).and_return("Successfully built\n")
        allow(mock_ssh).to receive(:upload)
        allow(mock_ssh).to receive(:close)
      end

      it 'builds on remote host via SSH' do
        expect(Odysseus::Deployer::SSH).to receive(:new).with(
          host: 'build-server',
          user: 'root',
          keys: ['~/.ssh/id_ed25519'],
          verbose: false
        ).and_return(mock_ssh)

        expect(mock_ssh).to receive(:execute).with(/mkdir -p/)
        expect(mock_ssh).to receive(:upload)
        expect(mock_ssh).to receive(:execute).with(/docker build/)
        expect(mock_ssh).to receive(:execute).with(/rm -rf/)
        expect(mock_ssh).to receive(:close)

        result = client.build(context_path: context_path, image: image)
        expect(result[:success]).to be true
        expect(result[:strategy]).to eq(:remote)
      end

      it 'uploads build context to remote host' do
        allow(mock_ssh).to receive(:execute)

        expect(mock_ssh).to receive(:upload).with(context_path, anything)

        client.build(context_path: context_path, image: image)
      end

      it 'cleans up remote directory after build' do
        allow(mock_ssh).to receive(:execute)

        expect(mock_ssh).to receive(:execute).with(/rm -rf \/tmp\/odysseus-build/)

        client.build(context_path: context_path, image: image)
      end

      it 'raises error when host is not configured' do
        client = described_class.new(
          config: { strategy: :remote },
          logger: mock_logger
        )

        expect {
          client.build(context_path: context_path, image: image)
        }.to raise_error(Odysseus::BuildError, /host/)
      end
    end

    context 'with multiarch builds' do
      let(:multiarch_config) do
        builder_config.merge(
          multiarch: true,
          platforms: ['linux/amd64', 'linux/arm64']
        )
      end

      let(:client) do
        described_class.new(
          config: multiarch_config,
          logger: mock_logger
        )
      end

      it 'uses docker buildx for multi-platform builds' do
        allow(client).to receive(:execute_local) do |cmd, _path|
          expect(cmd).to include('docker buildx build')
          expect(cmd).to include('--platform linux/amd64,linux/arm64')
          "Successfully built\n"
        end

        client.build(context_path: '/path/to/app', image: 'myapp:v1.0.0')
      end
    end
  end

  describe '#build_and_push' do
    let(:context_path) { '/path/to/app' }
    let(:image) { 'myregistry/myapp:v1.0.0' }

    before do
      allow(client).to receive(:execute_local).and_return("Success\n")
      allow(client).to receive(:execute_local_command).and_return("Success\n")
    end

    it 'builds and pushes when push is configured' do
      push_client = described_class.new(
        config: builder_config.merge(push: true),
        logger: mock_logger
      )
      allow(push_client).to receive(:execute_local).and_return("Success\n")
      allow(push_client).to receive(:execute_local_command).and_return("Success\n")

      result = push_client.build_and_push(context_path: context_path, image: image)
      expect(result[:success]).to be true
      expect(result[:pushed]).to be true
    end

    it 'does not push when push is false and no registry provided' do
      result = client.build_and_push(context_path: context_path, image: image)
      expect(result[:success]).to be true
      expect(result[:pushed]).to be false
    end

    it 'pushes when registry config is provided' do
      registry = { username: 'user', password: 'pass', server: 'docker.io' }

      result = client.build_and_push(
        context_path: context_path,
        image: image,
        registry: registry
      )
      expect(result[:success]).to be true
      expect(result[:pushed]).to be true
    end
  end

  describe '#push' do
    let(:image) { 'myregistry/myapp:v1.0.0' }

    before do
      allow(client).to receive(:execute_local_command).and_return("Pushed\n")
    end

    it 'pushes image to registry' do
      expect(client).to receive(:execute_local_command) do |cmd|
        expect(cmd).to include('docker push')
        expect(cmd).to include(image)
        "Pushed\n"
      end

      result = client.push(image: image)
      expect(result[:success]).to be true
    end

    it 'logs in before push when credentials provided' do
      registry = { username: 'user', password: 'secret', server: 'docker.io' }

      # First call is login, second is push
      call_count = 0
      allow(client).to receive(:execute_local_command) do |cmd|
        call_count += 1
        if call_count == 1
          expect(cmd).to include('docker login')
          expect(cmd).to include('-u user')
          expect(cmd).to include('docker.io')
        end
        "Success\n"
      end

      client.push(image: image, registry: registry)
    end
  end

  describe '#image_exists?' do
    it 'returns true when image exists' do
      allow(client).to receive(:execute_local_command).and_return("sha256:abc123\n")
      expect(client.image_exists?('myapp:v1.0.0')).to be true
    end

    it 'returns false when image does not exist' do
      allow(client).to receive(:execute_local_command).and_return("\n")
      expect(client.image_exists?('myapp:v1.0.0')).to be false
    end

    it 'returns false on error' do
      allow(client).to receive(:execute_local_command).and_raise(StandardError)
      expect(client.image_exists?('myapp:v1.0.0')).to be false
    end
  end

  describe '#pussh' do
    let(:image) { 'myregistry/myapp:v1.0.0' }
    let(:host) { 'server1.example.com' }

    it 'pushes image to host via SSH using docker pussh' do
      expect(client).to receive(:execute_local_command) do |cmd|
        expect(cmd).to include('docker pussh')
        expect(cmd).to include(image)
        expect(cmd).to include('root@server1.example.com')
        "Pushed successfully\n"
      end

      result = client.pussh(image: image, host: host)
      expect(result[:success]).to be true
      expect(result[:host]).to eq(host)
    end

    it 'uses custom SSH user' do
      expect(client).to receive(:execute_local_command) do |cmd|
        expect(cmd).to include('deploy@server1.example.com')
        "Pushed successfully\n"
      end

      client.pussh(image: image, host: host, user: 'deploy')
    end

    it 'returns failure when pussh fails' do
      allow(client).to receive(:execute_local_command).and_raise(
        Odysseus::BuildError.new("Connection refused")
      )

      result = client.pussh(image: image, host: host)
      expect(result[:success]).to be false
      expect(result[:error]).to include("Connection refused")
    end
  end

  describe '#pussh_to_hosts' do
    let(:image) { 'myregistry/myapp:v1.0.0' }
    let(:hosts) { ['server1.example.com', 'server2.example.com'] }

    before do
      allow(client).to receive(:execute_local_command).and_return("Success\n")
    end

    it 'pushes to all hosts' do
      expect(client).to receive(:execute_local_command).twice

      result = client.pussh_to_hosts(image: image, hosts: hosts)
      expect(result[:success]).to be true
      expect(result[:results].keys).to eq(hosts)
    end

    it 'reports partial failure' do
      call_count = 0
      allow(client).to receive(:execute_local_command) do
        call_count += 1
        if call_count == 1
          "Success\n"
        else
          raise Odysseus::BuildError.new("Failed")
        end
      end

      result = client.pussh_to_hosts(image: image, hosts: hosts)
      expect(result[:success]).to be false
      expect(result[:results]['server1.example.com'][:success]).to be true
      expect(result[:results]['server2.example.com'][:success]).to be false
    end
  end
end
