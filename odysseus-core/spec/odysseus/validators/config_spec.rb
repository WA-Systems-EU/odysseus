# spec/odysseus/validators/config_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Validators::Config do
  # Raw string-keyed config, as it comes out of YAML.load_file.
  let(:valid_config) do
    {
      'service' => 'myapp',
      'image' => 'myapp-production',
      'servers' => {
        'web' => { 'hosts' => ['web1.example.com'] }
      }
    }
  end

  def validate(config)
    described_class.new(config).validate!
  end

  describe 'required keys' do
    it 'accepts a config with service, image and servers' do
      expect { validate(valid_config) }.not_to raise_error
    end

    ['service', 'image', 'servers'].each do |key|
      it "rejects a config missing #{key}" do
        expect { validate(valid_config.reject { |k, _| k == key }) }
          .to raise_error(Odysseus::ConfigValidationError, /Missing required keys: #{key}/)
      end
    end

    it 'names every missing key at once' do
      expect { validate({ 'image' => 'myapp' }) }
        .to raise_error(Odysseus::ConfigValidationError, /service, servers/)
    end

    it 'treats an explicitly nil key as missing' do
      expect { validate(valid_config.merge('service' => nil)) }
        .to raise_error(Odysseus::ConfigValidationError, /Missing required keys: service/)
    end
  end

  describe 'servers' do
    it 'rejects servers that are not a hash' do
      expect { validate(valid_config.merge('servers' => ['web1.example.com'])) }
        .to raise_error(Odysseus::ConfigValidationError, /servers must be a hash/)
    end

    it 'rejects a role without hosts' do
      config = valid_config.merge('servers' => { 'web' => { 'cmd' => 'bin/rails s' } })

      expect { validate(config) }
        .to raise_error(Odysseus::ConfigValidationError, /server role 'web' must have 'hosts' array/)
    end

    it 'rejects a role whose hosts are not an array' do
      config = valid_config.merge('servers' => { 'web' => { 'hosts' => 'web1.example.com' } })

      expect { validate(config) }
        .to raise_error(Odysseus::ConfigValidationError, /must have 'hosts' array/)
    end

    it 'rejects a role that is not a hash at all' do
      config = valid_config.merge('servers' => { 'web' => 'web1.example.com' })

      expect { validate(config) }
        .to raise_error(Odysseus::ConfigValidationError, /server role 'web'/)
    end

    it 'accepts multiple roles' do
      config = valid_config.merge('servers' => {
        'web' => { 'hosts' => ['web1.example.com'] },
        'jobs' => { 'hosts' => ['worker1.example.com'], 'cmd' => 'bundle exec good_job' }
      })

      expect { validate(config) }.not_to raise_error
    end
  end

  describe 'proxy' do
    it 'requires app_port when a proxy block is present' do
      config = valid_config.merge('proxy' => { 'hosts' => ['app.example.com'] })

      expect { validate(config) }
        .to raise_error(Odysseus::ConfigValidationError, /proxy must have 'app_port'/)
    end

    it 'accepts a proxy with app_port' do
      config = valid_config.merge('proxy' => { 'hosts' => ['app.example.com'], 'app_port' => 3000 })

      expect { validate(config) }.not_to raise_error
    end

    it 'skips proxy validation when there is no proxy block' do
      expect { validate(valid_config) }.not_to raise_error
    end
  end

  describe 'env' do
    it 'rejects env that is not a hash' do
      expect { validate(valid_config.merge('env' => ['RAILS_ENV=production'])) }
        .to raise_error(Odysseus::ConfigValidationError, /env must be a hash/)
    end

    it 'rejects env.clear that is not a hash' do
      config = valid_config.merge('env' => { 'clear' => ['RAILS_ENV=production'] })

      expect { validate(config) }
        .to raise_error(Odysseus::ConfigValidationError, /env.clear must be a hash/)
    end

    it 'rejects env.secret that is not an array' do
      config = valid_config.merge('env' => { 'secret' => { 'DATABASE_URL' => true } })

      expect { validate(config) }
        .to raise_error(Odysseus::ConfigValidationError, /env.secret must be an array/)
    end

    it 'accepts clear and secret in their expected shapes' do
      config = valid_config.merge('env' => {
        'clear' => { 'RAILS_ENV' => 'production' },
        'secret' => ['DATABASE_URL']
      })

      expect { validate(config) }.not_to raise_error
    end
  end

  describe 'ssh' do
    it 'rejects ssh that is not a hash' do
      expect { validate(valid_config.merge('ssh' => 'root')) }
        .to raise_error(Odysseus::ConfigValidationError, /ssh must be a hash/)
    end

    it 'rejects ssh.keys that is not an array' do
      config = valid_config.merge('ssh' => { 'keys' => '~/.ssh/id_ed25519' })

      expect { validate(config) }
        .to raise_error(Odysseus::ConfigValidationError, /ssh.keys must be an array/)
    end

    it 'accepts ssh without keys' do
      expect { validate(valid_config.merge('ssh' => { 'user' => 'deploy' })) }.not_to raise_error
    end
  end

  describe 'containers' do
    def config_with_containers(containers)
      valid_config.merge('servers' => {
        'web' => { 'hosts' => ['web1.example.com'], 'containers' => containers }
      })
    end

    it 'rejects a count below one' do
      expect { validate(config_with_containers('count' => 0)) }
        .to raise_error(Odysseus::ConfigValidationError, /containers.count must be an integer >= 1/)
    end

    it 'rejects a non-integer count' do
      expect { validate(config_with_containers('count' => '3')) }
        .to raise_error(Odysseus::ConfigValidationError, /containers.count must be an integer >= 1/)
    end

    it 'names the offending role' do
      expect { validate(config_with_containers('count' => 0)) }
        .to raise_error(Odysseus::ConfigValidationError, /servers.web.containers.count/)
    end

    it 'accepts a valid count' do
      expect { validate(config_with_containers('count' => 3)) }.not_to raise_error
    end
  end

  describe 'deploy' do
    def config_with_deploy(deploy)
      valid_config.merge('servers' => {
        'web' => { 'hosts' => ['web1.example.com'], 'deploy' => deploy }
      })
    end

    around do |example|
      Odysseus::Sails.reset!
      example.run
      Odysseus::Sails.reset!
    end

    it 'rejects a strategy no sail has registered' do
      expect { validate(config_with_deploy('strategy' => 'rolling')) }
        .to raise_error(Odysseus::ConfigValidationError, /'rolling' is not registered/)
    end

    it 'accepts a strategy once a sail registers it' do
      Odysseus::Sails.register(:rolling, Class.new)

      expect { validate(config_with_deploy('strategy' => 'rolling')) }.not_to raise_error
    end

    it 'accepts a deploy block with no strategy' do
      expect { validate(config_with_deploy('drain_timeout' => 30)) }.not_to raise_error
    end

    ['drain_timeout', 'stop_timeout', 'boot_timeout'].each do |key|
      it "rejects a non-integer #{key}" do
        expect { validate(config_with_deploy(key => '30')) }
          .to raise_error(Odysseus::ConfigValidationError, /#{key} must be a positive integer/)
      end

      it "rejects a negative #{key}" do
        expect { validate(config_with_deploy(key => -1)) }
          .to raise_error(Odysseus::ConfigValidationError, /#{key} must be a positive integer/)
      end
    end

    it 'accepts positive timeouts' do
      deploy = { 'drain_timeout' => 30, 'stop_timeout' => 10, 'boot_timeout' => 60 }

      expect { validate(config_with_deploy(deploy)) }.not_to raise_error
    end
  end
end
