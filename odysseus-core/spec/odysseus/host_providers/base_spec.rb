# spec/odysseus/host_providers/base_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::HostProviders::Base do
  let(:config) { { hosts: ['host1'] } }

  describe '#initialize' do
    it 'stores the config' do
      provider = described_class.new(config)
      expect(provider.instance_variable_get(:@config)).to eq(config)
    end
  end

  describe '#resolve' do
    it 'raises NotImplementedError' do
      provider = described_class.new(config)
      expect { provider.resolve }
        .to raise_error(NotImplementedError, /Subclasses must implement/)
    end
  end

  describe '#name' do
    it 'returns the class name' do
      provider = described_class.new(config)
      expect(provider.name).to eq('Base')
    end
  end
end
