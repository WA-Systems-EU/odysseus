# spec/odysseus/host_providers_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::HostProviders do
  describe '.build' do
    it 'returns Static provider when hosts are specified' do
      role_config = { hosts: ['host1', 'host2'] }
      provider = described_class.build(role_config)

      expect(provider).to be_a(Odysseus::HostProviders::Static)
      expect(provider.resolve).to eq(['host1', 'host2'])
    end

    it 'returns AwsAsg provider when aws config is specified' do
      role_config = {
        aws: {
          asg: 'my-asg',
          region: 'us-east-1'
        }
      }
      provider = described_class.build(role_config)

      expect(provider).to be_a(Odysseus::HostProviders::AwsAsg)
      expect(provider.name).to eq('aws_asg(my-asg)')
    end

    it 'prefers AWS provider when both aws and hosts are specified' do
      role_config = {
        hosts: ['static-host'],
        aws: {
          asg: 'my-asg',
          region: 'us-east-1'
        }
      }
      provider = described_class.build(role_config)

      expect(provider).to be_a(Odysseus::HostProviders::AwsAsg)
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
