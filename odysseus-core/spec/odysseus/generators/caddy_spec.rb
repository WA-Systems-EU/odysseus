# spec/odysseus/generators/caddy_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Generators::Caddy do
  let(:fixture_file) { fixture_path('deploy.yml') }
  let(:parser) { Odysseus::Config::Parser.new(fixture_file) }
  let(:config) { parser.parse }
  let(:generator) { described_class.new(config) }

  describe '#generate' do
    subject(:output) { generator.generate }

    it 'generates a block for each host' do
      expect(output).to include('app.example.com')
      expect(output).to include('example.com')
      expect(output).to include('www.example.com')
    end

    it 'includes reverse_proxy directive with service and port' do
      expect(output).to include('reverse_proxy df:3000')
    end

    it 'includes response timeout' do
      expect(output).to include('timeout 120s')
    end

    describe 'healthcheck configuration' do
      it 'includes health_uri from config' do
        expect(output).to include('health_uri /releases/current')
      end

      it 'includes health_interval' do
        expect(output).to include('health_interval 3s')
      end

      it 'includes health_timeout' do
        expect(output).to include('health_timeout 3s')
      end
    end

    it 'generates valid Caddyfile syntax with braces' do
      # Each host block should have opening and closing braces
      expect(output.scan('{').count).to be >= 3
      expect(output.scan('}').count).to be >= 3
    end
  end

  describe 'with no proxy config' do
    let(:config_without_proxy) do
      {
        service: 'myapp',
        image: 'myapp-prod',
        servers: { web: { hosts: ['server1'], options: {} } },
        proxy: {},
        env: { clear: {}, secret: [] }
      }
    end
    let(:generator) { described_class.new(config_without_proxy) }

    it 'returns empty string' do
      expect(generator.generate).to eq('')
    end
  end

  describe 'with minimal proxy config' do
    let(:minimal_config) do
      {
        service: 'myapp',
        image: 'myapp-prod',
        servers: { web: { hosts: ['server1'], options: {} } },
        proxy: {
          hosts: ['example.com'],
          app_port: 8080,
          response_timeout: 60,
          healthcheck: {}
        },
        env: { clear: {}, secret: [] }
      }
    end
    let(:generator) { described_class.new(minimal_config) }

    it 'generates basic reverse proxy' do
      output = generator.generate
      expect(output).to include('example.com')
      expect(output).to include('reverse_proxy myapp:8080')
      expect(output).to include('timeout 60s')
    end
  end
end
