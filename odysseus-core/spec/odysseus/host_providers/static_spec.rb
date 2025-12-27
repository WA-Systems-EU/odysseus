# spec/odysseus/host_providers/static_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::HostProviders::Static do
  describe '#initialize' do
    it 'accepts hosts from config' do
      provider = described_class.new(hosts: ['host1', 'host2'])
      expect(provider.resolve).to eq(['host1', 'host2'])
    end

    it 'defaults to empty array when no hosts provided' do
      provider = described_class.new({})
      expect(provider.resolve).to eq([])
    end
  end

  describe '#resolve' do
    it 'returns the static list of hosts' do
      hosts = ['192.168.1.1', 'server.example.com', '10.0.0.1']
      provider = described_class.new(hosts: hosts)

      expect(provider.resolve).to eq(hosts)
    end

    it 'returns empty array for empty hosts' do
      provider = described_class.new(hosts: [])
      expect(provider.resolve).to eq([])
    end
  end

  describe '#name' do
    it 'returns "static"' do
      provider = described_class.new(hosts: [])
      expect(provider.name).to eq('static')
    end
  end
end
