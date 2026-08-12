# spec/odysseus/secrets/loader_spec.rb

require 'spec_helper'
require 'tempfile'
require 'fileutils'

RSpec.describe Odysseus::Secrets::Loader do
  let(:master_key) { Odysseus::Secrets::EncryptedFile.generate_key }
  let(:temp_dir) { Dir.mktmpdir }
  let(:secrets_file_path) { File.join(temp_dir, 'secrets.yml.enc') }

  let(:config_with_secrets) do
    {
      service: 'myapp',
      secrets_file: 'secrets.yml.enc'
    }
  end

  let(:config_without_secrets) do
    {
      service: 'myapp',
      secrets_file: nil
    }
  end

  let(:loader_with_secrets) do
    described_class.new(config_with_secrets, config_dir: temp_dir)
  end

  let(:loader_without_secrets) do
    described_class.new(config_without_secrets, config_dir: temp_dir)
  end

  after do
    FileUtils.rm_rf(temp_dir)
  end

  around do |example|
    original_key = ENV.fetch('ODYSSEUS_MASTER_KEY', nil)
    ENV['ODYSSEUS_MASTER_KEY'] = master_key
    example.run
    ENV['ODYSSEUS_MASTER_KEY'] = original_key
  end

  def create_encrypted_secrets(secrets)
    encrypted_file = Odysseus::Secrets::EncryptedFile.new(secrets_file_path)
    encrypted_file.write(secrets, key: master_key)
  end

  describe '#configured?' do
    it 'returns true when secrets_file is set' do
      expect(loader_with_secrets.configured?).to be true
    end

    it 'returns false when secrets_file is nil' do
      expect(loader_without_secrets.configured?).to be false
    end
  end

  describe '#load' do
    context 'with secrets file configured' do
      it 'loads and returns secrets from encrypted file' do
        secrets = { DATABASE_URL: 'postgres://localhost', API_KEY: 'secret123' }
        create_encrypted_secrets(secrets)

        loaded = loader_with_secrets.load
        expect(loaded).to eq(secrets)
      end

      it 'caches loaded secrets' do
        secrets = { API_KEY: 'cached_value' }
        create_encrypted_secrets(secrets)

        # Load twice
        first_load = loader_with_secrets.load
        second_load = loader_with_secrets.load

        # Should be same object (cached)
        expect(first_load).to equal(second_load)
      end

      it 'raises ConfigError when secrets file not found' do
        # Don't create the file
        expect { loader_with_secrets.load }
          .to raise_error(Odysseus::ConfigError, /not found/)
      end
    end

    context 'without secrets file configured' do
      it 'returns empty hash' do
        expect(loader_without_secrets.load).to eq({})
      end
    end
  end

  describe '#get' do
    let(:secrets) do
      { DATABASE_URL: 'postgres://localhost', API_KEY: 'secret123' }
    end

    before do
      create_encrypted_secrets(secrets)
    end

    it 'returns value for symbol key' do
      expect(loader_with_secrets.get(:DATABASE_URL)).to eq('postgres://localhost')
    end

    it 'returns value for string key' do
      expect(loader_with_secrets.get('API_KEY')).to eq('secret123')
    end

    it 'returns nil for missing key' do
      expect(loader_with_secrets.get(:NONEXISTENT)).to be_nil
    end
  end

  describe 'relative vs absolute paths' do
    it 'resolves relative path from config_dir' do
      secrets = { KEY: 'value' }
      create_encrypted_secrets(secrets)

      loader = described_class.new(
        { secrets_file: 'secrets.yml.enc' },
        config_dir: temp_dir
      )

      expect(loader.load).to eq(secrets)
    end

    it 'uses absolute path as-is' do
      secrets = { KEY: 'absolute_value' }
      create_encrypted_secrets(secrets)

      loader = described_class.new(
        { secrets_file: secrets_file_path }, # absolute path
        config_dir: '/some/other/dir'
      )

      expect(loader.load).to eq(secrets)
    end
  end
end
