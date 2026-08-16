# spec/odysseus/cli/cli_spec.rb
#
# Unit-level cover for the command objects. The executor is always a double:
# nothing here may reach a server.

require 'spec_helper'

RSpec.describe Odysseus::CLI::CLI do
  subject(:cli) { described_class.new(debug: true) }

  let(:config_file) { fixture_path('deploy.yml') }
  let(:executor) { instance_double(Odysseus::Deployer::Executor) }

  before do
    allow(Odysseus::Deployer::Executor).to receive(:new).and_return(executor)
  end

  # Commands print to $stdout and exit on failure. Buffer that chatter here so it
  # stays readable after a SystemExit escapes the block.
  let(:stdout_buffer) { StringIO.new }

  def output_of
    original = $stdout
    $stdout = stdout_buffer
    begin
      yield
    ensure
      $stdout = original
    end
    stdout_buffer.string
  end

  describe '#deploy' do
    let(:build_result) do
      { build: { success: true }, pussh: { success: true }, push: { success: true } }
    end
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'v1.2.3', ref: 'main', deployer: 'dev@example.com')
    end

    before { allow(executor).to receive(:deploy_version).and_return(resolved) }

    it 'deploys the requested tag without building by default' do
      expect(executor).to receive(:deploy_all).with(image_tag: 'v1.2.3', dry_run: false)
      expect(executor).not_to receive(:build_and_distribute)

      output_of { cli.deploy(config: config_file, image: 'v1.2.3') }
    end

    it 'builds and distributes first when asked' do
      expect(executor).to receive(:build_and_distribute)
        .with(image_tag: 'v1.2.3').and_return(build_result)
      allow(executor).to receive(:deploy_all)

      output_of { cli.deploy(config: config_file, image: 'v1.2.3', build: true) }
    end

    it 'passes dry-run through' do
      expect(executor).to receive(:deploy_all).with(image_tag: nil, dry_run: true)

      output_of { cli.deploy(config: config_file, 'dry-run': true) }
    end

    it 'reports a failed build and exits non-zero without deploying' do
      allow(executor).to receive(:build_and_distribute)
        .and_return(build: { success: false, error: 'Dockerfile not found' })
      expect(executor).not_to receive(:deploy_all)

      expect { output_of { cli.deploy(config: config_file, build: true) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('Dockerfile not found')
    end

    it 'reports a failed deploy and exits non-zero' do
      allow(executor).to receive(:deploy_all)
        .and_raise(Odysseus::DeployError, 'Container failed health checks')

      expect { output_of { cli.deploy(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('Container failed health checks')
    end
  end

  describe 'version handling' do
    let(:resolved) do
      Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
    end

    before { allow(executor).to receive(:deploy_version).and_return(resolved) }

    it 'lets the executor resolve the version when --image is absent' do
      expect(executor).to receive(:deploy_all).with(image_tag: nil, dry_run: false)

      output_of { cli.deploy(config: config_file) }
    end

    it 'passes --image through when given' do
      expect(executor).to receive(:deploy_all).with(image_tag: 'v9', dry_run: false)

      output_of { cli.deploy(config: config_file, image: 'v9') }
    end

    it 'shows the resolved version in the deploy header' do
      allow(executor).to receive(:deploy_all)

      expect(output_of { cli.deploy(config: config_file) }).to include('abc123def456')
    end

    it 'reports a dirty tree without deploying' do
      allow(executor).to receive(:deploy_version)
        .and_raise(Odysseus::ConfigError, 'The working tree has uncommitted changes')
      expect(executor).not_to receive(:deploy_all)

      expect { output_of { cli.deploy(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('uncommitted changes')
    end

    # Pins current behaviour: the version resolves before the dry-run branch is
    # reached, so --dry-run still requires a resolvable version even though it
    # has no side effects to protect. Whether to relax this is a product
    # decision, not made in this pass.
    it 'refuses --dry-run in a dirty tree rather than printing a plan' do
      allow(executor).to receive(:deploy_version)
        .and_raise(Odysseus::ConfigError, 'The working tree has uncommitted changes')
      expect(executor).not_to receive(:deploy_all)

      expect { output_of { cli.deploy(config: config_file, 'dry-run': true) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('uncommitted changes')
    end
  end

  describe '#app_exec' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
    end

    it 'runs the version that is currently serving' do
      allow(docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Image' => 'myapp-production:abc123def456', 'Labels' => 'odysseus.version=abc123def456' }]
      )

      expect(docker).to receive(:run_once)
        .with(image: 'myapp-production:abc123def456', command: 'true', options: anything)
        .and_return('done')

      output_of { cli.app_exec('web1.example.com', config: config_file, command: 'true') }
    end

    # This is the regression the reviewer verified live: every container deployed
    # before this branch carries a timestamp in odysseus.version and was built
    # from an image tagged `latest`. Reconstructing "#{image}:#{version}" from
    # that label produces a tag that was never pushed. The container's own
    # Image field is what docker ps actually reports as running, so that is
    # what a one-off container must run instead.
    it 'runs the container Image, not a tag reconstructed from a legacy timestamp label' do
      allow(docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Image' => 'myapp-production:latest', 'Labels' => 'odysseus.version=20260101120000' }]
      )

      expect(docker).to receive(:run_once)
        .with(image: 'myapp-production:latest', command: 'true', options: anything)
        .and_return('done')

      output_of { cli.app_exec('web1.example.com', config: config_file, command: 'true') }
    end

    it 'exits non-zero when nothing is running for the service' do
      allow(docker).to receive(:list).with(service: 'myapp').and_return([])

      expect { output_of { cli.app_exec('web1.example.com', config: config_file, command: 'true') } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to match(/no running container/i)
    end
  end

  # Every container carries odysseus.service=<label>, and Docker::Labels
  # decides that label: the bare service name for the web role,
  # "<service>-<role>" for every other. docker ps filters on an exact match, so
  # a command that searches the bare name finds nothing on a jobs host — and
  # nothing anywhere at all for a service that has no web role.
  #
  # These examples are deliberately not on the web role: there
  # `service_for` and the bare service name are byte-identical, so an
  # assertion made against a web fixture is satisfied by the bug as readily as
  # by the fix.
  describe 'app commands on a non-web role' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }
    let(:worker_only) { fixture_path('worker-only.yml') }
    let(:jobs_containers) do
      [{ 'ID' => 'abc', 'Image' => 'myapp-production:abc123def456',
         'Labels' => 'odysseus.service=myapp-jobs,odysseus.version=abc123def456' }]
    end

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
      allow(cli).to receive(:system).and_return(true)
    end

    it 'exec asks for the label the jobs role carries, not the bare service' do
      allow(docker).to receive(:list).with(service: 'myapp-jobs').and_return(jobs_containers)
      expect(docker).to receive(:run_once)
        .with(image: 'myapp-production:abc123def456', command: 'true', options: anything)
        .and_return('done')

      output_of { cli.app_exec('worker1.example.com', config: config_file, command: 'true', role: 'jobs') }
    end

    it 'shell asks for the label the jobs role carries' do
      expect(docker).to receive(:list).with(service: 'myapp-jobs').and_return(jobs_containers)

      output_of { cli.app_shell('worker1.example.com', config: config_file, role: 'jobs') }
    end

    it 'console asks for the label the jobs role carries' do
      expect(docker).to receive(:list).with(service: 'myapp-jobs').and_return(jobs_containers)

      output_of { cli.app_console('worker1.example.com', config: config_file, role: 'jobs') }
    end

    # A worker-only service deploys through JobDeploy and passes validate, so
    # nothing it runs is ever labelled with the bare service name. Before
    # --role reached these commands there was no host at all on which they
    # worked, and no workaround.
    it 'exec works for a service that has no web role at all' do
      allow(docker).to receive(:list).with(service: 'myapp-jobs').and_return(jobs_containers)
      expect(docker).to receive(:run_once)
        .with(image: 'myapp-production:abc123def456', command: 'true', options: anything)
        .and_return('done')

      output_of { cli.app_exec('worker1.example.com', config: worker_only, command: 'true', role: 'jobs') }
    end

    it 'still looks up the bare service name when no role is named' do
      allow(docker).to receive(:list).with(service: 'myapp').and_return(
        [{ 'ID' => 'abc', 'Image' => 'myapp-production:latest', 'Labels' => 'odysseus.service=myapp' }]
      )
      expect(docker).to receive(:run_once)
        .with(image: 'myapp-production:latest', command: 'true', options: anything)
        .and_return('done')

      output_of { cli.app_exec('web1.example.com', config: config_file, command: 'true') }
    end

    it 'names the role, the label it searched and the option that changes it' do
      allow(docker).to receive(:list).with(service: 'myapp-jobs').and_return([])

      expect { output_of { cli.app_exec('worker1.example.com', config: config_file, command: 'true', role: 'jobs') } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }

      expect(stdout_buffer.string).to include('jobs')
      expect(stdout_buffer.string).to include('myapp-jobs')
      expect(stdout_buffer.string).to include('--role')
    end

    # Execing against a role other than the one you named is worse than being
    # told what to type, so the failure must not search anywhere else.
    it 'does not fall back to another role when the named one has nothing running' do
      allow(docker).to receive(:list).with(service: 'myapp-jobs').and_return([])
      expect(docker).not_to receive(:list).with(service: 'myapp')

      expect { output_of { cli.app_exec('worker1.example.com', config: config_file, command: 'true', role: 'jobs') } }
        .to raise_error(SystemExit)
    end
  end

  # `logs` had no examples at all before this group, which is how it shipped
  # reading only running containers for four releases: it asked docker ps
  # without -a, so the container you most want the logs of — the one that just
  # exited — was invisible, and the command said so and exited 0.
  describe '#logs' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }
    let(:running) { { 'ID' => 'aaaaaaaaaaaa', 'State' => 'running' } }
    let(:exited) { { 'ID' => 'bbbbbbbbbbbb', 'State' => 'exited' } }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
    end

    it 'asks docker for stopped containers as well as running ones' do
      expect(docker).to receive(:list).with(service: 'myapp', all: true).and_return([running])
      allow(docker).to receive(:logs).and_return('hello')

      output_of { cli.logs('web1.example.com', config: config_file) }
    end

    it 'reads the logs of a container that has exited' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([exited])
      expect(docker).to receive(:logs).with('bbbbbbbbbbbb', tail: 100, since: nil).and_return('segfault')

      expect(output_of { cli.logs('web1.example.com', config: config_file) }).to include('segfault')
    end

    # cleanup_old_containers keeps the previous two deploys on purpose, so a
    # stopped container alongside a running one is the normal state of a host,
    # not an edge case. The running one is the one being asked about.
    it 'prefers the running container when stopped ones are also present' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([exited, running])
      expect(docker).to receive(:logs).with('aaaaaaaaaaaa', tail: 100, since: nil).and_return('hello')

      output_of { cli.logs('web1.example.com', config: config_file) }
    end

    it 'says the container is stopped rather than ending its logs without explanation' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([exited])
      allow(docker).to receive(:logs).and_return('segfault')

      out = output_of { cli.logs('web1.example.com', config: config_file) }

      expect(out).to match(/stopped|exited/i)
      expect(out).to include('bbbbbbbbbbbb')
    end

    it 'does not claim a stopped container when the logs come from a running one' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([running])
      allow(docker).to receive(:logs).and_return('hello')

      expect(output_of { cli.logs('web1.example.com', config: config_file) }).not_to match(/stopped|exited/i)
    end

    # A request for logs that produced none is a failed request. Exiting 0 told
    # every caller — a script, a CI step, a person in a hurry — that it worked.
    it 'exits non-zero when there is no container at all, running or stopped' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([])

      expect { output_of { cli.logs('web1.example.com', config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('myapp')
    end

    it 'reads the role named by --role' do
      allow(docker).to receive(:list).with(service: 'myapp-jobs', all: true).and_return([running])
      allow(docker).to receive(:logs).and_return('working')

      expect(output_of { cli.logs('worker1.example.com', config: config_file, role: 'jobs') })
        .to include('working')
    end

    it 'follows and passes --lines and --since through' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([running])
      expect(docker).to receive(:logs).with('aaaaaaaaaaaa', follow: true, tail: 50, since: '10m')

      output_of { cli.logs('web1.example.com', config: config_file, follow: true, lines: 50, since: '10m') }
    end
  end

  describe '#dependency_logs' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }
    let(:exited) { { 'ID' => 'cccccccccccc', 'State' => 'exited' } }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
    end

    it 'reads the logs of a dependency that has exited' do
      allow(docker).to receive(:list).with(service: 'myapp-db', all: true).and_return([exited])
      expect(docker).to receive(:logs).with('cccccccccccc', tail: 100, since: nil).and_return('FATAL: out of memory')

      out = output_of { cli.dependency_logs('db.example.com', config: config_file, name: 'db') }

      expect(out).to include('FATAL: out of memory')
      expect(out).to match(/stopped|exited/i)
    end

    it 'exits non-zero when the dependency has no container at all' do
      allow(docker).to receive(:list).with(service: 'myapp-db', all: true).and_return([])

      expect { output_of { cli.dependency_logs('db.example.com', config: config_file, name: 'db') } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('myapp-db')
    end
  end

  describe '#validate' do
    it 'summarises a valid config' do
      out = output_of { cli.validate(config: config_file) }

      expect(out).to include('Configuration is valid')
      expect(out).to include('myapp')
      expect(out).to include('web')
      expect(out).to include('db')
    end

    it 'exits non-zero for a config that cannot be parsed' do
      expect { output_of { cli.validate(config: 'no-such-file.yml') } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe '#dependency_boot' do
    it 'boots the named dependency' do
      expect(executor).to receive(:deploy_dependency).with(name: 'db')

      output_of { cli.dependency_boot(config: config_file, name: 'db') }
    end

    it 'exits non-zero when no name is given' do
      expect { output_of { cli.dependency_boot(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe '#dependency_boot_all' do
    it 'boots every configured dependency' do
      expect(executor).to receive(:boot_dependencies)

      output_of { cli.dependency_boot_all(config: config_file) }
    end
  end

  describe '#secrets_generate_key' do
    it 'prints a key that can be used as a master key' do
      out = output_of { cli.secrets_generate_key }

      expect(out).to match(/[0-9a-f]{64}/)
      expect(out).to include('ODYSSEUS_MASTER_KEY')
    end
  end

  describe '#secrets_encrypt' do
    it 'exits non-zero without an input file' do
      expect { output_of { cli.secrets_encrypt } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end

    it 'round-trips secrets through an encrypted file' do
      key = Odysseus::Secrets::EncryptedFile.generate_key
      dir = Dir.mktmpdir
      plain = File.join(dir, 'secrets.yml')
      encrypted = File.join(dir, 'secrets.yml.enc')
      File.write(plain, { 'DATABASE_URL' => 'postgres://user:pass@db/app' }.to_yaml)

      begin
        with_master_key(key) do
          output_of { cli.secrets_encrypt(input: plain, file: encrypted) }

          expect(File).to exist(encrypted)
          expect(File.read(encrypted)).not_to include('postgres://user:pass@db/app')

          out = output_of { cli.secrets_decrypt(file: encrypted) }
          expect(out).to include('DATABASE_URL')
          expect(out).not_to include('postgres://user:pass@db/app')
        end
      ensure
        FileUtils.remove_entry(dir)
      end
    end
  end

  describe '#status' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }
    let(:caddy) { instance_double(Odysseus::Caddy::Client) }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
      allow(Odysseus::Caddy::Client).to receive(:new).and_return(caddy)
      allow(caddy).to receive(:status).and_return(running: false, services: [], tls: { enabled: false })
      allow(docker).to receive(:list).and_return([])
      allow(docker).to receive(:list).with(service: 'myapp').and_return(
        [{
          'ID' => 'abc123abc123',
          'Names' => 'myapp-abc123def456-20260812112759',
          'State' => 'running',
          'Status' => 'Up 8 minutes (healthy)',
          'Image' => 'myapp-production:latest',
          # The version label is deliberately distinct from the Names/Image fields above:
          # they legitimately embed abc123def456 too (a real container is named after its
          # version), so only a substring unique to the label can prove status read it.
          'Labels' => 'odysseus.service=myapp,odysseus.version=deadbeef9876,' \
                      'odysseus.deployed_at=2026-08-12T11:27:59Z,odysseus.git_ref=main'
        }]
      )
    end

    it 'reports the version, ref and deploy time of the running container' do
      out = output_of { cli.status('web1.example.com', config: config_file) }

      expect(out).to include('deadbeef9876')
      expect(out).to include('main')
      expect(out).to include('2026-08-12T11:27:59Z')
    end

    it 'reports the running container Image' do
      out = output_of { cli.status('web1.example.com', config: config_file) }

      expect(out).to include('myapp-production:latest')
    end

    it 'does not report an unhealthy container as healthy' do
      allow(docker).to receive(:list).with(service: 'myapp').and_return(
        [{
          'ID' => 'abc123abc123',
          'Names' => 'myapp-abc123def456-20260812112759',
          'State' => 'running',
          'Status' => 'Up 8 minutes (unhealthy)',
          'Image' => 'myapp-production:latest',
          'Labels' => 'odysseus.service=myapp,odysseus.version=deadbeef9876,' \
                      'odysseus.deployed_at=2026-08-12T11:27:59Z,odysseus.git_ref=main'
        }]
      )

      out = output_of { cli.status('web1.example.com', config: config_file) }

      expect(out).not_to include('✓')
    end
  end

  describe '#rollback' do
    let(:plan) do
      Odysseus::RollbackPlan.new(
        version: 'v1', ref: 'main', approximate: false,
        replacing: { 'web1.example.com' => 'v2' }
      )
    end

    before { allow(executor).to receive(:rollback_plan).and_return(plan) }

    it 'rolls back to the planned version' do
      expect(executor).to receive(:rollback_all).with(plan)

      output_of { cli.rollback(config: config_file) }
    end

    it 'shows the target version before acting' do
      allow(executor).to receive(:rollback_all)

      out = output_of { cli.rollback(config: config_file) }

      expect(out).to include('v1')
      expect(out).not_to match(/deploy log/i)
    end

    it 'shows the commit the target was built from' do
      allow(executor).to receive(:rollback_all)

      expect(output_of { cli.rollback(config: config_file) }).to include('main')
    end

    it 'announces completion as a rollback, not a deploy' do
      allow(executor).to receive(:rollback_all)

      out = output_of { cli.rollback(config: config_file) }

      expect(out).to match(/rollback complete/i)
      expect(out).not_to match(/deployment successful/i)
    end

    it 'passes an explicit version through to the planner' do
      expect(executor).to receive(:rollback_plan).with(version: 'v0').and_return(plan)
      allow(executor).to receive(:rollback_all)

      output_of { cli.rollback(config: config_file, version: 'v0') }
    end

    it 'warns when the ordering is only approximate' do
      approximate = Odysseus::RollbackPlan.new(
        version: 'v1', ref: nil, approximate: true, replacing: {}
      )
      allow(executor).to receive(:rollback_plan).and_return(approximate)
      allow(executor).to receive(:rollback_all)

      expect(output_of { cli.rollback(config: config_file) }).to match(/approximate/i)
    end

    it 'says there is no deploy log record when an explicit version is approximate' do
      approximate = Odysseus::RollbackPlan.new(
        version: 'v0', ref: nil, approximate: true, replacing: {}
      )
      allow(executor).to receive(:rollback_plan).with(version: 'v0').and_return(approximate)
      allow(executor).to receive(:rollback_all)

      out = output_of { cli.rollback(config: config_file, version: 'v0') }

      expect(out).to match(/deploy log/i)
      expect(out).not_to match(/approximate/i)
    end

    it 'reports a refused rollback and exits non-zero without deploying' do
      allow(executor).to receive(:rollback_plan)
        .and_raise(Odysseus::RollbackError, 'No image tagged v1 is present on web2.example.com')
      expect(executor).not_to receive(:rollback_all)

      expect { output_of { cli.rollback(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('web2.example.com')
    end

    it 'reports a failed rollback and exits non-zero' do
      allow(executor).to receive(:rollback_all)
        .and_raise(Odysseus::DeployError, 'Container failed health checks')

      expect { output_of { cli.rollback(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stdout_buffer.string).to include('failed health checks')
    end
  end

  describe '#rollback --list' do
    let(:entry) do
      Odysseus::DeployLog::Entry.new(
        at: '2026-08-12T11:27:59Z', version: 'v2', role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
    end
    let(:older) do
      Odysseus::DeployLog::Entry.new(
        at: '2026-08-10T09:00:00Z', version: 'v1', role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
    end
    let(:survey) do
      [Odysseus::HostVersions.new(
        host: 'web1.example.com', current: 'v2', available: %w[v2], history: [older, entry]
      )]
    end

    before { allow(executor).to receive(:version_survey).and_return(survey) }

    it 'lists each host and what it is serving' do
      out = output_of { cli.rollback(config: config_file, list: true) }

      expect(out).to include('web1.example.com')
      expect(out).to include('v2')
    end

    it 'marks a version whose image is gone as unavailable' do
      out = output_of { cli.rollback(config: config_file, list: true) }

      # v1 is not in `available`, so its row — and only its row — must read 'missing'.
      row = out.lines.find { |line| line =~ /^\s*v1\b/ }
      expect(row).to include('missing')
    end

    it 'marks a version whose image is present' do
      out = output_of { cli.rollback(config: config_file, list: true) }

      # v2 is in `available`, so its row — and only its row — must read 'present'.
      row = out.lines.find { |line| line =~ /^\s*v2\b/ }
      expect(row).to include('present')
    end

    it 'does not roll anything back' do
      expect(executor).not_to receive(:rollback_all)
      expect(executor).not_to receive(:rollback_plan)

      output_of { cli.rollback(config: config_file, list: true) }
    end

    it 'says so when a host has no deploy history' do
      allow(executor).to receive(:version_survey).and_return(
        [Odysseus::HostVersions.new(host: 'web1.example.com', current: nil,
                                    available: [], history: [])]
      )

      expect(output_of { cli.rollback(config: config_file, list: true) })
        .to match(/no deploy history/i)
    end

    # A version deployed twice must sort by its LATEST deploy, not its
    # first, and must display that latest deploy's timestamp. v2 is
    # deployed, then v1, then v2 again: v2's newest entry (Aug 3) is more
    # recent than v1's only entry (Aug 1), so v2 belongs above v1, showing
    # Aug 3 — not v2's own first deploy on Aug 2. This is
    # RollbackPlanner#logged_versions' candidate order, not necessarily
    # what a plain `odysseus rollback` would target: the planner then
    # skips candidates that are already serving somewhere or unavailable
    # on some host.
    #
    # v1 and v2's first deploys straddle different sides of v2's redeploy
    # (v1 earliest, v2's first deploy second) so that latest-deploy
    # ordering and first-deploy ordering disagree — a fixture where the
    # redeployed version also happened to deploy first would pass under
    # either rule and prove nothing.
    it 'orders a redeployed version by its latest deploy, and shows that latest deploy time' do
      first_v1 = Odysseus::DeployLog::Entry.new(
        at: '2026-08-01T09:00:00Z', version: 'v1', role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
      first_v2 = Odysseus::DeployLog::Entry.new(
        at: '2026-08-02T09:00:00Z', version: 'v2', role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
      redeployed_v2 = Odysseus::DeployLog::Entry.new(
        at: '2026-08-03T09:00:00Z', version: 'v2', role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
      allow(executor).to receive(:version_survey).and_return(
        [Odysseus::HostVersions.new(
          host: 'web1.example.com', current: 'v2', available: %w[v1 v2],
          history: [first_v1, first_v2, redeployed_v2]
        )]
      )

      out = output_of { cli.rollback(config: config_file, list: true) }
      rows = out.lines.grep(/^\s*v[12]\b/)

      expect(rows.first).to match(/^\s*v2\b/)
      expect(rows.last).to match(/^\s*v1\b/)
      expect(rows.first).to include('2026-08-03T09:00:00Z')
      expect(rows.first).not_to include('2026-08-02T09:00:00Z')
    end
  end

  def with_master_key(key)
    previous = ENV.fetch('ODYSSEUS_MASTER_KEY', nil)
    ENV['ODYSSEUS_MASTER_KEY'] = key
    yield
  ensure
    ENV['ODYSSEUS_MASTER_KEY'] = previous
  end
end
