# spec/odysseus/registry/host_session_spec.rb
require 'spec_helper'

RSpec.describe Odysseus::Registry::HostSession do
  let(:ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:complete) do
    instance_double(Odysseus::Registry::Credentials,
                    complete?: true, server: 'ghcr.io', username: 'wa', password: 's3cr3t')
  end
  let(:incomplete) { instance_double(Odysseus::Registry::Credentials, complete?: false) }

  def stub_mktemp(dir = '/tmp/odysseus-registry.XYZ')
    allow(ssh).to receive(:execute).with(a_string_including('mktemp -d')).and_return("#{dir}\n")
    allow(ssh).to receive(:execute).with(a_string_including('docker login'))
    allow(ssh).to receive(:execute).with(a_string_including('rm -rf'))
    dir
  end

  it 'yields the directory it created' do
    dir = stub_mktemp
    expect { |b| described_class.open(ssh: ssh, credentials: complete, &b) }.to yield_with_args(dir)
  end

  it 'creates the directory mode 700, so another user on the host cannot read it' do
    stub_mktemp
    expect(ssh).to receive(:execute).with(a_string_including('chmod 700')).and_return("/tmp/d\n")
    allow(ssh).to receive(:execute)
    described_class.open(ssh: ssh, credentials: complete) { nil }
  end

  # $_ holds mktemp's last argument, not its output -- a first version of this
  # chmod'd the template and returned it as the directory.
  it 'returns the directory mktemp created, not the template it was given' do
    # Order matters: RSpec resolves a stubbed message by trying the most
    # recently declared matching `allow` first, so the specific mktemp
    # constraint has to come after the catch-all or it is shadowed by it.
    allow(ssh).to receive(:execute)
    allow(ssh).to receive(:execute).with(a_string_including('mktemp')).and_return("/tmp/odysseus-registry.AbCdEfGh\n")
    described_class.open(ssh: ssh, credentials: complete) do |dir|
      expect(dir).to eq('/tmp/odysseus-registry.AbCdEfGh')
    end
  end

  it 'aborts when the directory cannot be created' do
    allow(ssh).to receive(:execute).with(a_string_including('mktemp')).and_return("\n")
    expect { described_class.open(ssh: ssh, credentials: complete) { nil } }
      .to raise_error(Odysseus::DeployError, /director/i)
  end

  # Any other shape loses redaction. See CommandRedaction::STDIN_PIPE, which
  # requires `docker login` (or `--password-stdin`) immediately after the
  # pipe -- DOCKER_CONFIG is exported as its own statement rather than
  # prefixed onto `docker login`, because a prefix puts a token between the
  # pipe and `docker login` and the redactor stops matching.
  it 'builds the login in the shape CommandRedaction matches' do
    stub_mktemp('/tmp/d')
    expect(ssh).to receive(:execute).with(
      "export DOCKER_CONFIG=/tmp/d && echo 's3cr3t' | docker login ghcr.io -u wa --password-stdin"
    )
    described_class.open(ssh: ssh, credentials: complete) { nil }
  end

  it 'redacts the password it just built' do
    stub_mktemp('/tmp/d')
    sent = nil
    allow(ssh).to receive(:execute) do |cmd|
      sent = cmd if cmd.include?('docker login')
      "/tmp/d\n"
    end
    described_class.open(ssh: ssh, credentials: complete) { nil }
    expect(Odysseus::CommandRedaction.redact(sent)).not_to include('s3cr3t')
  end

  # A naive `'#{password}'` breaks the command as soon as the password itself
  # contains a single quote, since that closes the quoting early.
  it 'quotes a password containing a single quote so it still reaches docker intact' do
    quoting_creds = instance_double(Odysseus::Registry::Credentials,
                                    complete?: true, server: 'ghcr.io', username: 'wa', password: "it's-a-secret")
    stub_mktemp('/tmp/d')
    sent = nil
    allow(ssh).to receive(:execute) do |cmd|
      sent = cmd if cmd.include?('docker login')
      "/tmp/d\n"
    end
    described_class.open(ssh: ssh, credentials: quoting_creds) { nil }
    piped = sent[/echo (.+?) \| docker login/, 1]
    expect(`echo #{piped}`.chomp).to eq("it's-a-secret")
  end

  it 'removes the directory afterwards' do
    stub_mktemp('/tmp/d')
    expect(ssh).to receive(:execute).with('rm -rf /tmp/d')
    described_class.open(ssh: ssh, credentials: complete) { nil }
  end

  # The whole point of a temp directory is that nothing is left behind, which
  # is exactly the case where the block raised.
  it 'removes the directory when the block raises' do
    stub_mktemp('/tmp/d')
    expect(ssh).to receive(:execute).with('rm -rf /tmp/d')
    expect { described_class.open(ssh: ssh, credentials: complete) { raise 'boom' } }.to raise_error('boom')
  end

  # A deploy that fails because teardown couldn't clean up its own temp
  # directory is worse than the credential being left behind: now there's a
  # failed deploy AND an undiscarded credential. The requirement is that
  # teardown failure warns -- naming the directory, since that's the one
  # thing left on the host for someone to go clean up by hand -- and never
  # fails the deploy.
  it 'warns and keeps the deploy result when the directory cannot be removed' do
    stub_mktemp('/tmp/d')
    allow(ssh).to receive(:execute).with(a_string_including('rm -rf'))
                                   .and_raise(Odysseus::SSHCommandError, 'permission denied')
    result = nil
    expect { result = described_class.open(ssh: ssh, credentials: complete) { :ok } }
      .to output(%r{/tmp/d}).to_stderr
    expect(result).to eq(:ok)
  end

  it 'returns what the block returned' do
    stub_mktemp
    expect(described_class.open(ssh: ssh, credentials: complete) { :result }).to eq(:result)
  end

  it 'yields nil and logs in nowhere when credentials are incomplete' do
    expect(ssh).not_to receive(:execute)
    expect { |b| described_class.open(ssh: ssh, credentials: incomplete, &b) }.to yield_with_args(nil)
  end

  it 'aborts when the login is rejected, before anything else runs' do
    allow(ssh).to receive(:execute).with(a_string_including('mktemp -d')).and_return("/tmp/d\n")
    allow(ssh).to receive(:execute).with(a_string_including('docker login'))
                                   .and_raise(Odysseus::SSHCommandError, 'unauthorized')
    allow(ssh).to receive(:execute).with(a_string_including('rm -rf'))
    expect { described_class.open(ssh: ssh, credentials: complete) { nil } }
      .to raise_error(Odysseus::DeployError, /ghcr.io/)
  end

  # A stub that raises with just 'unauthorized' would make this pass whether
  # or not anything redacts anything -- that message never contained the
  # password to begin with. A rejected login raised by the real SSH class
  # embeds the raw command (command_failure_message), so the stub has to
  # carry that shape, password and all, for this spec to mean anything.
  it 'does not put the password in the abort message' do
    allow(ssh).to receive(:execute).with(a_string_including('mktemp -d')).and_return("/tmp/d\n")
    realistic_failure = Odysseus::SSHCommandError.new(
      'Command failed on registry-host with exit status 1: ' \
      "export DOCKER_CONFIG=/tmp/d && echo 's3cr3t' | docker login ghcr.io -u wa --password-stdin\n" \
      'unauthorized: incorrect username or password'
    )
    allow(ssh).to receive(:execute).with(a_string_including('docker login')).and_raise(realistic_failure)
    allow(ssh).to receive(:execute).with(a_string_including('rm -rf'))
    described_class.open(ssh: ssh, credentials: complete) { nil }
  rescue Odysseus::DeployError => e
    expect(e.message).not_to include('s3cr3t')
  end
end
