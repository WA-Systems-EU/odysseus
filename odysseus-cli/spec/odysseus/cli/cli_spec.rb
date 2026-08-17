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
  #
  # Both streams are buffered, and separately: which one a message went to is
  # itself under test. `odysseus logs web1 > app.log` is the command most
  # likely to be redirected, so its own diagnostics must not be in what the
  # redirect captures.
  let(:stdout_buffer) { StringIO.new }
  let(:stderr_buffer) { StringIO.new }

  def output_of
    original = [$stdout, $stderr]
    $stdout = stdout_buffer
    $stderr = stderr_buffer
    begin
      yield
    ensure
      $stdout, $stderr = original
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
      expect(stderr_buffer.string).to match(/no running container/i)
    end
  end

  # `app exec` builds an environment and hands it to run_once, which writes the
  # env file. run_once is core's code, but "the secret reaches the container and
  # not the process list" is a claim about the strings that arrive at the host —
  # so this group drives the real Docker::Client over a doubled connection and
  # reads what was actually sent, rather than trusting a doubled run_once.
  describe 'what app exec sends to the host' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil, user: 'root') }
    let(:awkward) { fixture_path('awkward-env.yml') }
    let(:secret_url) { "postgres://app:it's a pass@db.internal/app" }
    let(:executed) { [] }
    let(:uploaded) { [] }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(ssh).to receive(:upload_string) { |content, path, mode:| uploaded << [content, path, mode] }
      allow(ssh).to receive(:execute) do |command|
        executed << command
        case command
        when /\Adocker ps/ then '{"ID":"abc123abc123","Image":"myapp-production:latest"}'
        when /\Aecho \$/ then "#{secret_url}\n"
        else ''
        end
      end
    end

    it 'writes the secret into a 0600 env file under /var/lib/odysseus/env' do
      output_of { cli.app_exec('web1.example.com', config: awkward, command: 'rails db:migrate') }

      content, path, mode = uploaded.last
      expect(content).to include("DATABASE_URL=#{secret_url}")
      expect(path).to start_with('/var/lib/odysseus/env/')
      expect(mode).to eq(0o600)
    end

    it 'names no environment value in any command it sends' do
      output_of { cli.app_exec('web1.example.com', config: awkward, command: 'rails db:migrate') }

      run = executed.find { |command| command.start_with?('docker run') }
      expect(run).to match(%r{--env-file /var/lib/odysseus/env/one-off@\h+\.env})
      [secret_url, 'My App <hi@x.com>', "it's fine"].each do |value|
        expect(executed.join("\n")).not_to include(value)
      end
    end

    # A relative secrets_file is relative to deploy.yml, not to wherever the
    # command was typed — the rule Loader already applies for deploys. The
    # config here is in a directory the suite never chdirs to, so a loader
    # built with the working directory finds no secrets file and the command
    # fails outright rather than quietly injecting less.
    it 'resolves a relative secrets_file against the directory holding deploy.yml' do
      dir = Dir.mktmpdir
      key = Odysseus::Secrets::EncryptedFile.generate_key
      File.write(File.join(dir, 'deploy.yml'), <<~YAML)
        service: myapp
        image: myapp-production
        secrets_file: secrets.yml.enc
        servers:
          web:
            hosts:
              - web1.example.com
        env:
          secret:
            - DATABASE_URL
        ssh:
          user: deploy
          keys:
            - ~/.ssh/id_ed25519
      YAML

      begin
        with_master_key(key) do
          encrypted = Odysseus::Secrets::EncryptedFile.new(File.join(dir, 'secrets.yml.enc'))
          encrypted.write({ 'DATABASE_URL' => secret_url })

          # Wrapped rather than called bare: a loader built with the working
          # directory raises ConfigError, which app_exec turns into `exit 1`,
          # and RSpec does not rescue SystemExit. Without this the mutant would
          # take the whole run down instead of failing one example.
          expect do
            output_of { cli.app_exec('web1.example.com', config: File.join(dir, 'deploy.yml'), command: 'true') }
          end.not_to raise_error
        end

        expect(uploaded.last.first).to include("DATABASE_URL=#{secret_url}")
      ensure
        FileUtils.remove_entry(dir)
      end
    end

    # The three examples above all connect as root, where HostPaths never asks
    # the host anything — so none of them would notice HostPaths breaking for
    # a deploy user. This one connects as a non-root user and gives it a home
    # directory unrelated to the username, on purpose: if HostPaths were ever
    # rewritten to build the path from the username instead of asking the host
    # for $HOME, a home like "/home/odysseus" would still satisfy this
    # assertion by coincidence. A fixture home that shares nothing with the
    # username can only pass if the code actually uses what the host reports.
    context 'when the connected user is not root' do
      let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus') }
      let(:home) { '/srv/state/7f3c1' }

      before do
        allow(ssh).to receive(:execute) do |command|
          executed << command
          case command
          when /\Aecho \$HOME\z/ then "#{home}\n"
          when /\Adocker ps/ then '{"ID":"abc123abc123","Image":"myapp-production:latest"}'
          when /\Aecho \$/ then "#{secret_url}\n"
          else ''
          end
        end
      end

      it "writes the env file under the deploy user's home, not /var/lib/odysseus" do
        output_of { cli.app_exec('web1.example.com', config: awkward, command: 'rails db:migrate') }

        _content, path, mode = uploaded.last
        expect(path).to start_with("#{home}/.odysseus/env/")
        expect(mode).to eq(0o600)
      end
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
      # Neither fixture here declares any env, so with_env_file writes nothing
      # and yields nil. This group is about which label is looked up.
      allow(docker).to receive(:with_env_file) { |_env, &block| block.call(nil) }
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

      expect(stderr_buffer.string).to include('jobs')
      expect(stderr_buffer.string).to include('myapp-jobs')
      expect(stderr_buffer.string).to include('--role')
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

      output_of { cli.logs('web1.example.com', config: config_file) }

      expect(stderr_buffer.string).to match(/stopped|exited/i)
      expect(stderr_buffer.string).to include('bbbbbbbbbbbb')
    end

    # `odysseus logs web1 > app.log` is the command most likely to be
    # redirected or piped into something that parses it. The notice is about
    # the logs, not part of them, so it belongs on stderr — where it is still
    # on the terminal in front of whoever ran the command.
    it 'keeps the stopped-container notice out of the log stream itself' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([exited])
      allow(docker).to receive(:logs).and_return('segfault')

      out = output_of { cli.logs('web1.example.com', config: config_file) }

      expect(out).to include('segfault')
      expect(out).not_to match(/stopped|exited/i)
      expect(out).not_to include('bbbbbbbbbbbb')
    end

    it 'does not claim a stopped container when the logs come from a running one' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([running])
      allow(docker).to receive(:logs).and_return('hello')

      output_of { cli.logs('web1.example.com', config: config_file) }

      expect(stdout_buffer.string).not_to match(/stopped|exited/i)
      expect(stderr_buffer.string).to be_empty
    end

    # A request for logs that produced none is a failed request. Exiting 0 told
    # every caller — a script, a CI step, a person in a hurry — that it worked.
    it 'exits non-zero when there is no container at all, running or stopped' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([])

      expect { output_of { cli.logs('web1.example.com', config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stderr_buffer.string).to include('myapp')
    end

    # A mistyped --role is the ordinary reason this finds nothing, and the
    # message named only a service label the reader never typed:
    # `No containers found for myapp-jbos on w1 (stopped ones included)`. The
    # equivalent failure in `running_image` had said all of this for a release
    # already — two messages for one job, and only one of them any use.
    it 'names the role, the label it searched, the option and the roles that exist' do
      allow(docker).to receive(:list).with(service: 'myapp-jbos', all: true).and_return([])

      expect { output_of { cli.logs('web1.example.com', config: config_file, role: 'jbos') } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }

      expect(stderr_buffer.string).to include("role 'jbos'")
      expect(stderr_buffer.string).to include('odysseus.service=myapp-jbos')
      expect(stderr_buffer.string).to include('--role')
      expect(stderr_buffer.string).to include('web, jobs')
    end

    it 'keeps the not-found message out of the log stream too' do
      allow(docker).to receive(:list).with(service: 'myapp', all: true).and_return([])

      expect { output_of { cli.logs('web1.example.com', config: config_file) } }
        .to raise_error(SystemExit)

      expect(stdout_buffer.string).not_to match(/no running or stopped container/i)
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
      expect(stderr_buffer.string).to match(/stopped|exited/i)
    end

    it 'exits non-zero when the dependency has no container at all' do
      allow(docker).to receive(:list).with(service: 'myapp-db', all: true).and_return([])

      expect { output_of { cli.dependency_logs('db.example.com', config: config_file, name: 'db') } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(stderr_buffer.string).to include('myapp-db')
    end

    # A dependency is named with --name, not --role: pointing at --role here
    # would send the reader to an option this command does not have.
    it 'names the label it searched without advising --role' do
      allow(docker).to receive(:list).with(service: 'myapp-db', all: true).and_return([])

      expect { output_of { cli.dependency_logs('db.example.com', config: config_file, name: 'db') } }
        .to raise_error(SystemExit)

      expect(stderr_buffer.string).to include('odysseus.service=myapp-db')
      expect(stderr_buffer.string).not_to include('--role')
    end
  end

  # app shell/console and dependency shell hand a terminal over, so they build
  # an ssh command line and run it locally. Nothing had ever driven them, so
  # nothing had ever looked at the string they build — and it passed through
  # two shells with no escaping at either.
  describe 'the commands that shell out over ssh' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }
    let(:awkward) { fixture_path('awkward-env.yml') }
    let(:commands) { [] }
    # awkward-env.yml names DATABASE_URL under env.secret and configures no
    # secrets file, so it resolves from the host's own environment. A space and
    # an apostrophe, so that a value which reached a command line would break it
    # as well as show up in `ps`.
    let(:secret_url) { "postgres://app:it's a pass@db.internal/app" }
    let(:env_file_path) { '/var/lib/odysseus/env/one-off@0123456789abcdef.env' }
    let(:injected) { [] }
    let(:removed) { [] }
    let(:removed_at_session) { [] }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
      allow(ssh).to receive(:execute).with('echo $DATABASE_URL').and_return("#{secret_url}\n")
      allow(docker).to receive(:list).with(service: 'myapp')
                                     .and_return([{ 'ID' => 'abc123abc123', 'Image' => 'myapp-production:latest' }])
      allow(docker).to receive(:list).with(service: 'myapp-db')
                                     .and_return([{ 'ID' => 'db0123456789', 'Image' => 'postgres:16' }])
      # Stands in for Docker::Client#with_env_file, contract and all: it removes
      # the file on the way out however the block left it. That is what lets an
      # example ask both that the session ran while the file still existed and
      # that it was gone once the session ended.
      allow(docker).to receive(:with_env_file) do |env, &block|
        injected << env
        begin
          block.call(env_file_path)
        ensure
          removed << env_file_path
        end
      end
      allow(cli).to receive(:system) do |command|
        commands << command
        removed_at_session << removed.dup
        true
      end
    end

    # The words the LOCAL /bin/sh — the one `system` invokes — would see.
    def local_words
      Shellwords.split(commands.last)
    end

    # The words the REMOTE login shell would see: ssh passes it the last word
    # of the local command line, and splits that into words itself.
    def remote_words
      Shellwords.split(local_words.last)
    end

    it 'builds an ssh command line the local shell reads as ssh, its keys and one remote command' do
      output_of { cli.app_shell('web1.example.com', config: awkward) }

      expect(local_words[0..-2]).to eq(
        ['ssh',
         '-i', File.expand_path('~/.ssh/id_ed25519'),
         '-i', File.expand_path('~/.ssh/deploy key'),
         '-t', 'deploy@web1.example.com']
      )
    end

    # These values used to travel as `-e KEY=VALUE` in this very string, where
    # `ps` on the deploy target shows them to every user on the box. They now go
    # in the 0600 file with_env_file writes; the command carries its path only.
    it 'points docker at an env file rather than naming the values' do
      output_of { cli.app_shell('web1.example.com', config: awkward) }

      expect(remote_words).to eq(
        ['docker', 'run', '-it', '--rm', '--network', 'odysseus',
         '--env-file', env_file_path,
         'myapp-production:latest', '/bin/sh']
      )
    end

    # Asserted over the environment that was actually built, not a list copied
    # from the fixture, so adding a variable to the fixture cannot quietly stop
    # this example from covering it.
    it 'puts no environment value in the command it runs, at either shell layer' do
      output_of { cli.app_shell('web1.example.com', config: awkward) }

      expect(injected.last.values).not_to be_empty
      injected.last.each_value { |value| expect(commands.last).not_to include(value) }
    end

    # The bug this branch fixes: these commands injected env.clear and nothing
    # else, so `app shell` on a host got a container with no DATABASE_URL while
    # the container deployed seconds earlier had one.
    it 'gives the shell the secrets the deployed container has, not env.clear alone' do
      output_of { cli.app_shell('web1.example.com', config: awkward) }

      expect(injected.last).to eq(
        'SMTP_FROM' => 'My App <hi@x.com>',
        'MOTD' => "it's fine",
        'PLAIN' => 'simple',
        'DATABASE_URL' => secret_url
      )
    end

    it 'console injects the same environment, and keeps it out of the command too' do
      output_of { cli.app_console('web1.example.com', config: awkward, cmd: 'rails c') }

      expect(injected.last).to include('DATABASE_URL' => secret_url)
      expect(commands.last).not_to include(secret_url)
    end

    # The session has to run inside the block that holds the file open. Reading
    # the path out of the block and running ssh afterwards would leave docker
    # pointing at a file that had already been removed.
    it 'holds the env file open for the session and removes it afterwards' do
      output_of { cli.app_shell('web1.example.com', config: awkward) }

      expect(removed_at_session.last).to be_empty
      expect(removed).to eq([env_file_path])
    end

    it 'removes the env file when the session exits non-zero' do
      allow(cli).to receive(:system) { |command| commands << command and false }

      expect { output_of { cli.app_shell('web1.example.com', config: awkward) } }
        .to raise_error(SystemExit)
      expect(removed).to eq([env_file_path])
    end

    # with_env_file yields nil when there is nothing to write, so a config with
    # no env at all must not grow an --env-file flag pointing nowhere.
    it 'omits --env-file entirely when the config has no environment' do
      allow(docker).to receive(:with_env_file) { |env, &block| injected << env and block.call(nil) }
      allow(docker).to receive(:list).with(service: 'myapp-jobs')
                                     .and_return([{ 'ID' => 'j0b123456789', 'Image' => 'myapp-production:latest' }])

      output_of { cli.app_shell('worker1.example.com', config: fixture_path('worker-only.yml'), role: 'jobs') }

      expect(remote_words).to eq(
        ['docker', 'run', '-it', '--rm', '--network', 'odysseus',
         'myapp-production:latest', '/bin/sh']
      )
    end

    it 'hands the remote command to the local shell as a single word' do
      output_of { cli.app_shell('web1.example.com', config: awkward) }

      expect(local_words.size).to eq(8)
    end

    it 'console runs the console command, splitting it the way a shell would' do
      output_of { cli.app_console('web1.example.com', config: awkward, cmd: 'rails c') }

      expect(remote_words.last(2)).to eq(%w[rails c])
    end

    # --cmd is a command line, not a filename: escaping it whole would ask
    # docker to exec a program literally called "rails runner puts 1".
    it 'console keeps a quoted argument inside the console command intact' do
      output_of { cli.app_console('web1.example.com', config: awkward, cmd: "rails runner 'puts 1'") }

      expect(remote_words.last(3)).to eq(['rails', 'runner', 'puts 1'])
    end

    it 'console reports a --cmd it cannot read rather than building a broken command' do
      expect { output_of { cli.app_console('web1.example.com', config: awkward, cmd: "rails runner 'oops") } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
      expect(commands).to be_empty
    end

    it 'dependency shell execs into the container it found' do
      output_of { cli.dependency_shell('db.example.com', config: awkward, name: 'db') }

      expect(remote_words).to eq(['docker', 'exec', '-it', 'db0123456789', '/bin/sh'])
    end

    # A failed ssh, a missing image, a docker error: system's return value was
    # discarded, so all of them reported success.
    describe 'when the ssh command fails' do
      before { allow(cli).to receive(:system).and_return(false) }

      it 'app shell exits non-zero' do
        expect { output_of { cli.app_shell('web1.example.com', config: awkward) } }
          .to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
      end

      it 'app console exits non-zero' do
        expect { output_of { cli.app_console('web1.example.com', config: awkward) } }
          .to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
      end

      it 'dependency shell exits non-zero' do
        expect { output_of { cli.dependency_shell('db.example.com', config: awkward, name: 'db') } }
          .to raise_error(SystemExit) { |error| expect(error.status).not_to eq(0) }
      end

      # ssh exits with the remote command's own status, and passing that on is
      # what makes `odysseus app console web1 -- ... && deploy` and a CI step
      # mean anything. Every example above asks only for "not 0", which a flat
      # `exit 1` satisfies as readily as reading $? does — so nothing here
      # distinguished the two until this one. The session really runs
      # `sh -c 'exit 7'`, because $? is what the code under test reads.
      it 'app shell exits with the status the session gave it, not a flat 1' do
        allow(cli).to receive(:system) { |command| commands << command and system('exit 7') }

        expect { output_of { cli.app_shell('web1.example.com', config: awkward) } }
          .to raise_error(SystemExit) { |error| expect(error.status).to eq(7) }
      end
    end

    it 'does not exit non-zero when the session ends normally' do
      expect { output_of { cli.app_shell('web1.example.com', config: awkward) } }.not_to raise_error
    end
  end

  # `odysseus app shell dedalus-prod` printed nothing at all before handing the
  # terminal over: no host, no role, no image, and nothing to say that the
  # `/app $` prompt belongs to a container started for this session rather than
  # the one serving traffic. `app exec` had a header from the start; these two
  # never did.
  #
  # The role is `jobs` throughout, on the fixture with no web role: for `web`
  # the role name and the service name are byte-identical, so a header that
  # printed the service would satisfy the assertion as readily as one that
  # printed the role.
  describe 'the header the interactive sessions print' do
    let(:ssh) { instance_double(Odysseus::Deployer::SSH, close: nil) }
    let(:docker) { instance_double(Odysseus::Docker::Client) }
    let(:worker_only) { fixture_path('worker-only.yml') }
    let(:session_output) { "hello from the container\n" }

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(docker)
      allow(docker).to receive(:list).with(service: 'myapp-jobs')
                                     .and_return([{ 'ID' => 'j0b123456789', 'Image' => 'myapp-production:v9' }])
      allow(docker).to receive(:with_env_file) { |_env, &block| block.call(nil) }
      # Stands in for the session itself, which writes to the terminal's stdout.
      allow(cli).to receive(:system) do
        print session_output
        true
      end
    end

    def shell_stderr
      output_of { cli.app_shell('worker1.example.com', config: worker_only, role: 'jobs') }
      stderr_buffer.string
    end

    def console_stderr
      output_of { cli.app_console('worker1.example.com', config: worker_only, role: 'jobs', cmd: 'rails c') }
      stderr_buffer.string
    end

    it 'names the command it belongs to' do
      expect(shell_stderr).to include('App Shell')
      expect(console_stderr).to include('App Console')
    end

    it 'names the server the session reached' do
      expect(shell_stderr).to include('Server: worker1.example.com')
    end

    # The role, not the label the lookup was made with: `myapp-jobs` is what
    # docker was asked for, `jobs` is what the caller typed and what they would
    # have to type again.
    it 'names the role the container was found under' do
      expect(shell_stderr).to include('Role: jobs')
    end

    it 'names the image that is actually serving, tag and all' do
      expect(shell_stderr).to include('Image: myapp-production:v9')
    end

    it 'names the command the container will run' do
      expect(shell_stderr).to include('Command: /bin/sh')
      expect(console_stderr).to include('Command: rails c')
    end

    # The single most useful thing the header can say, and the thing a prompt
    # in a container invites you to assume the other way round: this is a new
    # container from the serving image, not an attach to the one taking traffic.
    it 'says the container is a new one, that the running app is untouched and that it is discarded' do
      expect(shell_stderr).to match(/new container/i)
      expect(shell_stderr).to match(/running app/i)
      expect(shell_stderr).to match(/discarded/i)
    end

    it 'says the same of the console' do
      expect(console_stderr).to match(/new container/i)
      expect(console_stderr).to match(/discarded/i)
    end

    # `odysseus app console web1 --cmd "rails runner 'puts Thing.count'" > count`
    # is a plausible way to get a value out of a deployment, and a header on
    # stdout would land in the file. The session's own output is the only thing
    # that may reach it.
    it 'writes the header to stderr, leaving stdout to the session' do
      out = output_of { cli.app_shell('worker1.example.com', config: worker_only, role: 'jobs') }

      expect(out).to eq(session_output)
      expect(stderr_buffer.string).to include('worker1.example.com')
    end

    it 'keeps the console header off stdout too' do
      out = output_of do
        cli.app_console('worker1.example.com', config: worker_only, role: 'jobs', cmd: 'rails c')
      end

      expect(out).to eq(session_output)
      expect(stderr_buffer.string).to include('myapp-production:v9')
    end

    # A header naming an image that was never found would be a lie, so it waits
    # for the lookup. Nothing is printed but the failure.
    it 'prints no header when there is no container to name an image from' do
      allow(docker).to receive(:list).with(service: 'myapp-jobs').and_return([])

      expect { output_of { cli.app_shell('worker1.example.com', config: worker_only, role: 'jobs') } }
        .to raise_error(SystemExit)
      expect(stderr_buffer.string).not_to include('App Shell')
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

  describe '#doctor' do
    # Overrides the outer `executor` double: doctor drives the host loop off
    # #host_roles rather than any of the deploy-shaped methods the other
    # describes stub.
    let(:executor) do
      instance_double(
        Odysseus::Deployer::Executor,
        host_roles: { 'web1.example.com' => [:web], 'worker1.example.com' => [:jobs] }
      )
    end

    let(:ok)   { Odysseus::HostVerifier::Result.new(check: :docker, status: :ok, detail: 'docker 29.1.3') }
    let(:warn) { Odysseus::HostVerifier::Result.new(check: :distro, status: :warn, detail: 'debian 12 — deploys work here') }
    let(:bad)  { Odysseus::HostVerifier::Result.new(check: :state_dir, status: :fail, detail: '/home/odysseus/.odysseus is not writable') }

    def run_setup(results, options = {})
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      verifier = instance_double(Odysseus::HostVerifier, verify: results)
      allow(Odysseus::HostVerifier).to receive(:new).and_return(verifier)

      cli.doctor({ config: fixture_path('deploy.yml') }.merge(options))
    end

    it 'reports each check and exits zero when all pass' do
      expect { output_of { run_setup([ok]) } }.not_to raise_error
    end

    it 'exits non-zero when any check fails' do
      expect { output_of { run_setup([ok, bad]) } }.to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    # A warning is information, not a broken host: deploys work on a distro
    # `setup` cannot bootstrap.
    it 'exits zero when the worst result is a warning' do
      expect { output_of { run_setup([ok, warn]) } }.not_to raise_error
    end

    # No other example in this file puts a :warn and a :fail in the same
    # survey. Ranking statuses ok: 0, warn: 2, fail: 1 — instead of the
    # correct ok: 0, warn: 1, fail: 2 — still passes every one of them, and
    # under that ranking a :fail arriving after a :warn cannot raise the
    # recorded worst above :warn, so the run exits zero. That ordering is
    # the common real case: checks run distro first, so a warned distro
    # is typically followed by a later check (docker, on a broken daemon)
    # failing.
    it 'exits non-zero when a warning is followed by a failure' do
      expect { output_of { run_setup([warn, bad]) } }
        .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    # The reverse order is also realistic: worst carries across hosts, so one
    # host's docker check can fail before a later host's distro check warns.
    # This pins that a recorded failure is never downgraded by a later
    # warning — a mutant that assigned the latest status outright, instead of
    # ranking it against the current worst, would still pass the example
    # above (fail is the last status seen there) but would silently clear
    # this survey's failing exit code.
    it 'exits non-zero when a failure is followed by a warning' do
      expect { output_of { run_setup([bad, warn]) } }
        .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    it 'names the failing check and its detail, so the reader can act' do
      output = output_of do
        run_setup([ok, bad])
      rescue SystemExit
        nil
      end

      expect(output).to include('state_dir')
      expect(output).to include('not writable')
    end

    it 'verifies every host in the config, not only the first' do
      hosts = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        hosts << args[:host]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus')
      end
      allow(Odysseus::HostVerifier).to receive(:new)
        .and_return(instance_double(Odysseus::HostVerifier, verify: [ok]))

      output_of { cli.doctor(config: fixture_path('deploy.yml')) }

      # The fixture config's stubbed host_roles names two hosts. Asserting the
      # exact set (not just hosts.uniq.size >= 1, which a single visited host
      # would also satisfy) is what actually catches breaking out of the loop
      # after the first host.
      expect(hosts).to contain_exactly('web1.example.com', 'worker1.example.com')
      expect(hosts).to eq(hosts.uniq) # each host visited once, not once per role
    end

    # Renamed from 'closes every connection it opens, even when a check
    # fails': a :fail Result is a value HostVerifier returns, not a raise, so
    # this pins only the ordinary sequential path through the begin/ensure —
    # it says nothing about what happens when the connection itself dies
    # mid-survey. The context below covers that.
    it 'closes the connection after a check reports a failing result' do
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::HostVerifier).to receive(:new)
        .and_return(instance_double(Odysseus::HostVerifier, verify: [bad]))

      output_of do
        cli.doctor(config: fixture_path('deploy.yml'))
      rescue SystemExit
        nil
      end

      expect(ssh).to have_received(:close).at_least(:once)
    end

    # #verify itself can raise rather than return a :fail Result: a dropped
    # connection mid-check can surface as IOError, Net::SSH::Disconnect (a
    # RuntimeError) or Errno::EPIPE/ECONNRESET (a SystemCallError) — three
    # branches of StandardError with no narrower ancestor in common, so
    # nothing tighter than StandardError could catch all of them in one
    # rescue. doctor's whole purpose is surveying every host, so one host
    # dying this way must not abort the rest of the run.
    context "when a host's check raises instead of returning a result" do
      let(:sshes) { [] }

      before do
        allow(Odysseus::Deployer::SSH).to receive(:new) do
          instance_double(Odysseus::Deployer::SSH, close: nil, user: 'odysseus').tap { |ssh| sshes << ssh }
        end

        raising_verifier = instance_double(Odysseus::HostVerifier)
        allow(raising_verifier).to receive(:verify).and_raise(IOError, 'connection reset')
        ok_verifier = instance_double(Odysseus::HostVerifier, verify: [ok])

        seen = 0
        allow(Odysseus::HostVerifier).to receive(:new) do
          seen += 1
          seen == 1 ? raising_verifier : ok_verifier
        end
      end

      def run
        output_of do
          cli.doctor(config: fixture_path('deploy.yml'))
        rescue SystemExit
          nil
        end
      end

      it 'still visits the other host rather than stopping the survey' do
        run

        expect(sshes.size).to eq(2)
      end

      it 'closes the connection to the host whose check raised' do
        run

        expect(sshes.first).to have_received(:close)
      end

      it "reports the error's class and message, so the reader can tell it from an ordinary failing check" do
        output = run

        expect(output).to include('IOError')
        expect(output).to include('connection reset')
      end

      it 'exits non-zero' do
        expect { output_of { cli.doctor(config: fixture_path('deploy.yml')) } }
          .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
      end
    end
  end

  describe '#setup' do
    # Overrides the outer `executor` double: setup drives the host loop off
    # #host_roles rather than any of the deploy-shaped methods the other
    # describes stub.
    let(:executor) do
      instance_double(
        Odysseus::Deployer::Executor,
        host_roles: { 'web1.example.com' => [:web], 'worker1.example.com' => [:jobs] }
      )
    end

    let(:ok)      { Odysseus::Setup::Preparer::Result.new(step: :docker, status: :ok, detail: 'docker 29.1.3') }
    let(:changed) { Odysseus::Setup::Preparer::Result.new(step: :user, status: :changed, detail: 'created odysseus') }
    let(:warn)    { Odysseus::Setup::Preparer::Result.new(step: :distro, status: :warn, detail: 'debian 12 — deploys work here') }
    let(:bad)     { Odysseus::Setup::Preparer::Result.new(step: :distro, status: :fail, detail: 'debian 12') }

    def run_setup(results, options = {})
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['ssh-ed25519 AAAAtest t@e'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: results))

      cli.setup({ config: fixture_path('deploy.yml') }.merge(options))
    end

    it 'exits zero when every step is ok or changed' do
      expect { output_of { run_setup([ok, changed]) } }.not_to raise_error
    end

    it 'exits non-zero when a step fails' do
      expect { output_of { run_setup([ok, bad]) } }
        .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    # `escalate`'s rank table (setup_commands.rb) has no coverage above this
    # point for :warn at all. Mirrors doctor's analogous pair (cli_spec.rb,
    # `#doctor`) for the same reason: a rank-swap mutation of
    # `{ ok: 0, changed: 0, warn: 1, fail: 2 }` to `warn: 2, fail: 1` passes
    # each ordering alone, because both examples below only ever compare a
    # status against :ok (order value 0), which the swap leaves unchanged.
    # Only seeing both a :warn-then-:fail survey and a :fail-then-:warn
    # survey forces the comparison between :warn and :fail itself.
    it 'exits zero when the worst result is a warning' do
      expect { output_of { run_setup([ok, warn]) } }.not_to raise_error
    end

    it 'exits non-zero when a warning is followed by a failure' do
      expect { output_of { run_setup([warn, bad]) } }
        .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    # The reverse order is also realistic: worst carries across hosts, so one
    # host's fail can be followed by a later host's distro warning. This pins
    # that a recorded failure is never downgraded by a later warning.
    it 'exits non-zero when a failure is followed by a warning' do
      expect { output_of { run_setup([bad, warn]) } }
        .to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    # Asserts on the UI calls rather than on substring presence in the
    # rendered output: `render_result`'s :changed branch calling
    # @ui.step_ok instead of @ui.step_info would still put
    # 'created odysseus' in stdout (step_ok prints the same message text,
    # just with a different icon/color), so a substring-only assertion
    # passes under that mutation. Spying on the CLI's real UI instance
    # (rather than stubbing it, which would need its own render assertions
    # duplicated per icon) lets the example assert directly that :changed
    # was routed to step_info and never to step_ok.
    it 'shows what it changed distinctly from what was already correct' do
      ui = cli.instance_variable_get(:@ui)
      allow(ui).to receive(:step_info).and_call_original
      allow(ui).to receive(:step_ok).and_call_original

      output_of { run_setup([ok, changed]) }

      expect(ui).to have_received(:step_info).with(a_string_matching('created odysseus')).at_least(:once)
      expect(ui).to have_received(:step_ok).with(a_string_matching('docker 29.1.3')).at_least(:once)
      expect(ui).not_to have_received(:step_ok).with(a_string_matching('created odysseus'))
    end

    # The default is the Ubuntu cloud image's user, so a stock image works
    # untouched.
    it 'connects as ubuntu by default' do
      users = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        users << args[:user]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: args[:user])
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [ok]))

      output_of { cli.setup(config: fixture_path('deploy.yml')) }

      expect(users.uniq).to eq(['ubuntu'])
    end

    it 'connects as the identity --as names' do
      users = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        users << args[:user]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: args[:user])
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [ok]))

      output_of { cli.setup(config: fixture_path('deploy.yml'), as: 'root') }

      expect(users.uniq).to eq(['root'])
    end

    # A created user with no way to log in is the worst outcome available, so
    # the key is resolved before a single host is touched.
    it 'refuses before connecting when no public key can be resolved' do
      allow(Odysseus::Setup::PublicKey).to receive(:resolve)
        .and_raise(Odysseus::SetupError, 'Found no public key to install')
      expect(Odysseus::Deployer::SSH).not_to receive(:new)

      expect { output_of { cli.setup(config: fixture_path('deploy.yml')) } }.to raise_error(SystemExit)
    end

    it 'prepares every host in the config, not only the first' do
      hosts = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        hosts << args[:host]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [ok]))

      output_of { cli.setup(config: fixture_path('deploy.yml')) }

      expect(hosts).to contain_exactly('web1.example.com', 'worker1.example.com')
    end

    it 'opens setup connections without Tailscale troubleshooting advice on timeout' do
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [ok]))

      expect(Odysseus::Deployer::SSH).to receive(:new)
        .with(hash_including(use_tailscale: false))
        .at_least(:once)
        .and_return(instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu'))

      output_of { cli.setup(config: fixture_path('deploy.yml')) }
    end

    it 'closes every connection it opens, even when a step fails' do
      ssh = instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(ssh)
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new)
        .and_return(instance_double(Odysseus::Setup::Preparer, prepare: [bad]))

      output_of do
        cli.setup(config: fixture_path('deploy.yml'))
      rescue SystemExit
        nil
      end

      expect(ssh).to have_received(:close).at_least(:once)
    end

    it 'reports a host whose preparation raises and continues to the next' do
      hosts = []
      allow(Odysseus::Deployer::SSH).to receive(:new) do |args|
        hosts << args[:host]
        instance_double(Odysseus::Deployer::SSH, close: nil, user: 'ubuntu')
      end
      allow(Odysseus::Setup::PublicKey).to receive(:resolve).and_return(['k'])
      allow(Odysseus::Setup::Preparer).to receive(:new) do
        instance_double(Odysseus::Setup::Preparer).tap do |p|
          allow(p).to receive(:prepare).and_raise(IOError, 'connection dropped')
        end
      end

      error = nil
      output = output_of do
        cli.setup(config: fixture_path('deploy.yml'))
      rescue SystemExit => e
        error = e
      end

      expect(hosts.size).to eq(2)
      expect(output).to include('IOError')

      # setup_commands.rb's per-host rescue escalates `worst` to :fail before
      # rendering the error -- a raising host is reported through
      # render_result, but that alone does not touch the exit code. Deleting
      # that escalation line leaves the IOError still printed above while
      # `worst` never leaves :ok, so the run would exit zero. An operator
      # scripting around this command needs a raise to look exactly like a
      # reported :fail step, not silently succeed.
      expect(error).to be_a(SystemExit)
      expect(error.status).not_to eq(0)
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
