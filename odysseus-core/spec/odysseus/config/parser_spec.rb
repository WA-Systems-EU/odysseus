# spec/odysseus/config/parser_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Config::Parser do
  let(:fixture_file) { fixture_path('deploy.yml') }
  let(:parser) { described_class.new(fixture_file) }

  describe '#parse' do
    it 'parses valid deploy.yml' do
      config = parser.parse

      expect(config[:service]).to eq('myapp')
      expect(config[:image]).to eq('myapp-production')
    end

    it 'parses servers' do
      config = parser.parse

      expect(config[:servers]).to have_key(:web)
      expect(config[:servers][:web][:hosts]).to include('app1.example.com')
      expect(config[:servers][:web][:options][:memory]).to eq('12g')
    end

    it 'parses proxy configuration' do
      config = parser.parse

      expect(config[:proxy][:hosts]).to include('app.example.com')
      expect(config[:proxy][:app_port]).to eq(3000)
      expect(config[:proxy][:response_timeout]).to eq(120)
    end

    it 'parses healthcheck configuration' do
      config = parser.parse

      expect(config[:proxy][:healthcheck][:interval]).to eq(3)
      expect(config[:proxy][:healthcheck][:path]).to eq('/health')
      expect(config[:proxy][:healthcheck][:timeout]).to eq(3)
    end

    it 'parses environment variables' do
      config = parser.parse

      expect(config[:env][:clear][:RAILS_ENV]).to eq('production')
      expect(config[:env][:clear][:RAILS_HOST]).to eq('https://app.example.com')
      expect(config[:env][:secret]).to include('RAILS_MASTER_KEY', 'DATABASE_URL')
    end

    it 'parses ssh configuration' do
      config = parser.parse

      expect(config[:ssh][:user]).to eq('root')
      expect(config[:ssh][:keys]).to include('~/.ssh/id_ed25519')
    end

    it 'raises error for missing required keys' do
      allow_any_instance_of(described_class).to receive(:load_yaml)
        .and_return({ 'image' => 'test' }) # missing 'service' and 'servers'

      expect { parser.parse }
        .to raise_error(Odysseus::ConfigValidationError, /Missing required keys/)
    end

    it 'raises error for invalid YAML' do
      invalid_parser = described_class.new(fixture_path('invalid.yml'))
      allow_any_instance_of(described_class).to receive(:load_yaml)
        .and_raise(Psych::SyntaxError.new(nil, 1, 1, 1, 'error', 'context'))

      expect { invalid_parser.parse }
        .to raise_error(Odysseus::ConfigParseError, /Failed to parse YAML/)
    end

    it 'raises error for missing file' do
      missing_parser = described_class.new('/nonexistent/deploy.yml')
      allow_any_instance_of(described_class).to receive(:load_yaml)
        .and_call_original

      expect { missing_parser.parse }
        .to raise_error(Odysseus::ConfigError, /Config file not found/)
    end

    it 'returns default values for optional config' do
      config = parser.parse

      expect(config[:builder]).to be_a(Hash)
      expect(config[:proxy][:ssl]).to be(false) # from fixture
    end

    it 'handles servers without options' do
      allow_any_instance_of(described_class).to receive(:load_yaml)
        .and_return({
                      'service' => 'test',
                      'image' => 'test-image',
                      'servers' => {
                        'web' => {
                          'hosts' => ['localhost']
                          # no options
                        }
                      }
                    })

      config = parser.parse

      expect(config[:servers][:web][:options]).to eq({})
    end
  end

  # `accessories:` was renamed to `dependencies:` because the old name implied
  # optional extras, when a database the app cannot boot without is not
  # optional. The old key keeps working for one release so existing deploy.yml
  # files can be updated at leisure.
  describe 'dependencies' do
    def parse(fixture)
      described_class.new(fixture_path(fixture)).parse
    end

    it 'parses the dependencies key' do
      config = parse('deploy-dependencies.yml')

      expect(config[:dependencies][:redis][:image]).to eq('redis:7')
      expect(config[:dependencies][:redis][:hosts]).to eq(%w[acc1.example.com acc2.example.com])
    end

    it 'still accepts the old accessories key' do
      config = parse('deploy-legacy-accessories.yml')

      expect(config[:dependencies][:redis][:image]).to eq('redis:7')
    end

    # Asserts non-emptiness first: comparing two nils would pass this happily
    # while neither key was being read at all.
    it 'parses the two keys identically' do
      from_new_key = parse('deploy-dependencies.yml')[:dependencies]

      expect(from_new_key.keys).to eq(%i[redis sidekiq])
      expect(from_new_key).to eq(parse('deploy-legacy-accessories.yml')[:dependencies])
    end

    it 'yields an empty hash when neither key is present' do
      expect(parse('deploy.yml')[:dependencies]).to eq({})
    end
  end

  describe 'retain_versions' do
    it 'defaults to 5 when not configured' do
      expect(parser.parse[:retain_versions]).to eq(5)
    end

    it 'reads a configured value' do
      config = described_class.new(fixture_path('deploy-retain-two.yml')).parse

      expect(config[:retain_versions]).to eq(2)
    end
  end
end
