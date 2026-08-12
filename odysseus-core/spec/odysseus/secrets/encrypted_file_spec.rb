# spec/odysseus/secrets/encrypted_file_spec.rb

require 'spec_helper'
require 'tempfile'

RSpec.describe Odysseus::Secrets::EncryptedFile do
  let(:master_key) { described_class.generate_key }
  let(:temp_file) { Tempfile.new(['secrets', '.enc']) }
  let(:encrypted_file) { described_class.new(temp_file.path) }

  after do
    begin
      temp_file.close
    rescue StandardError
      nil
    end
    begin
      temp_file.unlink
    rescue StandardError
      nil
    end
  end

  describe '.generate_key' do
    it 'generates a 64-character hex string (32 bytes)' do
      key = described_class.generate_key
      expect(key).to be_a(String)
      expect(key.length).to eq(64)
      expect(key).to match(/\A[0-9a-f]+\z/)
    end

    it 'generates unique keys each time' do
      key1 = described_class.generate_key
      key2 = described_class.generate_key
      expect(key1).not_to eq(key2)
    end
  end

  describe '#exists?' do
    it 'returns true when file exists' do
      expect(encrypted_file.exists?).to be true
    end

    it 'returns false when file does not exist' do
      nonexistent = described_class.new('/tmp/nonexistent_secrets_file_12345.enc')
      expect(nonexistent.exists?).to be false
    end
  end

  describe '#write and #read' do
    let(:secrets) do
      {
        DATABASE_URL: 'postgres://localhost/myapp',
        SECRET_KEY_BASE: 'super_secret_value_12345',
        API_KEY: 'api-key-abc123'
      }
    end

    it 'encrypts and decrypts secrets round-trip' do
      encrypted_file.write(secrets, key: master_key)
      decrypted = encrypted_file.read(key: master_key)

      expect(decrypted).to eq(secrets)
    end

    it 'writes non-readable encrypted content to file' do
      encrypted_file.write(secrets, key: master_key)
      content = File.read(temp_file.path)

      # Should have comment header
      expect(content).to include('# Odysseus encrypted secrets')

      # Should not contain plaintext values
      secrets.each_value do |value|
        expect(content).not_to include(value)
      end
    end

    it 'handles empty secrets hash' do
      encrypted_file.write({}, key: master_key)
      decrypted = encrypted_file.read(key: master_key)

      expect(decrypted).to eq({})
    end

    it 'handles secrets with special characters' do
      special_secrets = {
        password: 'p@$$w0rd!#%^&*()',
        json_value: '{"key": "value", "nested": {"a": 1}}',
        multiline: "line1\nline2\nline3"
      }

      encrypted_file.write(special_secrets, key: master_key)
      decrypted = encrypted_file.read(key: master_key)

      expect(decrypted).to eq(special_secrets)
    end
  end

  describe '#read with wrong key' do
    it 'raises DecryptionError' do
      secrets = { API_KEY: 'secret123' }
      encrypted_file.write(secrets, key: master_key)

      wrong_key = described_class.generate_key
      expect { encrypted_file.read(key: wrong_key) }
        .to raise_error(described_class::DecryptionError)
    end
  end

  describe 'without master key' do
    around do |example|
      original_key = ENV.fetch('ODYSSEUS_MASTER_KEY', nil)
      ENV.delete('ODYSSEUS_MASTER_KEY')
      example.run
      ENV['ODYSSEUS_MASTER_KEY'] = original_key if original_key
    end

    it 'raises MissingKeyError on write' do
      expect { encrypted_file.write({ key: 'value' }) }
        .to raise_error(described_class::MissingKeyError, /ODYSSEUS_MASTER_KEY/)
    end

    it 'raises MissingKeyError on read' do
      File.write(temp_file.path, 'encrypted content')
      expect { encrypted_file.read }
        .to raise_error(described_class::MissingKeyError, /ODYSSEUS_MASTER_KEY/)
    end
  end

  describe 'with master key from ENV' do
    let(:env_key) { described_class.generate_key }
    let(:secrets) { { API_KEY: 'from_env' } }

    around do |example|
      original_key = ENV.fetch('ODYSSEUS_MASTER_KEY', nil)
      ENV['ODYSSEUS_MASTER_KEY'] = env_key
      example.run
      ENV['ODYSSEUS_MASTER_KEY'] = original_key
    end

    it 'uses ODYSSEUS_MASTER_KEY from environment for write' do
      encrypted_file.write(secrets)

      # Read back with explicit key
      decrypted = encrypted_file.read(key: env_key)
      expect(decrypted).to eq(secrets)
    end

    it 'uses ODYSSEUS_MASTER_KEY from environment for read' do
      # Write with explicit key
      encrypted_file.write(secrets, key: env_key)

      # Read using env
      decrypted = encrypted_file.read
      expect(decrypted).to eq(secrets)
    end
  end

  describe '#read with corrupted file' do
    it 'raises DecryptionError for invalid format' do
      File.write(temp_file.path, 'not valid encrypted content')

      expect { encrypted_file.read(key: master_key) }
        .to raise_error(described_class::DecryptionError)
    end

    it 'raises DecryptionError for tampered content' do
      secrets = { key: 'value' }
      encrypted_file.write(secrets, key: master_key)

      # Tamper with the file
      content = File.read(temp_file.path)
      lines = content.lines
      # Modify the encrypted data portion
      lines[-1] = 'tampered_data_here'
      File.write(temp_file.path, lines.join)

      expect { encrypted_file.read(key: master_key) }
        .to raise_error(described_class::DecryptionError)
    end
  end
end
