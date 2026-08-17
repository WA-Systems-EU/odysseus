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
      # These examples are about deploying, not pruning; the 'image retention'
      # context below exercises the prune pass itself.
      allow(executor).to receive(:prune_old_images)
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

    context 'image retention' do
      let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
      let(:deploy_log) { instance_double(Odysseus::DeployLog) }

      before do
        # Undo the enclosing block's blanket stub: these examples are the ones
        # actually exercising the prune pass, unlike the plain deploy examples
        # above.
        allow(executor).to receive(:prune_old_images).and_call_original
        allow(Odysseus::Docker::Client).to receive(:new).and_return(mock_docker)
        allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
        allow(deploy_log).to receive(:append)
        allow(deploy_log).to receive(:entries).and_return(
          [Odysseus::DeployLog::Entry.new(at: '2026-08-01T09:00:00Z', version: 'v_old', role: 'web',
                                          ref: 'main', deployer: 'dev@example.com',
                                          kind: 'deployed', from: nil)]
        )
        allow(mock_docker).to receive(:image_tags).with('myapp-production').and_return(%w[v_old])
        allow(mock_docker).to receive(:versions_in_use).and_return([])
        allow(mock_docker).to receive(:remove_image)
      end

      # retain_versions defaults to 5 and the log has one entry, so nothing is
      # eligible — which is why this asserts the sweep *ran* by checking the
      # host was read, not by checking a removal happened.
      it 'sweeps each host after deploying' do
        expect(mock_docker).to receive(:versions_in_use)

        executor.deploy_all(image_tag: 'v1.0')
      end

      it 'does not touch any host on a dry run' do
        expect(mock_docker).not_to receive(:versions_in_use)
        expect(mock_docker).not_to receive(:remove_image)

        executor.deploy_all(image_tag: 'v1.0', dry_run: true)
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
      # web1 serves web then cron (config order), web2 serves only web,
      # jobs1 serves only jobs. Constrained by the exact label each role
      # actually carries (Docker::Labels.service_for) rather than answering
      # identically for every filter — an unconstrained stub cannot tell a
      # correct filter from a wrong one, which is how the fleet-survey bug
      # (only the web role's containers were ever found) escaped every
      # per-task review.
      allow(mock_docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.service=myapp,odysseus.version=v2' }]
      )
      allow(mock_docker).to receive(:list).with(service: 'myapp-jobs').and_return(
        [{ 'ID' => 'abc', 'Labels' => 'odysseus.service=myapp-jobs,odysseus.version=v2' }]
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

      # jobs1 only ever serves the :jobs role, so #current must come from the
      # 'myapp-jobs' label JobDeploy actually writes, not the bare service
      # name WebDeploy writes. Before the fix, every host was queried under
      # the bare name, so a worker-only host always reported nothing running.
      it 'reports the running version of a host serving only a non-web role' do
        jobs_survey = multihost.version_survey.find { |s| s.host == 'jobs1.example.com' }

        expect(jobs_survey.current).to eq('v2')
      end

      # web1 serves web and cron, in that config order. With web down, the
      # survey must fall through to cron rather than reporting nil.
      it 'falls through to a second role on a host when the first is not serving' do
        allow(mock_docker).to receive(:list).with(service: 'myapp').and_return([])
        allow(mock_docker).to receive(:list).with(service: 'myapp-cron').and_return(
          [{ 'ID' => 'abc', 'Labels' => 'odysseus.service=myapp-cron,odysseus.version=v3' }]
        )

        web1_survey = multihost.version_survey.find { |s| s.host == 'web1.example.com' }

        expect(web1_survey.current).to eq('v3')
      end
    end

    describe '#host_roles' do
      # respond_to? alone would also pass by accident if some other change
      # made this true without anyone deciding it should be — the return
      # value below is what actually grounds "this is public API" in
      # behaviour a caller (odysseus doctor) depends on.
      it 'is public, so callers outside Executor can ask which hosts a config targets' do
        expect(multihost).to respond_to(:host_roles)
      end

      it 'maps every host to the roles it serves, in config order, without listing a shared host twice' do
        expect(multihost.host_roles).to eq(
          'web1.example.com' => %i[web cron],
          'web2.example.com' => %i[web],
          'jobs1.example.com' => %i[jobs]
        )
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

      # This is what carries a from= into jobs1's deploys.log line for a
      # rollback: RollbackCommands writes it from plan.from_for(host), which
      # reads plan.replacing[host]. A worker-only host whose current version
      # was never seen (the bug in Finding 1) would carry nil here instead,
      # silently losing the audit record.
      it 'carries a non-nil replacing value for a worker-only host' do
        plan = multihost.rollback_plan

        expect(plan.replacing['jobs1.example.com']).to eq('v2')
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

    describe 'retention and rollback' do
      # A non-empty log, unlike the outer describe block's default: an empty
      # log makes RetentionSweeper skip the host before ever calling
      # versions_in_use (see retention_sweeper_spec.rb), which would make
      # 'surveys each host once' below vacuously true no matter how many
      # hosts prune_old_images actually reached.
      before do
        allow(deploy_log).to receive(:entries).and_return(
          [Odysseus::DeployLog::Entry.new(at: '2026-08-01T09:00:00Z', version: 'v1', role: 'web',
                                          ref: 'main', deployer: 'dev@example.com',
                                          kind: 'deployed', from: nil)]
        )
        # Constrained by the exact label(s) each host's containers actually
        # carry, the same reasoning as the mock_docker.list stubs above and
        # guarding the same bug: an unconstrained double cannot tell a correct
        # label from the bare service name, which is how the fleet-survey bug
        # escaped every per-task review before.
        allow(mock_docker).to receive(:versions_in_use).with(%w[myapp myapp-cron]).and_return([])
        allow(mock_docker).to receive(:versions_in_use).with(['myapp']).and_return([])
        allow(mock_docker).to receive(:versions_in_use).with(['myapp-jobs']).and_return([])
        allow(mock_docker).to receive(:remove_image)
      end

      # Deleting images during a recovery is the wrong moment, and the version
      # just rolled back FROM is the most likely next thing wanted.
      it 'does not prune when rolling back' do
        # Six deploys logged against the default retain of five, with the
        # oldest (v1) present on the host and not in use: if the sweep ran
        # despite this being a rollback, v1 would genuinely be eligible for
        # removal. Without this, "not_to receive(:remove_image)" would hold
        # even if pruning ran, since a single-entry log (the describe block's
        # default) never has anything eligible either way.
        versions = %w[v1 v2 v3 v4 v5 v6]
        allow(deploy_log).to receive(:entries).and_return(
          versions.each_with_index.map do |version, i|
            Odysseus::DeployLog::Entry.new(
              at: format('2026-08-%<day>02dT09:00:00Z', day: i + 1), version: version, role: 'web',
              ref: 'main', deployer: 'dev@example.com', kind: 'deployed', from: nil
            )
          end
        )
        allow(mock_docker).to receive(:image_tags).with('myapp-production').and_return(versions.reverse)

        plan = Odysseus::RollbackPlan.new(version: 'v1', ref: 'main', approximate: false,
                                          replacing: { 'web1.example.com' => 'v2',
                                                       'web2.example.com' => 'v2',
                                                       'jobs1.example.com' => 'v2' })
        allow(Odysseus::Orchestrator::WebDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(Odysseus::Orchestrator::JobDeploy).to receive(:new).and_return(mock_orchestrator)
        allow(mock_orchestrator).to receive(:deploy).and_return(success: true)

        expect(mock_docker).not_to receive(:remove_image)

        multihost.rollback_all(plan)
      end

      it 'surveys each host once even when a host serves two roles' do
        expect(mock_docker).to receive(:versions_in_use).exactly(3).times.and_return([])

        multihost.prune_old_images
      end

      # The unconstrained double above can't tell a correct label from a wrong
      # one. web1 serves web + cron and jobs1 serves only jobs, so a
      # container_labels that answered with the bare service name for every
      # host (identical to what Labels.service_for returns for :web alone)
      # would still call versions_in_use three times without ever being
      # caught by a call-count assertion. A wrong label here is worse than a
      # bad report: versions_in_use is the only thing protecting a
      # running-but-old version from deletion, which is exactly the state a
      # host is in right after a rollback.
      it 'protects containers under the exact label each role carries, not the bare service name' do
        expect(mock_docker).to receive(:versions_in_use).with(%w[myapp myapp-cron]).and_return([])
        expect(mock_docker).to receive(:versions_in_use).with(['myapp']).and_return([])
        expect(mock_docker).to receive(:versions_in_use).with(['myapp-jobs']).and_return([])

        multihost.prune_old_images
      end

      # The brief's central guarantee: a host that cannot be reached at all
      # must not fail a deploy that already succeeded. Raising from #entries,
      # rather than from remove_image, is what actually reaches sweep_host's
      # own rescue: a removal failure is swallowed by prune_image's own
      # rescue first, and never gets anywhere near this one.
      it 'keeps sweeping the other hosts when one cannot be read at all' do
        calls = 0
        allow(deploy_log).to receive(:entries) do
          calls += 1
          raise IOError, 'connection reset' if calls == 1

          [Odysseus::DeployLog::Entry.new(at: '2026-08-01T09:00:00Z', version: 'v1', role: 'web',
                                          ref: 'main', deployer: 'dev@example.com',
                                          kind: 'deployed', from: nil)]
        end

        result = nil
        expect { result = multihost.prune_old_images }.not_to raise_error

        expect(result['web1.example.com']).to eq([])
        expect(mock_docker).to have_received(:versions_in_use).with(['myapp']).once
        expect(mock_docker).to have_received(:versions_in_use).with(['myapp-jobs']).once
      end
    end
  end
end
