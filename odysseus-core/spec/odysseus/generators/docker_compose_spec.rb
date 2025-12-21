# spec/odysseus/generators/docker_compose_spec.rb

require 'spec_helper'
require 'yaml'

RSpec.describe Odysseus::Generators::DockerCompose do
  let(:fixture_file) { fixture_path('deploy.yml') }
  let(:parser) { Odysseus::Config::Parser.new(fixture_file) }
  let(:config) { parser.parse }
  let(:generator) { described_class.new(config) }

  describe '#generate' do
    subject(:output) { generator.generate }
    let(:parsed) { YAML.safe_load(output) }

    it 'returns valid YAML' do
      expect { parsed }.not_to raise_error
    end

    it 'includes version 3.8' do
      expect(parsed['version']).to eq('3.8')
    end

    it 'creates a service with the correct name' do
      expect(parsed['services']).to have_key('df')
    end

    describe 'service configuration' do
      let(:service) { parsed['services']['df'] }

      it 'sets the image with :latest tag' do
        expect(service['image']).to eq('myapp-production:latest')
      end

      it 'exposes the app port' do
        expect(service['ports']).to include('3000:3000')
      end

      it 'sets restart policy' do
        expect(service['restart']).to eq('unless-stopped')
      end

      describe 'environment variables' do
        let(:env) { service['environment'] }

        it 'includes clear env vars with their values' do
          expect(env['RAILS_ENV']).to eq('production')
          expect(env['RAILS_HOST']).to eq('https://app.example.com')
          expect(env['WORKER_PROCESSES']).to eq('8')
        end

        it 'includes secret env vars as placeholders' do
          expect(env['RAILS_MASTER_KEY']).to eq('${RAILS_MASTER_KEY}')
          expect(env['DATABASE_URL']).to eq('${DATABASE_URL}')
          expect(env['SECONDARY_DATABASE_URL']).to eq('${SECONDARY_DATABASE_URL}')
        end
      end

      describe 'resource limits' do
        let(:deploy) { service['deploy'] }
        let(:resources) { deploy['resources'] }

        it 'sets memory limit' do
          expect(resources['limits']['memory']).to eq('12g')
        end

        it 'sets memory reservation' do
          expect(resources['reservations']['memory']).to eq('10g')
        end
      end
    end
  end

  describe 'with minimal config' do
    let(:minimal_config) do
      {
        service: 'myapp',
        image: 'myapp-prod',
        servers: {
          web: {
            hosts: ['server1'],
            options: {}
          }
        },
        proxy: {
          app_port: 8080
        },
        env: {
          clear: {},
          secret: []
        }
      }
    end
    let(:generator) { described_class.new(minimal_config) }

    it 'generates valid output without optional fields' do
      output = generator.generate
      parsed = YAML.safe_load(output)

      expect(parsed['services']['myapp']['image']).to eq('myapp-prod:latest')
      expect(parsed['services']['myapp']['ports']).to include('8080:8080')
    end
  end
end
