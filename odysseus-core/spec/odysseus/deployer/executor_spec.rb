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
    # Executor now records every successful deploy_role unconditionally (see
    # 'recording the deploy on the host' below), so any test that reaches
    # deploy_role needs DeployLog silenced unless it is specifically
    # exercising recording, where the describe block below overrides this.
    allow(Odysseus::DeployLog).to receive(:new).and_return(instance_double(Odysseus::DeployLog, append: nil))
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

      # Pins current behaviour: the version resolves before the dry-run branch
      # is reached, so a dry run in a dirty tree still raises instead of
      # printing a plan. Whether to relax this is a product decision, not made
      # in this pass.
      it 'still requires a resolvable version, since resolution happens before the dry-run check' do
        resolver = instance_double(Odysseus::VersionResolver)
        allow(Odysseus::VersionResolver).to receive(:new).and_return(resolver)
        allow(resolver).to receive(:resolve)
          .and_raise(Odysseus::ConfigError, 'The working tree has uncommitted changes')

        expect { executor.deploy_role(host: 'test-server', image_tag: nil, role: :web, dry_run: true) }
          .to raise_error(Odysseus::ConfigError, /uncommitted changes/)
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

  describe 'recording the deploy on the host' do
    let(:deploy_log) { instance_double(Odysseus::DeployLog) }
    let(:resolver) { instance_double(Odysseus::VersionResolver) }
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
    end

    before do
      allow(Odysseus::VersionResolver).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:resolve).and_return(resolved)
      allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
      allow(deploy_log).to receive(:append)
      # The top-level before stubs SSH.new and #close only; each describe block
      # stubs its own orchestrator. Without this the real WebDeploy is built and
      # #deploy reaches the Docker client.
      allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
      allow(mock_orchestrator).to receive(:deploy).and_return(success: true)
    end

    it 'records the version, role, ref and deployer for the service' do
      expect(Odysseus::DeployLog).to receive(:new).with(ssh: mock_ssh, service: 'myapp')
                                                  .and_return(deploy_log)
      expect(deploy_log).to receive(:append).with(
        version: 'abc123def456', role: :web, ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )

      executor.deploy_role(host: 'app1.example.com', role: :web)
    end

    it 'records nothing when the orchestrator raises' do
      allow(mock_orchestrator).to receive(:deploy)
        .and_raise(Odysseus::DeployError, 'Container failed health checks')
      expect(deploy_log).not_to receive(:append)

      expect { executor.deploy_role(host: 'app1.example.com', role: :web) }
        .to raise_error(Odysseus::DeployError)
    end

    it 'still reports success when the log cannot be written' do
      allow(deploy_log).to receive(:append).and_raise(Odysseus::SSHCommandError, 'read-only fs')

      expect(executor.deploy_role(host: 'app1.example.com', role: :web)).to include(success: true)
    end

    # Net::SSH::Disconnect, IOError and Net::SSH::ChannelOpenFailed all
    # propagate through SSH#execute untranslated. Traffic has already switched
    # to the new container by this point, so none of them may turn a completed
    # deploy into a reported failure.
    it 'still reports success when writing the log raises a raw connection error' do
      allow(deploy_log).to receive(:append).and_raise(IOError, 'connection reset')

      expect(executor.deploy_role(host: 'app1.example.com', role: :web)).to include(success: true)
    end

    it 'closes the connection even when recording fails' do
      allow(deploy_log).to receive(:append).and_raise(IOError, 'connection reset')
      expect(mock_ssh).to receive(:close)

      executor.deploy_role(host: 'app1.example.com', role: :web)
    end

    it 'records the role that was deployed, not the web role' do
      job_orchestrator = instance_double(Odysseus::Orchestrator::JobDeploy, deploy: { success: true })
      allow(Odysseus::Orchestrator::JobDeploy).to receive(:new).and_return(job_orchestrator)
      expect(deploy_log).to receive(:append).with(hash_including(role: :jobs))

      executor.deploy_role(host: 'app1.example.com', role: :jobs)
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

  describe 'rollback' do
    let(:multihost) { described_class.new(fixture_path('deploy-multihost.yml')) }
    let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
    let(:deploy_log) { instance_double(Odysseus::DeployLog) }

    # The fixture's cron role names deploy.strategy: rolling, and the config
    # validator refuses a strategy that is not registered (validators/config.rb:88)
    # — so the sail has to exist before the config parses. That makes every
    # example here exercise a sail-deployed role alongside the built-in
    # orchestrators, which is what pins "a sail role gets recorded too".
    let(:sail_class) do
      Class.new do
        def initialize(ssh:, config:, logger:, secrets_loader:); end

        def deploy(image_tag:, role:)
          { success: true, image_tag: image_tag, role: role }
        end
      end
    end

    # sails_spec.rb:8 and validators/config_spec.rb:182 both guard the global
    # registry with around/reset!; match that so example order cannot matter.
    around do |example|
      Odysseus::Sails.reset!
      Odysseus::Sails.register(:rolling, sail_class)
      example.run
      Odysseus::Sails.reset!
    end

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
      allow(mock_ssh).to receive(:close)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(mock_docker)
      allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
      allow(deploy_log).to receive(:append)
      allow(deploy_log).to receive(:entries).and_return([])
      allow(mock_docker).to receive(:list).and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.version=v2' }]
      )
      allow(mock_docker).to receive(:image_tags).and_return(%w[v2 v1])
    end

    describe '#version_survey' do
      # The fixture has four role/host pairs over three hosts: cron shares
      # web1 with web. Surveying a host twice would open two connections and
      # report it twice in rollback --list.
      it 'reports one entry per host even when a host serves two roles' do
        expect(multihost.version_survey.map(&:host))
          .to eq(%w[web1.example.com web2.example.com jobs1.example.com])
      end

      it 'closes every connection it opened' do
        expect(mock_ssh).to receive(:close).exactly(3).times

        multihost.version_survey
      end

      it 'closes the connection even when reading a host fails' do
        allow(mock_docker).to receive(:image_tags).and_raise(Odysseus::SSHCommandError, 'no docker')
        expect(mock_ssh).to receive(:close).at_least(:once)

        expect { multihost.version_survey }.to raise_error(Odysseus::SSHCommandError)
      end
    end

    describe '#rollback_plan' do
      it 'plans against every host, not just the first' do
        plan = multihost.rollback_plan

        expect(plan.version).to eq('v1')
        expect(plan.replacing.keys)
          .to eq(%w[web1.example.com web2.example.com jobs1.example.com])
      end

      it 'refuses when the target is missing on one host' do
        tags = { 'web1.example.com' => %w[v2 v1], 'web2.example.com' => %w[v2],
                 'jobs1.example.com' => %w[v2 v1] }
        seen = []
        allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
          seen << args[:host]
          mock_ssh
        end
        allow(mock_docker).to receive(:image_tags) { tags.fetch(seen.last) }

        expect { multihost.rollback_plan(version: 'v1') }
          .to raise_error(Odysseus::RollbackError, /web2\.example\.com/)
      end
    end

    describe '#rollback_all' do
      # web2 deliberately differs from web1 and jobs1 so the from: lookup is
      # provably per host rather than a value hoisted out of the loop (e.g.
      # plan.replacing.values.first, which would pass every other example
      # here unnoticed since they all shared 'v2').
      let(:plan) do
        Odysseus::RollbackPlan.new(
          version: 'v1', ref: 'main', approximate: false,
          replacing: { 'web1.example.com' => 'v2', 'web2.example.com' => 'v3',
                       'jobs1.example.com' => 'v2' }
        )
      end

      before do
        allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(Odysseus::Orchestrator::JobDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(mock_orchestrator).to receive(:deploy).and_return(success: true)
      end

      it 'deploys the planned version to every role on every host' do
        expect(mock_orchestrator).to receive(:deploy).with(image_tag: 'v1', role: :web).twice
        expect(mock_orchestrator).to receive(:deploy).with(image_tag: 'v1', role: :jobs).once

        multihost.rollback_all(plan)
      end

      it 'returns results keyed by role@host, including a shared host twice' do
        expect(multihost.rollback_all(plan).keys).to contain_exactly(
          'web@web1.example.com', 'web@web2.example.com',
          'jobs@jobs1.example.com', 'cron@web1.example.com'
        )
      end

      # cron is deployed by the sail, not by WebDeploy or JobDeploy. Before
      # recording moved into Executor, a sail-deployed role left no trace in
      # deploys.log at all, which would make it invisible to a later rollback.
      it 'records a role that a sail strategy deployed' do
        expect(deploy_log).to receive(:append).with(hash_including(role: :cron))

        multihost.rollback_all(plan)
      end

      it 'records the rollback as such, naming the version it came from' do
        expect(deploy_log).to receive(:append).with(
          hash_including(version: 'v1', kind: 'rolled-back', from: 'v2')
        ).at_least(:once)

        multihost.rollback_all(plan)
      end

      it 'records a distinct from value per host rather than one hoisted for the whole run' do
        expect(deploy_log).to receive(:append).with(hash_including(role: :web, from: 'v2')).once
        expect(deploy_log).to receive(:append).with(hash_including(role: :web, from: 'v3')).once

        multihost.rollback_all(plan)
      end

      it 'carries the commit ref recovered by the plan into the record' do
        expect(deploy_log).to receive(:append).with(hash_including(ref: 'main')).at_least(:once)

        multihost.rollback_all(plan)
      end

      it 'names who ran the rollback rather than leaving it blank' do
        expect(deploy_log).to receive(:append)
          .with(hash_including(deployer: a_string_matching(/\S/))).at_least(:once)

        multihost.rollback_all(plan)
      end

      # The label a container carries must be the version it is actually
      # running, or status and the next rollback both lie.
      it 'labels the rolled-back container with the target version' do
        expect(Odysseus::Orchestrator::WebDeploy).to receive(:new) do |args|
          expect(args[:config][:deploy_version].version).to eq('v1')
          mock_orchestrator
        end.at_least(:once)

        multihost.rollback_all(plan)
      end
    end
  end
end
