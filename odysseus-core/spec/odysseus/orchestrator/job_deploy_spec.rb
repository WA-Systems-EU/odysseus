# spec/odysseus/orchestrator/job_deploy_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Orchestrator::JobDeploy do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_docker) { instance_double(Odysseus::Docker::Client) }

  let(:config) do
    {
      service: 'myapp',
      image: 'myapp/image',
      servers: {
        jobs: {
          hosts: ['server1'],
          cmd: 'bundle exec sidekiq',
          healthcheck: {
            cmd: 'pgrep -f sidekiq',
            interval: 30,
            timeout: 10,
            retries: 3
          }
        }
      },
      env: {
        clear: { RAILS_ENV: 'production' },
        secret: []
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
    allow(orchestrator).to receive(:sleep) # Don't actually sleep
    allow(mock_docker).to receive(:volume_exists?).and_return(false)
  end

  describe '#deploy' do
    context 'with healthcheck configured' do
      let(:new_container_id) { 'abc123def456' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:wait_healthy).and_return(true)
        allow(mock_docker).to receive(:cleanup_old_containers).and_return([])
      end

      it 'starts a new container with job config' do
        expect(mock_docker).to receive(:run).with(
          name: /myapp-jobs-v1-\d+/,
          image: 'myapp/image:v1',
          options: hash_including(
            service: 'myapp-jobs',
            cmd: 'bundle exec sidekiq',
            network: 'odysseus'
          )
        ).and_return(new_container_id)

        orchestrator.deploy(image_tag: 'v1', role: :jobs)
      end

      it 'waits for container to be healthy' do
        expect(mock_docker).to receive(:wait_healthy).with(new_container_id, timeout: 120).and_return(true)
        orchestrator.deploy(image_tag: 'v1', role: :jobs)
      end

      it 'returns success result' do
        result = orchestrator.deploy(image_tag: 'v1', role: :jobs)
        expect(result[:success]).to be true
        expect(result[:service]).to eq('myapp-jobs')
      end
    end

    context 'without healthcheck configured' do
      let(:config_no_healthcheck) do
        config.merge(
          servers: {
            worker: {
              hosts: ['server1'],
              cmd: 'bundle exec rake jobs:work'
            }
          }
        )
      end

      let(:orchestrator) { described_class.new(ssh: mock_ssh, config: config_no_healthcheck, logger: silent_logger) }
      let(:new_container_id) { 'abc123def456' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:running?).and_return(true)
        allow(mock_docker).to receive(:cleanup_old_containers).and_return([])
      end

      it 'checks running status instead of healthcheck' do
        expect(mock_docker).not_to receive(:wait_healthy)
        expect(mock_docker).to receive(:running?).with(new_container_id).and_return(true)
        orchestrator.deploy(image_tag: 'v1', role: :worker)
      end
    end

    context 'with existing containers' do
      let(:old_container) { { 'ID' => 'old123' * 10, 'Names' => 'myapp-jobs-old' } }
      let(:new_container_id) { 'new456def789' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([old_container])
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:wait_healthy).and_return(true)
        allow(mock_docker).to receive(:cleanup_old_containers).and_return([])
      end

      it 'gracefully stops old containers' do
        expect(mock_docker).to receive(:stop).with(old_container['ID'], timeout: 30)
        expect(mock_docker).to receive(:remove).with(old_container['ID'])
        orchestrator.deploy(image_tag: 'v1', role: :jobs)
      end
    end

    context 'when container fails health check' do
      let(:new_container_id) { 'failed123456' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:wait_healthy).and_return(false)
      end

      before do
        allow(mock_docker).to receive(:logs).and_return('')
        allow(mock_docker).to receive(:health_status).and_return('unhealthy')
      end

      it 'rolls back and raises error' do
        expect(mock_docker).to receive(:stop).with(new_container_id)
        expect(mock_docker).to receive(:remove).with(new_container_id, force: true)

        expect do
          orchestrator.deploy(image_tag: 'v1', role: :jobs)
        end.to raise_error(Odysseus::DeployError, /failed health checks/)
      end
    end

    context 'with a resolved deploy version' do
      let(:config) do
        super().merge(
          deploy_version: Odysseus::DeployVersion.new(
            version: 'abc123def456', ref: 'main', deployer: 'dev@example.com'
          )
        )
      end

      let(:deploy_log) { instance_double(Odysseus::DeployLog) }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return('new-container-123')
        allow(mock_docker).to receive(:wait_healthy).and_return(true)
        allow(mock_docker).to receive(:cleanup_old_containers).and_return([])
        allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
        allow(deploy_log).to receive(:append)
      end

      it 'names the container after the role and the version' do
        expect(mock_docker).to receive(:run) do |args|
          expect(args[:name]).to start_with('myapp-jobs-abc123def456-')
          expect(args[:options][:version]).to eq('abc123def456')
          'new-container-123'
        end

        orchestrator.deploy(image_tag: 'abc123def456', role: :jobs)
      end

      it 'records the deploy against the service, not the role name' do
        expect(Odysseus::DeployLog).to receive(:new).with(ssh: mock_ssh, service: 'myapp')
                                                    .and_return(deploy_log)
        expect(deploy_log).to receive(:append).with(hash_including(role: :jobs))

        orchestrator.deploy(image_tag: 'abc123def456', role: :jobs)
      end
    end
  end
end
