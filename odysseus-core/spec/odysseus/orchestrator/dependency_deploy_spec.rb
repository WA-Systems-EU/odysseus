# spec/odysseus/orchestrator/dependency_deploy_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Orchestrator::DependencyDeploy do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
  let(:mock_caddy) { instance_double(Odysseus::Caddy::Client) }

  let(:config) do
    {
      service: 'myapp',
      dependencies: {
        redis: {
          image: 'redis:7-alpine',
          volumes: ['/var/lib/redis:/data'],
          healthcheck: {
            cmd: 'redis-cli ping',
            interval: 10,
            timeout: 5
          }
        },
        db: {
          image: 'postgres:15',
          ports: ['5432:5432'],
          volumes: ['/var/lib/postgres:/var/lib/postgresql/data'],
          env: {
            clear: { POSTGRES_PASSWORD: 'secret' },
            secret: []
          }
        },
        admin: {
          image: 'adminer:latest',
          proxy: {
            hosts: ['admin.example.com'],
            app_port: 8080,
            ssl: true,
            ssl_email: 'admin@example.com'
          }
        }
      },
      ssh: { user: 'deploy', keys: ['~/.ssh/id_rsa'] }
    }
  end

  let(:silent_logger) do
    Object.new.tap do |l|
      def l.info(_msg); end
      def l.warn(_msg); end
      def l.error(_msg); end
    end
  end

  let(:orchestrator) { described_class.new(ssh: mock_ssh, config: config, logger: silent_logger) }

  before do
    allow(Odysseus::Docker::Client).to receive(:new).with(mock_ssh).and_return(mock_docker)
    allow(Odysseus::Caddy::Client).to receive(:new).with(ssh: mock_ssh, docker: mock_docker).and_return(mock_caddy)
    allow(orchestrator).to receive(:sleep)
    allow(mock_docker).to receive(:volume_exists?).and_return(false)
    allow(mock_docker).to receive(:ensure_network)
  end

  describe '#deploy' do
    context 'when dependency is not running' do
      let(:container_id) { 'redis123456' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return(container_id)
        allow(mock_docker).to receive(:wait_healthy).and_return(true)
      end

      it 'ensures the Docker network exists before starting' do
        expect(mock_docker).to receive(:ensure_network).with('odysseus',
                                                             labels: { 'odysseus.managed' => 'true' }).ordered
        expect(mock_docker).to receive(:run).ordered
        orchestrator.deploy(name: :redis)
      end

      it 'starts the dependency container' do
        expect(mock_docker).to receive(:run).with(
          name: 'myapp-redis',
          image: 'redis:7-alpine',
          options: hash_including(
            service: 'myapp-redis',
            network: 'odysseus',
            volumes: ['/var/lib/redis:/data']
          )
        ).and_return(container_id)

        orchestrator.deploy(name: :redis)
      end

      it 'waits for healthcheck if configured' do
        expect(mock_docker).to receive(:wait_healthy).with(container_id, timeout: 120).and_return(true)
        orchestrator.deploy(name: :redis)
      end

      it 'returns success result' do
        result = orchestrator.deploy(name: :redis)
        expect(result[:success]).to be true
        expect(result[:service]).to eq('myapp-redis')
      end

      # This is what makes renaming the `accessories:` key to `dependencies:`
      # safe to ship without a migration. The container name and the
      # odysseus.service label are built from "#{service}-#{name}" using the
      # *individual* dependency's key, so the top-level YAML key never reaches
      # a host. Runs the real parser over a real legacy fixture rather than an
      # inline hash, so it fails if either the back-compat key handling or the
      # naming changes — if it does, upgrading orphans every running
      # dependency container instead of adopting it.
      it 'names the container identically whichever config key deploy.yml used' do
        # The fixtures declare no healthcheck, so this takes the running? path
        # rather than the wait_healthy path the inline config above exercises.
        allow(mock_docker).to receive(:running?).and_return(true)

        %w[deploy-dependencies.yml deploy-legacy-accessories.yml].each do |fixture|
          parsed = Odysseus::Config::Parser.new(fixture_path(fixture)).parse
          from_file = described_class.new(ssh: mock_ssh, config: parsed, logger: silent_logger)
          allow(from_file).to receive(:sleep)

          expect(mock_docker).to receive(:run)
            .with(hash_including(name: 'myapp-redis', options: hash_including(service: 'myapp-redis')))
            .and_return(container_id)

          expect(from_file.deploy(name: :redis)[:service]).to eq('myapp-redis')
        end
      end
    end

    context 'when dependency is already running' do
      before do
        allow(mock_docker).to receive(:list).and_return([
                                                          { 'ID' => 'existing123', 'State' => 'running' }
                                                        ])
      end

      it 'does not start a new container' do
        expect(mock_docker).not_to receive(:run)
        orchestrator.deploy(name: :redis)
      end

      it 'returns already_running result' do
        result = orchestrator.deploy(name: :redis)
        expect(result[:already_running]).to be true
      end
    end

    context 'with proxy configuration' do
      let(:container_id) { 'admin123456' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return(container_id)
        allow(mock_docker).to receive(:running?).and_return(true)
        allow(mock_ssh).to receive(:execute).with(/docker inspect/).and_return('/myapp-admin')
      end

      it 'adds to Caddy' do
        expect(mock_caddy).to receive(:add_upstream).with(
          service: 'myapp-admin',
          hosts: ['admin.example.com'],
          upstream: 'myapp-admin:8080',
          ssl: true,
          ssl_email: 'admin@example.com'
        )

        orchestrator.deploy(name: :admin)
      end
    end

    context 'when dependency does not exist in config' do
      it 'raises ConfigError' do
        expect do
          orchestrator.deploy(name: :nonexistent)
        end.to raise_error(Odysseus::ConfigError, /not found/)
      end
    end
  end

  describe '#remove' do
    before do
      allow(mock_docker).to receive(:list).and_return([
                                                        { 'ID' => 'redis123', 'Names' => 'myapp-redis',
                                                          'State' => 'running' }
                                                      ])
      allow(mock_docker).to receive(:stop)
      allow(mock_docker).to receive(:remove)
    end

    it 'stops and removes the container' do
      expect(mock_docker).to receive(:stop).with('redis123')
      expect(mock_docker).to receive(:remove).with('redis123', force: true)
      orchestrator.remove(name: :redis)
    end

    it 'removes from Caddy if proxy configured' do
      allow(mock_docker).to receive(:list).and_return([
                                                        { 'ID' => 'admin123', 'Names' => 'myapp-admin',
                                                          'State' => 'running' }
                                                      ])

      expect(mock_caddy).to receive(:drain_upstream).with(
        service: 'myapp-admin',
        upstream: 'myapp-admin:8080'
      )

      orchestrator.remove(name: :admin)
    end
  end

  describe '#upgrade' do
    context 'when dependency exists and is running' do
      let(:container_id) { 'redis123456' * 4 }
      let(:new_container_id) { 'redis789abc' * 4 }

      before do
        allow(mock_docker).to receive(:pull)
        running = [{ 'ID' => container_id, 'Names' => 'myapp-redis', 'State' => 'running' }]
        allow(mock_docker).to receive(:list).with(service: 'myapp-redis', all: true).and_return(running)
        allow(mock_docker).to receive(:stop)
        allow(mock_docker).to receive(:remove)
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:wait_healthy).and_return(true)
      end

      it 'pulls the new image first' do
        expect(mock_docker).to receive(:pull).with('redis:7-alpine').ordered
        expect(mock_docker).to receive(:stop).ordered
        orchestrator.upgrade(name: :redis)
      end

      it 'stops and removes the old container' do
        expect(mock_docker).to receive(:stop).with(container_id, timeout: 30)
        expect(mock_docker).to receive(:remove).with(container_id, force: true)
        orchestrator.upgrade(name: :redis)
      end

      it 'starts a new container with the same config' do
        expect(mock_docker).to receive(:run).with(
          name: 'myapp-redis',
          image: 'redis:7-alpine',
          options: hash_including(
            service: 'myapp-redis',
            network: 'odysseus',
            volumes: ['/var/lib/redis:/data']
          )
        ).and_return(new_container_id)

        orchestrator.upgrade(name: :redis)
      end

      it 'waits for healthcheck if configured' do
        expect(mock_docker).to receive(:wait_healthy).with(new_container_id, timeout: 120).and_return(true)
        orchestrator.upgrade(name: :redis)
      end

      it 'returns upgrade result' do
        result = orchestrator.upgrade(name: :redis)
        expect(result[:success]).to be true
        expect(result[:upgraded]).to be true
        expect(result[:service]).to eq('myapp-redis')
      end
    end

    context 'when dependency is not running' do
      let(:new_container_id) { 'redis789abc' * 4 }

      before do
        allow(mock_docker).to receive(:pull)
        allow(mock_docker).to receive(:list).with(service: 'myapp-redis', all: true).and_return([])
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:wait_healthy).and_return(true)
      end

      it 'pulls image and starts container without needing to stop anything' do
        expect(mock_docker).to receive(:pull).with('redis:7-alpine')
        expect(mock_docker).not_to receive(:stop)
        expect(mock_docker).to receive(:run).and_return(new_container_id)

        orchestrator.upgrade(name: :redis)
      end
    end

    context 'with proxy configuration' do
      let(:container_id) { 'admin123456' * 4 }
      let(:new_container_id) { 'admin789abc' * 4 }

      before do
        allow(mock_docker).to receive(:pull)
        running = [{ 'ID' => container_id, 'Names' => 'myapp-admin', 'State' => 'running' }]
        allow(mock_docker).to receive(:list).with(service: 'myapp-admin', all: true).and_return(running)
        allow(mock_docker).to receive(:stop)
        allow(mock_docker).to receive(:remove)
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:running?).and_return(true)
        allow(mock_ssh).to receive(:execute).with(/docker inspect/).and_return('/myapp-admin')
      end

      it 'drains from Caddy before stopping' do
        allow(mock_caddy).to receive(:add_upstream)

        expect(mock_caddy).to receive(:drain_upstream).with(
          service: 'myapp-admin',
          upstream: 'myapp-admin:8080'
        ).ordered
        expect(mock_docker).to receive(:stop).ordered

        orchestrator.upgrade(name: :admin)
      end

      it 'adds to Caddy after starting new container' do
        allow(mock_caddy).to receive(:drain_upstream)

        expect(mock_caddy).to receive(:add_upstream).with(
          service: 'myapp-admin',
          hosts: ['admin.example.com'],
          upstream: 'myapp-admin:8080',
          ssl: true,
          ssl_email: 'admin@example.com'
        )

        orchestrator.upgrade(name: :admin)
      end
    end

    context 'when dependency does not exist in config' do
      it 'raises ConfigError' do
        expect do
          orchestrator.upgrade(name: :nonexistent)
        end.to raise_error(Odysseus::ConfigError, /not found/)
      end
    end
  end

  describe '#list_status' do
    it 'returns status of all dependencies' do
      allow(mock_docker).to receive(:list).with(service: 'myapp-redis', all: true).and_return([
                                                                                                { 'ID' => 'redis123',
                                                                                                  'State' => 'running' }
                                                                                              ])
      allow(mock_docker).to receive(:list).with(service: 'myapp-db', all: true).and_return([])
      allow(mock_docker).to receive(:list).with(service: 'myapp-admin', all: true).and_return([
                                                                                                { 'ID' => 'admin123',
                                                                                                  'State' => 'exited' }
                                                                                              ])

      statuses = orchestrator.list_status

      expect(statuses.size).to eq(3)

      redis_status = statuses.find { |s| s[:name] == :redis }
      expect(redis_status[:running]).to be true
      expect(redis_status[:container_id]).to eq('redis123')

      db_status = statuses.find { |s| s[:name] == :db }
      expect(db_status[:running]).to be false

      admin_status = statuses.find { |s| s[:name] == :admin }
      expect(admin_status[:running]).to be false
      expect(admin_status[:has_proxy]).to be true
    end
  end
end
