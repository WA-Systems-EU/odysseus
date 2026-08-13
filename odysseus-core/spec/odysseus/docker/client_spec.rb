# spec/odysseus/docker/client_spec.rb

require 'spec_helper'
require 'shellwords'

RSpec.describe Odysseus::Docker::Client do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
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

    it 'includes environment variables' do
      expect(mock_ssh).to receive(:execute) do |cmd|
        expect(cmd).to include('-e RAILS_ENV=production')
        ''
      end

      client.run_once(
        image: 'myapp:latest',
        command: 'rails console',
        options: { env: { 'RAILS_ENV' => 'production' } }
      )
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
