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

    it 'defaults the tag to latest' do
      expect(executor).to receive(:deploy_all).with(image_tag: 'latest', dry_run: false)

      output_of { cli.deploy(config: config_file) }
    end

    it 'passes dry-run through' do
      expect(executor).to receive(:deploy_all).with(image_tag: 'latest', dry_run: true)

      output_of { cli.deploy(config: config_file, :'dry-run' => true) }
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

  describe '#accessory_boot' do
    it 'boots the named accessory' do
      expect(executor).to receive(:deploy_accessory).with(name: 'db')

      output_of { cli.accessory_boot(config: config_file, name: 'db') }
    end

    it 'exits non-zero when no name is given' do
      expect { output_of { cli.accessory_boot(config: config_file) } }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end
  end

  describe '#accessory_boot_all' do
    it 'boots every configured accessory' do
      expect(executor).to receive(:boot_accessories)

      output_of { cli.accessory_boot_all(config: config_file) }
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

  def with_master_key(key)
    previous = ENV.fetch('ODYSSEUS_MASTER_KEY', nil)
    ENV['ODYSSEUS_MASTER_KEY'] = key
    yield
  ensure
    ENV['ODYSSEUS_MASTER_KEY'] = previous
  end
end
