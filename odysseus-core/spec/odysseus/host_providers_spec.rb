# spec/odysseus/host_providers_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::HostProviders do
  describe '.build' do
    it 'returns Static provider when hosts are specified' do
      role_config = { hosts: %w[host1 host2] }
      provider = described_class.build(role_config)

      expect(provider).to be_a(Odysseus::HostProviders::Static)
      expect(provider.resolve).to eq(%w[host1 host2])
    end

    it 'raises error when aws config specified but provider not loaded' do
      role_config = {
        aws: {
          asg: 'my-asg',
          region: 'us-east-1'
        }
      }

      expect { described_class.build(role_config) }
        .to raise_error(Odysseus::ConfigError, /odysseus-sail-aws-asg gem loaded/)
    end

    it 'uses registered aws_asg provider when available' do
      mock_provider_class = Class.new(Odysseus::HostProviders::Base) do
        def initialize(config)
          super
          @asg = config[:asg]
        end

        def resolve = ['10.0.0.1']
        def name = "aws_asg(#{@asg})"
      end

      described_class.register(:aws_asg, mock_provider_class)

      role_config = { aws: { asg: 'my-asg', region: 'us-east-1' } }
      provider = described_class.build(role_config)

      expect(provider.name).to eq('aws_asg(my-asg)')
      expect(provider.resolve).to eq(['10.0.0.1'])

      # Clean up
      described_class.providers.delete(:aws_asg)
    end

    it 'returns empty Static provider when no hosts configured' do
      role_config = { options: { memory: '2g' } }
      provider = described_class.build(role_config)

      expect(provider).to be_a(Odysseus::HostProviders::Static)
      expect(provider.resolve).to eq([])
    end
  end

  describe '.resolve' do
    it 'builds provider and returns resolved hosts' do
      role_config = { hosts: ['192.168.1.1', 'server.example.com'] }

      expect(described_class.resolve(role_config)).to eq(['192.168.1.1', 'server.example.com'])
    end

    it 'returns empty array for empty config' do
      expect(described_class.resolve({})).to eq([])
    end
  end

  describe '.register' do
    it 'allows registering custom providers' do
      custom_provider = Class.new(Odysseus::HostProviders::Base) do
        def resolve
          ['custom-host']
        end
      end

      described_class.register(:custom, custom_provider)
      expect(described_class.providers[:custom]).to eq(custom_provider)
    end

    it 'raises error if provider does not inherit from Base' do
      invalid_provider = Class.new

      expect { described_class.register(:invalid, invalid_provider) }
        .to raise_error(ArgumentError, /must inherit from/)
    end
  end
end
