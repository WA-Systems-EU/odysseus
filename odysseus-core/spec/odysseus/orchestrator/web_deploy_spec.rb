# spec/odysseus/orchestrator/web_deploy_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Orchestrator::WebDeploy do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
  let(:mock_caddy) { instance_double(Odysseus::Caddy::Client) }

  let(:config) do
    {
      service: 'myapp',
      image: 'myapp-prod',
      servers: {
        web: {
          hosts: ['server1'],
          options: { memory: '2g' }
        }
      },
      proxy: {
        hosts: ['app.example.com'],
        app_port: 3000,
        healthcheck: {
          path: '/health',
          interval: 10,
          timeout: 5
        }
      },
      env: {
        clear: { 'RAILS_ENV' => 'production' },
        secret: ['SECRET_KEY']
      },
      ssh: { user: 'root', keys: [] }
    }
  end

  let(:silent_logger) do
    Object.new.tap do |l|
      def l.info(_msg); end
      def l.warn(_msg); end
      def l.error(_msg); end
    end
  end

  let(:orchestrator) do
    described_class.new(ssh: mock_ssh, config: config, logger: silent_logger)
  end

  before do
    allow(Odysseus::Docker::Client).to receive(:new).and_return(mock_docker)
    allow(Odysseus::Caddy::Client).to receive(:new).and_return(mock_caddy)

    # Default mock behaviors
    allow(mock_caddy).to receive(:running?).and_return(false)
    allow(mock_caddy).to receive(:ensure_running).and_return(true)
    allow(mock_docker).to receive(:list).and_return([])
    allow(mock_docker).to receive(:run).and_return('new-container-123')
    allow(mock_docker).to receive(:wait_healthy).and_return(true)
    allow(mock_caddy).to receive(:add_upstream)
    allow(mock_ssh).to receive(:execute).and_return("/myapp-20231215\n")
    allow(mock_docker).to receive(:cleanup_old_containers).and_return([])
    allow(mock_caddy).to receive(:cleanup_stale_upstreams).and_return([])
    allow(mock_docker).to receive(:volume_exists?).and_return(false)
  end

  describe '#deploy' do
    it 'ensures Caddy is running first' do
      expect(mock_caddy).to receive(:ensure_running).and_return(true)
      orchestrator.deploy(image_tag: 'v1.0')
    end

    it 'raises error if Caddy fails to start' do
      allow(mock_caddy).to receive(:ensure_running).and_return(false)

      expect { orchestrator.deploy(image_tag: 'v1.0') }
        .to raise_error(Odysseus::DeployError, /Failed to start Caddy/)
    end

    it 'checks for existing containers' do
      expect(mock_docker).to receive(:list).with(service: 'myapp').and_return([])
      orchestrator.deploy(image_tag: 'v1.0')
    end

    it 'starts new container with correct config' do
      expect(mock_docker).to receive(:run) do |args|
        expect(args[:image]).to eq('myapp-prod:v1.0')
        expect(args[:options][:service]).to eq('myapp')
        expect(args[:options][:memory]).to eq('2g')
        expect(args[:options][:network]).to eq('odysseus')
        'new-container-123'
      end

      orchestrator.deploy(image_tag: 'v1.0')
    end

    it 'waits for container to become healthy' do
      expect(mock_docker).to receive(:wait_healthy)
        .with('new-container-123', timeout: 60)
        .and_return(true)

      orchestrator.deploy(image_tag: 'v1.0')
    end

    it 'raises error if health check fails' do
      allow(mock_docker).to receive(:wait_healthy).and_return(false)
      allow(mock_docker).to receive(:stop)
      allow(mock_docker).to receive(:remove)
      allow(mock_docker).to receive(:logs).and_return('')
      allow(mock_docker).to receive(:health_status).and_return('unhealthy')

      expect { orchestrator.deploy(image_tag: 'v1.0') }
        .to raise_error(Odysseus::DeployError, /failed health checks/)
    end

    context 'when proxy.healthcheck is not configured' do
      # Config::Parser yields an empty hash for a missing healthcheck block.
      let(:config) do
        super().merge(proxy: { hosts: ['app.example.com'], app_port: 3000, healthcheck: {} })
      end

      it 'still gives the container a health command so it can become healthy' do
        expect(mock_docker).to receive(:run) do |args|
          expect(args[:options][:healthcheck]).to include(
            cmd: a_string_including('http://localhost:3000/')
          )
          'new-container-123'
        end

        orchestrator.deploy(image_tag: 'v1.0')
      end
    end

    context 'when the role has no app_port to probe' do
      let(:config) { super().merge(proxy: {}) }

      it 'fails fast with a config error rather than timing out on health checks' do
        expect(mock_docker).not_to receive(:run)

        expect { orchestrator.deploy(image_tag: 'v1.0') }
          .to raise_error(Odysseus::ConfigError, /app_port/)
      end
    end

    it 'adds new container to Caddy' do
      expect(mock_caddy).to receive(:add_upstream).with(
        service: 'myapp',
        hosts: ['app.example.com'],
        upstream: 'myapp-20231215:3000',
        healthcheck: config[:proxy][:healthcheck],
        ssl: config[:proxy][:ssl],
        ssl_email: config[:proxy][:ssl_email]
      )

      orchestrator.deploy(image_tag: 'v1.0')
    end

    context 'with existing containers' do
      let(:old_container) { { 'ID' => 'old-container-456' } }

      before do
        allow(mock_docker).to receive(:list).and_return([old_container])
        allow(mock_caddy).to receive(:drain_upstream)
        allow(mock_docker).to receive(:stop)
        allow(mock_docker).to receive(:remove)
        allow(orchestrator).to receive(:sleep) # Don't wait in tests
      end

      it 'drains old container from Caddy' do
        expect(mock_caddy).to receive(:drain_upstream).with(
          service: 'myapp',
          upstream: 'myapp-20231215:3000'
        )

        orchestrator.deploy(image_tag: 'v1.0')
      end

      it 'stops old container' do
        expect(mock_docker).to receive(:stop).with('old-container-456')
        orchestrator.deploy(image_tag: 'v1.0')
      end

      it 'removes old container' do
        expect(mock_docker).to receive(:remove).with('old-container-456')
        orchestrator.deploy(image_tag: 'v1.0')
      end
    end

    it 'cleans up old stopped containers' do
      expect(mock_docker).to receive(:cleanup_old_containers)
        .with(service: 'myapp', keep: 2)

      orchestrator.deploy(image_tag: 'v1.0')
    end

    it 'returns success result' do
      result = orchestrator.deploy(image_tag: 'v1.0')

      expect(result[:success]).to be true
      expect(result[:container_id]).to eq('new-container-123')
      expect(result[:service]).to eq('myapp')
      expect(result[:image]).to eq('myapp-prod:v1.0')
    end
  end

  describe 'rollback on failure' do
    before do
      allow(mock_docker).to receive(:wait_healthy).and_return(false)
      allow(mock_docker).to receive(:stop)
      allow(mock_docker).to receive(:remove)
      allow(mock_docker).to receive(:logs).and_return('')
      allow(mock_docker).to receive(:health_status).and_return('unhealthy')
    end

    it 'stops failed container' do
      expect(mock_docker).to receive(:stop).with('new-container-123')

      expect { orchestrator.deploy(image_tag: 'v1.0') }
        .to raise_error(Odysseus::DeployError)
    end

    it 'removes failed container' do
      expect(mock_docker).to receive(:remove).with('new-container-123', force: true)

      expect { orchestrator.deploy(image_tag: 'v1.0') }
        .to raise_error(Odysseus::DeployError)
    end
  end
end
