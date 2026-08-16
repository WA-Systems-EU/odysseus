# spec/odysseus/core/environment_spec.rb
#
# Tested directly rather than through an orchestrator: the same environment is
# what a one-off `app exec` container gets, so the rules live here and not in
# any one caller.

require 'spec_helper'

RSpec.describe Odysseus::Core::Environment do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_loader) { instance_double(Odysseus::Secrets::Loader) }

  # Deliberately uneven: two clear values of different types, and three secrets
  # that each take a different path — one found in the encrypted file, one the
  # file does not carry, one that is set nowhere at all.
  let(:config) do
    {
      env: {
        clear: { RAILS_ENV: 'production', WEB_CONCURRENCY: 4 },
        secret: %w[DATABASE_URL SECRET_KEY_BASE UNSET_EVERYWHERE]
      }
    }
  end

  def build(secrets_loader: nil, config: self.config)
    described_class.new(config: config, secrets_loader: secrets_loader, ssh: mock_ssh).build
  end

  describe 'clear values' do
    before { allow(mock_ssh).to receive(:execute).and_return("\n") }

    it 'passes them through as strings, keyed by name' do
      expect(build).to include('RAILS_ENV' => 'production', 'WEB_CONCURRENCY' => '4')
    end

    it 'asks the host for nothing when there are no secrets' do
      expect(mock_ssh).not_to receive(:execute)

      expect(build(config: { env: { clear: { 'A' => 'b' } } })).to eq('A' => 'b')
    end

    it 'is empty when the config declares no environment at all' do
      expect(build(config: {})).to eq({})
    end
  end

  describe 'secret values' do
    context 'with an encrypted secrets file' do
      before do
        allow(mock_loader).to receive(:configured?).and_return(true)
        allow(mock_loader).to receive(:get).with('DATABASE_URL').and_return('postgres://user:pa ss@db/app')
        allow(mock_loader).to receive(:get).with('SECRET_KEY_BASE').and_return(nil)
        allow(mock_loader).to receive(:get).with('UNSET_EVERYWHERE').and_return(nil)
        allow(mock_ssh).to receive(:execute).with('echo $SECRET_KEY_BASE').and_return("from-the-host\n")
        allow(mock_ssh).to receive(:execute).with('echo $UNSET_EVERYWHERE').and_return("\n")
      end

      it 'prefers the value in the file' do
        expect(build(secrets_loader: mock_loader)['DATABASE_URL']).to eq('postgres://user:pa ss@db/app')
      end

      it 'never asks the host for a key the file supplied' do
        expect(mock_ssh).not_to receive(:execute).with('echo $DATABASE_URL')

        build(secrets_loader: mock_loader)
      end

      it 'falls back to the host for a key the file does not carry' do
        expect(build(secrets_loader: mock_loader)['SECRET_KEY_BASE']).to eq('from-the-host')
      end

      it 'omits a key that is set neither in the file nor on the host' do
        expect(build(secrets_loader: mock_loader)).not_to have_key('UNSET_EVERYWHERE')
      end
    end

    context 'without a secrets loader' do
      before do
        allow(mock_ssh).to receive(:execute).with('echo $DATABASE_URL').and_return("postgres://db/app\n")
        allow(mock_ssh).to receive(:execute).with('echo $SECRET_KEY_BASE').and_return("  padded  \n")
        allow(mock_ssh).to receive(:execute).with('echo $UNSET_EVERYWHERE').and_return("\n")
      end

      it 'reads every secret from the host environment' do
        expect(build['DATABASE_URL']).to eq('postgres://db/app')
      end

      it 'strips the shell output around the value' do
        expect(build['SECRET_KEY_BASE']).to eq('padded')
      end

      it 'omits a key the host does not set' do
        expect(build).not_to have_key('UNSET_EVERYWHERE')
      end
    end

    # A secrets file that was configured but is not the source of a given key
    # must not shadow the host's value with nothing.
    context 'with a loader that is not configured' do
      before do
        allow(mock_loader).to receive(:configured?).and_return(false)
        allow(mock_ssh).to receive(:execute).and_return("from-the-host\n")
      end

      it 'ignores it and reads the host environment' do
        expect(mock_loader).not_to receive(:get)

        expect(build(secrets_loader: mock_loader)['DATABASE_URL']).to eq('from-the-host')
      end
    end

    it 'lets a secret win over a clear value of the same name' do
      allow(mock_loader).to receive(:configured?).and_return(true)
      allow(mock_loader).to receive(:get).with('RAILS_ENV').and_return('staging')

      config = { env: { clear: { 'RAILS_ENV' => 'production' }, secret: ['RAILS_ENV'] } }

      expect(build(secrets_loader: mock_loader, config: config)).to eq('RAILS_ENV' => 'staging')
    end
  end
end
