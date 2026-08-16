# spec/odysseus/docker/client_spec.rb

require 'spec_helper'
require 'shellwords'

RSpec.describe Odysseus::Docker::Client do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH, user: 'root') }
  let(:client) { described_class.new(mock_ssh) }
  let(:container_id) { 'a' * 64 } # Valid 64-char hex container ID

  # Assert what docker actually receives, by parsing the command the way a
  # shell would. Escaping style is an implementation detail; a label arriving
  # as one argument is the requirement.
  def labels_in(cmd)
    tokens = Shellwords.split(cmd)
    # rubocop:disable Style/HashSlice
    tokens.each_cons(2).select { |flag, _| flag == '--label' }.map(&:last)
    # rubocop:enable Style/HashSlice
  end

  describe '#run' do
    it 'builds and executes docker run command' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker run -d')
        expect(cmd).to include('--name test-container')
        expect(cmd).to include('myapp:latest')
        "#{container_id}\n"
      end

      result = client.run(name: 'test-container', image: 'myapp:latest')
      expect(result).to eq(container_id)
    end

    it 'includes service label' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(labels_in(cmd)).to include('odysseus.service=myservice')
        "#{container_id}\n"
      end

      client.run(
        name: 'test',
        image: 'myapp:latest',
        options: { service: 'myservice' }
      )
    end

    it 'includes memory limits' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--memory 1g')
        expect(cmd).to include('--memory-reservation 512m')
        "#{container_id}\n"
      end

      client.run(
        name: 'test',
        image: 'myapp:latest',
        options: { memory: '1g', memory_reservation: '512m' }
      )
    end

    context 'with environment variables' do
      let(:env) do
        {
          'RAILS_ENV' => 'production',
          'DATABASE_URL' => 'postgres://user:pa ss@db/app'
        }
      end
      let(:commands) { [] }
      let(:env_file) { '/var/lib/odysseus/env/test.env' }

      before do
        allow(mock_ssh).to receive(:execute) { |cmd|
          commands << cmd
          "#{container_id}\n"
        }
        allow(mock_ssh).to receive(:upload_string)
      end

      def run_container
        client.run(name: 'test', image: 'myapp:latest', options: { env: env })
      end

      it 'passes them through an env file rather than the command line' do
        run_container

        run_cmd = commands.find { |c| c.include?('docker run') }
        expect(run_cmd).to include("--env-file #{env_file}")
        expect(run_cmd).not_to include('DATABASE_URL')
        expect(run_cmd).not_to include('pa ss')
      end

      it 'uploads the env file readable only by its owner' do
        expect(mock_ssh).to receive(:upload_string) do |content, path, mode:|
          expect(content).to include('RAILS_ENV=production')
          expect(content).to include('DATABASE_URL=postgres://user:pa ss@db/app')
          expect(path).to eq(env_file)
          expect(mode).to eq(0o600)
        end

        run_container
      end

      it 'deletes the env file once the container has been created' do
        run_container

        expect(commands.last).to include("rm -f #{env_file}")
      end

      # scp creates the remote file and then streams into it, so an upload that
      # dies partway has already left a partial file of secrets on the host.
      # The path is settled before the write for exactly this reason: an ensure
      # that learned it from the write's return value has nothing to remove,
      # and the file stays under a name nobody is going to go looking for.
      it 'deletes the env file when the upload dies partway through it' do
        allow(mock_ssh).to receive(:upload_string)
          .and_raise(Odysseus::SSHCommandError, 'connection lost mid-transfer')

        expect { run_container }.to raise_error(Odysseus::SSHCommandError)
        expect(commands.last).to eq("rm -f #{env_file}")
      end

      it 'rejects values docker cannot represent in an env file' do
        expect { client.run(name: 'test', image: 'myapp:latest', options: { env: { 'KEY' => "line1\nline2" } }) }
          .to raise_error(Odysseus::DeployError, /KEY.*newline/)
      end

      it 'writes no env file when there are no variables' do
        expect(mock_ssh).not_to receive(:upload_string)

        client.run(name: 'test', image: 'myapp:latest', options: { env: {} })

        expect(commands.find { |c| c.include?('docker run') }).not_to include('--env-file')
      end
    end

    context 'with custom labels' do
      it 'passes a label value containing a space as a single argument' do
        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(labels_in(cmd)).to include('odysseus.git_ref=feature/a b')
          "#{container_id}\n"
        end

        client.run(
          name: 'test',
          image: 'myapp:latest',
          options: { labels: { 'odysseus.git_ref' => 'feature/a b' } }
        )
      end

      it 'leaves the service and version labels intact' do
        expect(mock_ssh).to receive(:execute) do |cmd|
          expect(labels_in(cmd)).to include('odysseus.service=myapp', 'odysseus.version=abc123def456')
          "#{container_id}\n"
        end

        client.run(
          name: 'test',
          image: 'myapp:latest',
          options: { service: 'myapp', version: 'abc123def456' }
        )
      end
    end

    it 'includes network setting' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--network odysseus')
        "#{container_id}\n"
      end

      client.run(
        name: 'test',
        image: 'myapp:latest',
        options: { network: 'odysseus' }
      )
    end

    it 'extracts container ID from output with warnings' do
      expect(mock_ssh).to receive(:execute) do |_cmd|
        "WARNING: some docker warning\n#{container_id}\n"
      end

      result = client.run(name: 'test', image: 'myapp:latest')
      expect(result).to eq(container_id)
    end
  end

  describe '#stop' do
    it 'stops container with timeout' do
      expect(mock_ssh).to receive(:execute).with('docker stop --time 10 abc123')
      client.stop('abc123')
    end

    it 'uses custom timeout' do
      expect(mock_ssh).to receive(:execute).with('docker stop --time 30 abc123')
      client.stop('abc123', timeout: 30)
    end
  end

  describe '#remove' do
    it 'removes container' do
      expect(mock_ssh).to receive(:execute).with('docker rm  abc123')
      client.remove('abc123')
    end

    it 'force removes when specified' do
      expect(mock_ssh).to receive(:execute).with('docker rm -f abc123')
      client.remove('abc123', force: true)
    end
  end

  describe '#list' do
    it 'lists containers for service' do
      json_output = '{"ID":"abc123","State":"running"}'
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker ps')
        expect(cmd).to include('--filter label=odysseus.service=myapp')
        json_output
      end

      result = client.list(service: 'myapp')
      expect(result).to eq([{ 'ID' => 'abc123', 'State' => 'running' }])
    end

    it 'includes stopped containers when all: true' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-a')
        ''
      end

      client.list(service: 'myapp', all: true)
    end
  end

  describe '#health_status' do
    it 'returns healthy status' do
      expect(mock_ssh).to receive(:execute).and_return("healthy\n")
      expect(client.health_status('abc123')).to eq('healthy')
    end

    it 'returns unhealthy status' do
      expect(mock_ssh).to receive(:execute).and_return("unhealthy\n")
      expect(client.health_status('abc123')).to eq('unhealthy')
    end

    it 'returns none when no healthcheck' do
      expect(mock_ssh).to receive(:execute).and_return("none\n")
      expect(client.health_status('abc123')).to eq('none')
    end
  end

  describe '#running?' do
    it 'returns true when running' do
      expect(mock_ssh).to receive(:execute).and_return("true\n")
      expect(client.running?('abc123')).to be true
    end

    it 'returns false when not running' do
      expect(mock_ssh).to receive(:execute).and_return("false\n")
      expect(client.running?('abc123')).to be false
    end
  end

  describe '#container_ip' do
    it 'returns IP address' do
      expect(mock_ssh).to receive(:execute).and_return("172.17.0.2\n")
      expect(client.container_ip('abc123')).to eq('172.17.0.2')
    end

    it 'returns nil when no IP' do
      expect(mock_ssh).to receive(:execute).and_return("\n")
      expect(client.container_ip('abc123')).to be_nil
    end
  end

  describe '#pull' do
    it 'pulls the image' do
      expect(mock_ssh).to receive(:execute).with('docker pull myapp:v1.0')
      client.pull('myapp:v1.0')
    end
  end

  describe '#image_exists?' do
    it 'returns true when image exists' do
      expect(mock_ssh).to receive(:execute).and_return("sha256:abc123\n")
      expect(client.image_exists?('myapp:v1.0')).to be true
    end

    it 'returns false when image does not exist' do
      expect(mock_ssh).to receive(:execute).and_return("\n")
      expect(client.image_exists?('myapp:v1.0')).to be false
    end
  end

  describe '#image_tags' do
    it 'lists the tags docker reports for the repository' do
      allow(mock_ssh).to receive(:execute).and_return("abc123def456\n9f8e7d6c5b4a\nlatest\n")

      expect(client.image_tags('myapp-production')).to eq(%w[abc123def456 9f8e7d6c5b4a latest])
    end

    # A dangling image cannot be named in a docker run, so it can never be a
    # rollback target. Left in, it would be offered as one.
    it 'drops dangling images' do
      allow(mock_ssh).to receive(:execute).and_return("abc123def456\n<none>\nlatest\n")

      expect(client.image_tags('myapp-production')).to eq(%w[abc123def456 latest])
    end

    it 'returns an empty list when the host has no images for the repository' do
      allow(mock_ssh).to receive(:execute).and_return("\n")

      expect(client.image_tags('myapp-production')).to eq([])
    end

    it 'asks docker only for the tag, so the output needs no parsing' do
      expect(mock_ssh).to receive(:execute).with(a_string_including("--format '{{.Tag}}'")).and_return('')

      client.image_tags('myapp-production')
    end

    it 'escapes the repository name' do
      expect(mock_ssh).to receive(:execute).with(a_string_including('my\ app')).and_return('')

      client.image_tags('my app')
    end
  end

  describe '#wait_healthy' do
    before do
      allow(client).to receive(:sleep) # Don't actually sleep in tests
    end

    it 'returns true when container becomes healthy' do
      allow(mock_ssh).to receive(:execute)
        .and_return("starting\n", "starting\n", "healthy\n")

      expect(client.wait_healthy('abc123')).to be true
    end

    it 'returns false when container is unhealthy' do
      allow(mock_ssh).to receive(:execute).and_return("unhealthy\n")

      expect(client.wait_healthy('abc123')).to be false
    end

    it 'keeps polling for the whole timeout it was given' do
      allow(mock_ssh).to receive(:execute).and_return("starting\n")

      # 120s at one poll every 2s — the caller asked for two minutes, not one.
      expect(client.wait_healthy('abc123', timeout: 120)).to be false
      expect(mock_ssh).to have_received(:execute).exactly(60).times
    end

    it 'polls at least once for a timeout shorter than the poll interval' do
      allow(mock_ssh).to receive(:execute).and_return("healthy\n")

      expect(client.wait_healthy('abc123', timeout: 1)).to be true
    end
  end

  describe '#logs' do
    it 'gets container logs' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker logs')
        expect(cmd).to include('--tail 100')
        expect(cmd).to include('abc123')
        "log line 1\nlog line 2\n"
      end

      result = client.logs('abc123')
      expect(result).to eq("log line 1\nlog line 2\n")
    end

    it 'supports follow mode with streaming' do
      expect(mock_ssh).to receive(:stream) do |cmd, &block|
        expect(cmd).to include('docker logs')
        expect(cmd).to include('--follow')
        block.call("log line 1\n")
        block.call("log line 2\n")
      end

      lines = []
      client.logs('abc123', follow: true) { |line| lines << line }
      expect(lines).to eq(["log line 1\n", "log line 2\n"])
    end

    it 'supports since parameter' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--since 10m')
        ''
      end

      client.logs('abc123', since: '10m')
    end

    it 'supports timestamps option' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--timestamps')
        ''
      end

      client.logs('abc123', timestamps: true)
    end
  end

  describe '#exec' do
    it 'executes command in container' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker exec')
        expect(cmd).to include('abc123')
        expect(cmd).to include('ls -la')
        "file1\nfile2\n"
      end

      result = client.exec('abc123', 'ls -la')
      expect(result).to eq("file1\nfile2\n")
    end

    it 'supports interactive mode' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-i')
        ''
      end

      client.exec('abc123', 'bash', interactive: true)
    end

    it 'supports tty mode' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-t')
        ''
      end

      client.exec('abc123', 'bash', tty: true)
    end
  end

  describe '#run_once' do
    it 'runs command in ephemeral container' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('docker run --rm')
        expect(cmd).to include('myapp:latest')
        expect(cmd).to include('rake db:migrate')
        "Migrated!\n"
      end

      result = client.run_once(image: 'myapp:latest', command: 'rake db:migrate')
      expect(result).to eq("Migrated!\n")
    end

    context 'with environment variables' do
      let(:env) do
        {
          'RAILS_ENV' => 'production',
          'DATABASE_URL' => 'postgres://user:pa ss@db/app'
        }
      end
      let(:commands) { [] }
      let(:uploads) { [] }

      before do
        allow(mock_ssh).to receive(:execute) { |cmd|
          commands << cmd
          ''
        }
        allow(mock_ssh).to receive(:upload_string) { |content, path, mode:|
          uploads << { content: content, path: path, mode: mode }
        }
      end

      def migrate
        client.run_once(image: 'myapp:latest', command: 'rake db:migrate', options: { env: env })
      end

      def env_path
        uploads.first[:path]
      end

      it 'sends them to the container' do
        migrate

        expect(uploads.first[:content]).to include('RAILS_ENV=production')
        expect(uploads.first[:content]).to include('DATABASE_URL=postgres://user:pa ss@db/app')
        expect(commands.find { |c| c.include?('docker run') }).to include("--env-file #{env_path}")
      end

      # `ps` on the host must not show a customer's database password, and a
      # value containing a space must not split into two arguments.
      it 'keeps every value off the command line' do
        migrate

        run_cmd = commands.find { |c| c.include?('docker run') }
        expect(run_cmd).not_to include('DATABASE_URL')
        expect(run_cmd).not_to include('pa ss')
        expect(run_cmd).not_to include('-e ')
      end

      it 'writes the file readable only by its owner' do
        migrate

        expect(uploads.first[:mode]).to eq(0o600)
      end

      # A one-off has no container name to be named after. The name must not be
      # one a deployed container could have — overwriting a running container's
      # env file would be a live incident — and must differ per run.
      it 'names the file so it cannot collide with a container or another one-off' do
        migrate
        migrate

        paths = uploads.map { |u| u[:path] }
        expect(paths.first).to match(%r{\A/var/lib/odysseus/env/one-off@[0-9a-f]{16}\.env\z})
        expect(paths.first).not_to eq(paths.last)
      end

      it 'removes the env file once the command has finished' do
        migrate

        expect(commands.last).to eq("rm -f #{env_path}")
      end

      it 'removes the env file when the command fails, and reports the failure' do
        allow(mock_ssh).to receive(:execute) { |cmd|
          commands << cmd
          raise Odysseus::SSHCommandError, 'exit status 1' if cmd.include?('docker run')

          ''
        }

        expect { migrate }.to raise_error(Odysseus::SSHCommandError, /exit status 1/)
        expect(commands.last).to eq("rm -f #{env_path}")
      end

      it 'rejects values docker cannot represent in an env file' do
        expect { client.run_once(image: 'myapp:latest', command: 'true', options: { env: { 'KEY' => "a\nb" } }) }
          .to raise_error(Odysseus::DeployError, /KEY.*newline/)
      end

      it 'writes no env file when there is nothing to write' do
        expect(mock_ssh).not_to receive(:upload_string)

        client.run_once(image: 'myapp:latest', command: 'rake db:migrate')

        expect(commands.find { |c| c.include?('docker run') }).not_to include('--env-file')
      end
    end

    # The command is a shell command line by design — `rake db:migrate` has to
    # reach docker as two words — but the image is one argument.
    it 'passes the image as a single argument, and the command as words' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(Shellwords.split(cmd).last(3)).to eq(['myapp:latest', 'rake', 'db:migrate'])
        ''
      end

      client.run_once(image: 'myapp:latest', command: 'rake db:migrate')
    end

    # The image reference comes straight from `--image` on the command line.
    it 'keeps a metacharacter in the image reference from starting a second command' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(Shellwords.split(cmd)).to include('myapp:v1; rm -rf /')
        ''
      end

      client.run_once(image: 'myapp:v1; rm -rf /', command: 'true')
    end

    it 'includes network option' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('--network odysseus')
        ''
      end

      client.run_once(
        image: 'myapp:latest',
        command: 'bash',
        options: { network: 'odysseus' }
      )
    end

    it 'includes volume mounts' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-v /data:/app/data')
        ''
      end

      client.run_once(
        image: 'myapp:latest',
        command: 'bash',
        options: { volumes: ['/data:/app/data'] }
      )
    end
  end

  # For runs Odysseus does not execute itself: `app shell` and `app console`
  # need an interactive TTY, so the CLI builds its own `ssh -t ... docker run`.
  # The environment still has to reach the host as a file.
  describe '#with_env_file' do
    let(:commands) { [] }
    let(:uploads) { [] }
    # Every call in the order it was made, so an example can say that the
    # directory was made private *before* the secrets went into it rather than
    # only that both happened.
    let(:events) { [] }

    before do
      allow(mock_ssh).to receive(:execute) { |cmd|
        commands << cmd
        events << [:execute, cmd]
        ''
      }
      allow(mock_ssh).to receive(:upload_string) { |content, path, mode:|
        uploads << { content: content, path: path, mode: mode }
        events << [:upload, path]
      }
      allow(mock_ssh).to receive(:close) { events << [:close, nil] }
    end

    it 'yields the path of a private file holding the environment' do
      yielded = nil
      client.with_env_file('DATABASE_URL' => 'postgres://user:pa ss@db/app') { |path| yielded = path }

      expect(yielded).to eq(uploads.first[:path])
      expect(uploads.first[:content]).to include('DATABASE_URL=postgres://user:pa ss@db/app')
      expect(uploads.first[:mode]).to eq(0o600)
    end

    it 'removes the file once the block returns' do
      path = nil
      client.with_env_file('A' => 'b') { |p| path = p }

      expect(commands.last).to eq("rm -f #{path}")
    end

    it 'removes the file when the block raises, without masking the error' do
      path = nil

      expect do
        client.with_env_file('A' => 'b') do |p|
          path = p
          raise Odysseus::DeployError, 'interactive run failed'
        end
      end.to raise_error(Odysseus::DeployError, 'interactive run failed')

      expect(commands.last).to eq("rm -f #{path}")
    end

    # One code path for the caller, whether or not the app declares any env.
    it 'yields nil and writes nothing when there is no environment' do
      expect(mock_ssh).not_to receive(:upload_string)

      yielded = :untouched
      client.with_env_file({}) { |path| yielded = path }

      expect(yielded).to be_nil
      expect(commands).to be_empty
    end

    it 'returns what the block returned' do
      expect(client.with_env_file('A' => 'b') { 'exit 0' }).to eq('exit 0')
    end

    # The file is 0600 in its own right, so the directory's mode is a second
    # guard — but it is the guard that has to hold for a file left behind by a
    # session that died, which is the case the README leans on when it says
    # another user on the box still cannot read it. `mkdir -p` alone leaves the
    # directory 0755, and the chmod that fixes that had nothing asserting it.
    it 'makes the env directory private before any secret goes into it' do
      client.with_env_file('A' => 'b') { |_path| nil }

      expect(events.first).to eq([:execute, 'mkdir -p /var/lib/odysseus/env && chmod 700 /var/lib/odysseus/env'])
      expect(events[1].first).to eq(:upload)
    end

    # scp creates the remote file and then streams into it: an upload that dies
    # partway has already put part of a file of secrets on the host.
    it 'removes the file when the upload dies partway through it' do
      allow(mock_ssh).to receive(:upload_string)
        .and_raise(Odysseus::SSHCommandError, 'connection lost mid-transfer')

      expect { client.with_env_file('A' => 'b') { |_path| nil } }
        .to raise_error(Odysseus::SSHCommandError)

      expect(commands.last).to match(%r{\Arm -f /var/lib/odysseus/env/one-off@\h{16}\.env\z})
    end

    # These are the errors this ensure actually meets. The CLI holds the
    # connection open, idle and unpumped, for as long as an interactive session
    # lasts, so an idle NAT timeout, sshd's ClientAlive limit or a Tailscale
    # relay change can leave it dead by the time the session ends — and a dead
    # connection raises IOError, Net::SSH::Disconnect, Errno::EPIPE or
    # Errno::ECONNRESET, none of which is an Odysseus::SSHError. Rescuing only
    # Odysseus::SSHError meant the cleanup's own failure escaped the ensure and
    # replaced whatever the block was raising.
    context 'when the connection dies before the file can be removed' do
      def dead_after_write(error)
        attempts = 0
        allow(mock_ssh).to receive(:execute) do |cmd|
          commands << cmd
          events << [:execute, cmd]
          if cmd.start_with?('rm -f')
            attempts += 1
            raise error if attempts == 1
          end
          ''
        end
      end

      it 'removes the file over a fresh connection' do
        dead_after_write(IOError.new('closed stream'))

        path = nil
        client.with_env_file('A' => 'b') { |p| path = p }

        expect(events.last(3)).to eq([[:execute, "rm -f #{path}"], [:close, nil], [:execute, "rm -f #{path}"]])
      end

      it 'does not mask the failure the block was already raising' do
        dead_after_write(Errno::ECONNRESET.new)

        expect do
          client.with_env_file('A' => 'b') { raise Odysseus::DeployError, 'interactive run failed' }
        end.to raise_error(Odysseus::DeployError, 'interactive run failed')
      end

      # `app shell` reports the status ssh gave it by raising SystemExit through
      # here. SystemExit is not a StandardError, which is what keeps the rescue
      # in remove_env_file from eating it — asserted rather than assumed, since
      # a swallowed status is the difference between `exit 7` and success.
      it 'lets the session exit status through' do
        dead_after_write(IOError.new('closed stream'))

        expect { client.with_env_file('A' => 'b') { exit 7 } }
          .to raise_error(SystemExit) { |error| expect(error.status).to eq(7) }
      end

      # Reconnecting is one attempt, not a retry loop: a host that is gone stays
      # gone, and the caller came for the block's outcome, not this one's.
      it 'gives up quietly when the fresh connection cannot remove it either' do
        allow(mock_ssh).to receive(:execute) do |cmd|
          commands << cmd
          raise Net::SSH::Disconnect if cmd.start_with?('rm -f')

          ''
        end

        expect { client.with_env_file('A' => 'b') { |_path| nil } }.not_to raise_error
        expect(commands.count { |c| c.start_with?('rm -f') }).to eq(2)
      end
    end
  end

  describe 'where env files are written' do
    it 'uses the system directory for root' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'root')
      allow(ssh).to receive(:execute) do |cmd|
        commands << cmd
        ''
      end
      allow(ssh).to receive(:upload_string)

      described_class.new(ssh).with_env_file({ 'A' => '1' }) { |path| commands << "used #{path}" }

      expect(commands).to include(a_string_matching(%r{mkdir -p /var/lib/odysseus/env}))
      expect(commands).to include(a_string_matching(%r{used /var/lib/odysseus/env/}))
    end

    it 'uses the home directory for a deploy user' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'odysseus')
      allow(ssh).to receive(:execute) do |cmd|
        commands << cmd
        cmd == 'echo $HOME' ? "/home/odysseus\n" : ''
      end
      allow(ssh).to receive(:upload_string)

      described_class.new(ssh).with_env_file({ 'A' => '1' }) { |path| commands << "used #{path}" }

      expect(commands).to include(a_string_matching(%r{mkdir -p /home/odysseus/\.odysseus/env}))
      expect(commands).to include(a_string_matching(%r{used /home/odysseus/\.odysseus/env/}))
      expect(commands).not_to include(a_string_matching(%r{/var/lib/odysseus}))
    end

    # The directory is no longer the fixed literal ENV_FILE_DIR used to be —
    # it is built from whatever the host reports as $HOME — so it can no
    # longer be interpolated unescaped. A home containing a space is the
    # simplest value that breaks the command if either Shellwords.escape call
    # in write_env_file is dropped.
    it 'escapes a home directory containing a space' do
      commands = []
      ssh = instance_double(Odysseus::Deployer::SSH, user: 'deploy')
      allow(ssh).to receive(:execute) do |cmd|
        commands << cmd
        cmd == 'echo $HOME' ? "/home/deploy user\n" : ''
      end
      allow(ssh).to receive(:upload_string)

      described_class.new(ssh).with_env_file({ 'A' => '1' }) { |path| commands << "used #{path}" }

      mkdir_cmd = commands.find { |cmd| cmd.start_with?('mkdir') }
      expect(mkdir_cmd).to eq(
        'mkdir -p /home/deploy\ user/.odysseus/env && chmod 700 /home/deploy\ user/.odysseus/env'
      )
    end
  end

  describe '#prune' do
    it 'prunes containers excluding odysseus-managed' do
      expect(mock_ssh).to receive(:execute)
        .with('docker container prune -f --filter "label!=odysseus.managed=true" 2>&1')
        .and_return("Deleted containers:\nabc123\n")
      expect(mock_ssh).to receive(:execute)
        .with('docker image prune -f 2>&1')
        .and_return("Total reclaimed space: 100MB\n")

      result = client.prune
      expect(result[:containers]).to include('abc123')
      expect(result[:images]).to include('100MB')
    end

    it 'can prune volumes when requested' do
      expect(mock_ssh).to receive(:execute)
        .with('docker container prune -f --filter "label!=odysseus.managed=true" 2>&1')
        .and_return('')
      expect(mock_ssh).to receive(:execute).with('docker image prune -f 2>&1').and_return('')
      expect(mock_ssh).to receive(:execute).with('docker volume prune -f 2>&1').and_return("Total reclaimed space: 500MB\n")

      result = client.prune(volumes: true)
      expect(result[:volumes]).to include('500MB')
    end

    it 'can prune networks excluding odysseus-managed' do
      expect(mock_ssh).to receive(:execute)
        .with('docker container prune -f --filter "label!=odysseus.managed=true" 2>&1')
        .and_return('')
      expect(mock_ssh).to receive(:execute).with('docker image prune -f 2>&1').and_return('')
      expect(mock_ssh).to receive(:execute)
        .with('docker network prune -f --filter "label!=odysseus.managed=true" 2>&1')
        .and_return("Deleted networks:\nold_network\n")

      result = client.prune(networks: true)
      expect(result[:networks]).to include('old_network')
    end

    it 'can skip containers and images' do
      expect(mock_ssh).not_to receive(:execute).with(/container prune/)
      expect(mock_ssh).not_to receive(:execute).with(/image prune/)

      result = client.prune(containers: false, images: false)
      expect(result).to eq({})
    end
  end

  describe '#disk_usage' do
    it 'returns docker system df output' do
      df_output = "TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\nImages          5         2         1.2GB     800MB (66%)\n"
      expect(mock_ssh).to receive(:execute).with('docker system df').and_return(df_output)

      result = client.disk_usage
      expect(result).to include('Images')
      expect(result).to include('1.2GB')
    end
  end

  describe '#cleanup_old_containers' do
    it 'removes old stopped containers keeping specified number' do
      allow(mock_ssh).to receive(:execute) do |cmd|
        if cmd.include?('docker ps')
          [
            '{"ID":"old1","State":"exited","CreatedAt":"2024-01-01"}',
            '{"ID":"old2","State":"exited","CreatedAt":"2024-01-02"}',
            '{"ID":"new1","State":"exited","CreatedAt":"2024-01-03"}'
          ].join("\n")
        else
          ''
        end
      end

      expect(mock_ssh).to receive(:execute).with('docker rm  old1')

      removed = client.cleanup_old_containers(service: 'myapp', keep: 2)
      expect(removed).to eq(['old1'])
    end
  end

  describe '#remove_image' do
    it 'removes the image by reference' do
      expect(mock_ssh).to receive(:execute).with(a_string_including('docker image rm')).and_return('')

      client.remove_image('myapp-production:abc123')
    end

    # Not -f. A container whose role was removed from deploy.yml keeps
    # running with no label RetentionSweeper's container_labels(roles) would
    # ever see, so versions_in_use never protects it; docker's refusal to
    # remove an image a container still references is the only guard left for
    # that host. A forced removal would delete the image out from under it.
    it 'never forces the removal' do
      expect(mock_ssh).to receive(:execute).with('docker image rm myapp-production:abc123').and_return('')

      client.remove_image('myapp-production:abc123')
    end

    it 'escapes the image reference' do
      expect(mock_ssh).to receive(:execute).with(a_string_including('my\ app')).and_return('')

      client.remove_image('my app')
    end

    # Every other method on this client lets SSHCommandError through, and the
    # caller prunes image-by-image so one refusal is a skip rather than a failed
    # deploy. Swallowing it here would hide a host that cannot prune at all.
    it 'lets a failure propagate for the caller to rescue' do
      allow(mock_ssh).to receive(:execute).and_raise(Odysseus::SSHCommandError, 'image is in use')

      expect { client.remove_image('myapp-production:abc123') }
        .to raise_error(Odysseus::SSHCommandError, /in use/)
    end
  end

  describe '#versions_in_use' do
    it 'collects the version label of every container across the given service labels' do
      allow(client).to receive(:list).with(service: 'myapp', all: true).and_return(
        [{ 'Labels' => 'odysseus.service=myapp,odysseus.version=v2' }]
      )
      allow(client).to receive(:list).with(service: 'myapp-jobs', all: true).and_return(
        [{ 'Labels' => 'odysseus.service=myapp-jobs,odysseus.version=v1' }]
      )

      expect(client.versions_in_use(%w[myapp myapp-jobs])).to contain_exactly('v1', 'v2')
    end

    # cleanup_old_containers keeps two stopped containers per service on purpose.
    # Their images must not be pruned out from under them, so stopped containers
    # count as in use.
    it 'includes stopped containers' do
      expect(client).to receive(:list).with(service: 'myapp', all: true).and_return(
        [{ 'State' => 'exited', 'Labels' => 'odysseus.version=v1' }]
      )

      expect(client.versions_in_use(['myapp'])).to eq(['v1'])
    end

    it 'de-duplicates a version running under two labels' do
      allow(client).to receive(:list).and_return([{ 'Labels' => 'odysseus.version=v2' }])

      expect(client.versions_in_use(%w[myapp myapp-jobs])).to eq(['v2'])
    end

    it 'skips a container carrying no version label' do
      allow(client).to receive(:list).and_return(
        [{ 'Labels' => 'odysseus.service=myapp' }, { 'Labels' => 'odysseus.version=v2' }]
      )

      expect(client.versions_in_use(['myapp'])).to eq(['v2'])
    end

    it 'returns an empty array when nothing is on the host' do
      allow(client).to receive(:list).and_return([])

      expect(client.versions_in_use(['myapp'])).to eq([])
    end
  end
end
