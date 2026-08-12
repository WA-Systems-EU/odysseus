# spec/odysseus/deployer/executor_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Deployer::Executor do
  let(:fixture_file) { fixture_path('deploy.yml') }
  let(:executor) { described_class.new(fixture_file) }

  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_orchestrator) { instance_double(Odysseus::Orchestrator::WebDeploy) }

  before do
    allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
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

  describe '#deploy_all' do
    before do
      allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
      allow(mock_orchestrator).to receive(:deploy).and_return({ success: true })
    end

    it 'deploys to all hosts for each role' do
      # The fixture has web role with app1.example.com host
      expect(Odysseus::Deployer::SSH).to receive(:new).with(
        host: 'app1.example.com',
        user: 'root',
        keys: ['~/.ssh/id_ed25519'],
        use_tailscale: true,
        verbose: false
      ).and_return(mock_ssh)

      executor.deploy_all(image_tag: 'v1.0')
    end

    it 'returns results keyed by role@host' do
      results = executor.deploy_all(image_tag: 'v1.0')
      expect(results).to have_key('web@app1.example.com')
      expect(results['web@app1.example.com'][:success]).to be true
    end

    context 'with dry_run: true' do
      it 'does not connect to server' do
        expect(Odysseus::Deployer::SSH).not_to receive(:new)
        executor.deploy_all(image_tag: 'v1.0', dry_run: true)
      end

      it 'outputs deploy info' do
        expect { executor.deploy_all(image_tag: 'v1.0', dry_run: true) }
          .to output(/Dry run/).to_stdout
      end
    end
  end

  describe '#deploy_role' do
    context 'with dry_run: true' do
      it 'does not connect to server' do
        expect(Odysseus::Deployer::SSH).not_to receive(:new)
        executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web, dry_run: true)
      end

      it 'outputs deploy info' do
        expect { executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web, dry_run: true) }
          .to output(/Dry run/).to_stdout
      end

      it 'returns success result' do
        result = executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web, dry_run: true)
        expect(result[:success]).to be true
        expect(result[:dry_run]).to be true
      end
    end

    context 'with dry_run: false' do
      before do
        allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(mock_orchestrator).to receive(:deploy).and_return({ success: true })
      end

      it 'connects to the server with correct config' do
        expect(Odysseus::Deployer::SSH).to receive(:new).with(
          host: 'test-server',
          user: 'root',
          keys: ['~/.ssh/id_ed25519'],
          use_tailscale: true,
          verbose: false
        ).and_return(mock_ssh)

        executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web)
      end

      it 'creates orchestrator with SSH and config' do
        expect(Odysseus::Orchestrator::WebDeploy).to receive(:new).with(
          ssh: mock_ssh,
          config: hash_including(service: 'myapp', image: 'myapp-production'),
          logger: anything,
          secrets_loader: instance_of(Odysseus::Secrets::Loader)
        ).and_return(mock_orchestrator)

        executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web)
      end

      it 'calls orchestrator deploy with image tag' do
        expect(mock_orchestrator).to receive(:deploy)
          .with(image_tag: 'v1.0', role: :web)
          .and_return({ success: true })

        executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web)
      end

      it 'passes role to orchestrator' do
        mock_job_orchestrator = instance_double(Odysseus::Orchestrator::JobDeploy)
        allow(Odysseus::Orchestrator::JobDeploy).to receive(:new).and_return(mock_job_orchestrator)
        allow(mock_job_orchestrator).to receive(:deploy).and_return({ success: true })

        expect(mock_job_orchestrator).to receive(:deploy)
          .with(image_tag: 'v1.0', role: :worker)
          .and_return({ success: true })

        executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :worker)
      end

      it 'uses JobDeploy for non-web roles' do
        mock_job_orchestrator = instance_double(Odysseus::Orchestrator::JobDeploy)

        expect(Odysseus::Orchestrator::JobDeploy).to receive(:new)
          .with(ssh: mock_ssh, config: anything, logger: anything, secrets_loader: anything)
          .and_return(mock_job_orchestrator)
        allow(mock_job_orchestrator).to receive(:deploy).and_return({ success: true })

        executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :jobs)
      end

      it 'closes SSH connection when done' do
        expect(mock_ssh).to receive(:close)
        executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web)
      end

      it 'closes SSH connection even on error' do
        allow(mock_orchestrator).to receive(:deploy)
          .and_raise(Odysseus::DeployError.new('Deploy failed'))

        expect(mock_ssh).to receive(:close)

        expect { executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web) }
          .to raise_error(Odysseus::DeployError)
      end

      it 'returns orchestrator result' do
        allow(mock_orchestrator).to receive(:deploy)
          .and_return({ success: true, container_id: 'abc123' })

        result = executor.deploy_role(host: 'test-server', image_tag: 'v1.0', role: :web)
        expect(result[:success]).to be true
        expect(result[:container_id]).to eq('abc123')
      end
    end
  end

  describe '#deploy_version' do
    let(:resolver) { instance_double(Odysseus::VersionResolver) }
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
    end

    before do
      allow(Odysseus::VersionResolver).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:resolve).and_return(resolved)
    end

    it 'resolves against the directory holding deploy.yml' do
      expect(Odysseus::VersionResolver)
        .to receive(:new).with(config_dir: File.dirname(fixture_file), logger: anything)
        .and_return(resolver)

      executor.deploy_version
    end

    it 'passes an explicit tag through to the resolver' do
      expect(resolver).to receive(:resolve).with(image_tag: 'v9').and_return(resolved)

      executor.deploy_version('v9')
    end

    it 'resolves only once for the same tag' do
      expect(resolver).to receive(:resolve).once.and_return(resolved)

      executor.deploy_version
      executor.deploy_version
    end

    it 'hands the resolved version to the orchestrator inside the config' do
      allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
      allow(mock_orchestrator).to receive(:deploy).and_return({ success: true })

      expect(Odysseus::Orchestrator::WebDeploy).to receive(:new).with(
        ssh: mock_ssh,
        config: hash_including(deploy_version: resolved),
        logger: anything,
        secrets_loader: anything
      ).and_return(mock_orchestrator)

      executor.deploy_role(host: 'test-server', image_tag: nil, role: :web)
    end

    it 'deploys the resolved version when no tag is given' do
      allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)

      expect(mock_orchestrator).to receive(:deploy)
        .with(image_tag: 'abc123def456', role: :web)
        .and_return({ success: true })

      executor.deploy_role(host: 'test-server', image_tag: nil, role: :web)
    end
  end
end
