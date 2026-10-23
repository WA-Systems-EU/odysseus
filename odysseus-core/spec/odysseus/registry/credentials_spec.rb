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
    it 'is still accepted, and warns once that it is deprecated' do
      c = creds({ server: 'ghcr.io', username: 'wa', password: 'literal' })
      result = nil

      expect { result = c.password }.to output(/password_secret/).to_stderr
      expect(result).to eq('literal')
    end

    it 'warns only once even when #password is read more than once' do
      c = creds({ server: 'ghcr.io', username: 'wa', password: 'literal' })

      messages = []
      expect(c).to(receive(:warn).once { |msg| messages << msg })

      c.password
      c.password
      c.password

      expect(messages).to eq(messages.take(1))
    end

    it 'does not warn when password_secret is used instead' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return('s3cr3t')
      c = creds({ server: 'ghcr.io', username: 'wa', password_secret: 'REGISTRY_TOKEN' })

      expect { c.password }.not_to output.to_stderr
    end

    it 'does not warn when the credential comes from the env var' do
      c = creds({ server: 'ghcr.io', username: 'wa' }, env: { 'ODYSSEUS_REGISTRY_PASSWORD' => 'from-env' })

      expect { c.password }.not_to output.to_stderr
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
      # A literal password warns (see 'literal password' above); swallowed
      # here since this example is about #complete?, not the deprecation.
      result = nil
      expect { result = creds({ server: 'ghcr.io', username: 'wa', password: 'p' }).complete? }.to output.to_stderr
      expect(result).to be true
    end

    # A password with no username used to degrade silently to false --
    # credential-less mode -- which also skips the explicit pull and
    # reproduces the "container would not start" misdiagnosis this whole
    # branch exists to remove. A half-configured credential must fail loudly
    # instead.
    it 'raises naming what is missing when a password is configured but username is not' do
      error = nil
      expect do
        creds({ server: 'ghcr.io', password: 'p' }).complete?
      rescue Odysseus::ConfigError => e
        error = e
      end.to output.to_stderr # the literal password still warns; swallowed as above
      expect(error).to be_a(Odysseus::ConfigError)
      expect(error.message).to match(/username/i)
    end

    it 'raises the same way when the password comes from password_secret instead of the literal' do
      allow(loader).to receive(:get).with('REGISTRY_TOKEN').and_return('s3cr3t')
      expect { creds({ server: 'ghcr.io', password_secret: 'REGISTRY_TOKEN' }).complete? }
        .to raise_error(Odysseus::ConfigError, /username/i)
    end

    # The username check used to run before #password, so it short-circuited
    # the both-sources error whenever username was also missing.
    it 'still raises the both-sources error even when username is missing too' do
      c = creds({ server: 'ghcr.io', password: 'literal', password_secret: 'REGISTRY_TOKEN' })
      expect { c.complete? }.to raise_error(Odysseus::ConfigError, /both/i)
    end

    # The genuinely credential-less case -- public-image mode -- must keep
    # working with no error, username present or not.
    it 'is false, not an error, when no password is configured anywhere' do
      expect(creds({ server: 'ghcr.io', username: 'wa' }).complete?).to be false
    end

    it 'is false, not an error, when neither username nor password is configured' do
      expect(creds({ server: 'ghcr.io' }).complete?).to be false
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
