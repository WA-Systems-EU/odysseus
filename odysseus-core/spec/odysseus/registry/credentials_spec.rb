# spec/odysseus/registry/credentials_spec.rb
require 'spec_helper'

RSpec.describe Odysseus::Registry::Credentials do
  let(:loader) { instance_double(Odysseus::Secrets::Loader, configured?: true) }

  def creds(registry, env: {})
    described_class.new(registry, secrets_loader: loader, env: env)
  end

  describe 'password_secret' do
    it 'resolves the key from the encrypted file' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return('s3cr3t')
      c = creds({ server: 'ghcr.io', username: 'wa', password_secret: 'REGISTRY_TOKEN' })
      expect(c.password).to eq('s3cr3t')
    end

    # A silent fallback here authenticates the deploy with the wrong credential.
    it 'raises naming the key and the file when the secret is missing' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return(nil)
      c = creds({ server: 'ghcr.io', username: 'wa', password_secret: 'REGISTRY_TOKEN' },
                env: { 'ODYSSEUS_REGISTRY_PASSWORD' => 'ignored' })
      expect { c.password }.to raise_error(Odysseus::ConfigError, /REGISTRY_TOKEN/)
    end

    it 'never falls back to the env var when a secret key is named' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return(nil)
      c = creds({ server: 'ghcr.io', username: 'wa', password_secret: 'REGISTRY_TOKEN' },
                env: { 'ODYSSEUS_REGISTRY_PASSWORD' => 'from-env' })
      expect { c.password }.to raise_error(Odysseus::ConfigError)
    end
  end

  describe 'literal password' do
    it 'is still accepted' do
      expect(creds({ server: 'ghcr.io', username: 'wa', password: 'literal' }).password).to eq('literal')
    end
  end

  describe 'both sources set' do
    it 'raises rather than picking one' do
      c = creds({ server: 'ghcr.io', username: 'wa', password: 'literal', password_secret: 'REGISTRY_TOKEN' })
      expect { c.password }.to raise_error(Odysseus::ConfigError, /both/i)
    end
  end

  describe 'neither source set' do
    it 'reads ODYSSEUS_REGISTRY_PASSWORD, for CI' do
      c = creds({ server: 'ghcr.io', username: 'wa' }, env: { 'ODYSSEUS_REGISTRY_PASSWORD' => 'from-env' })
      expect(c.password).to eq('from-env')
    end

    it 'is incomplete with no password anywhere, which is public-image mode' do
      expect(creds({ server: 'ghcr.io', username: 'wa' }).complete?).to be false
    end
  end

  describe '#complete?' do
    it 'needs server, username and password' do
      expect(creds({ server: 'ghcr.io', username: 'wa', password: 'p' }).complete?).to be true
    end

    it 'is false without a username' do
      expect(creds({ server: 'ghcr.io', password: 'p' }).complete?).to be false
    end

    it 'is false for an empty registry config' do
      expect(creds({}).complete?).to be false
    end
  end

  describe '#configured?' do
    it 'is true when a server is set, which is what switches distribution' do
      expect(creds({ server: 'ghcr.io' }).configured?).to be true
    end

    it 'is false with no server' do
      expect(creds({}).configured?).to be false
    end
  end
end
