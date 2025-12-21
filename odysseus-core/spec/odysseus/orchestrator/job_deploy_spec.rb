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

  let(:orchestrator) { described_class.new(ssh: mock_ssh, config: config) }

  before do
    allow(Odysseus::Docker::Client).to receive(:new).with(mock_ssh).and_return(mock_docker)
    allow(orchestrator).to receive(:sleep) # Don't actually sleep
  end

  describe '#deploy' do
    context 'with healthcheck configured' do
      let(:new_container_id) { 'abc123def456' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:wait_healthy).and_return(true)
        allow(mock_docker).to receive(:cleanup_old_containers)
      end

      it 'starts a new container with job config' do
        expect(mock_docker).to receive(:run).with(
          name: /myapp-jobs-\d+/,
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

      let(:orchestrator) { described_class.new(ssh: mock_ssh, config: config_no_healthcheck) }
      let(:new_container_id) { 'abc123def456' * 4 }

      before do
        allow(mock_docker).to receive(:list).and_return([])
        allow(mock_docker).to receive(:run).and_return(new_container_id)
        allow(mock_docker).to receive(:running?).and_return(true)
        allow(mock_docker).to receive(:cleanup_old_containers)
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
        allow(mock_docker).to receive(:cleanup_old_containers)
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

      it 'rolls back and raises error' do
        expect(mock_docker).to receive(:stop).with(new_container_id)
        expect(mock_docker).to receive(:remove).with(new_container_id, force: true)

        expect {
          orchestrator.deploy(image_tag: 'v1', role: :jobs)
        }.to raise_error(Odysseus::DeployError, /failed health checks/)
      end
    end
  end
end
