# spec/odysseus/docker/labels_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Docker::Labels do
  describe '.parse' do
    it 'parses the comma separated pairs docker ps emits' do
      parsed = described_class.parse('odysseus.service=myapp,odysseus.version=abc123def456')

      expect(parsed).to eq(
        'odysseus.service' => 'myapp',
        'odysseus.version' => 'abc123def456'
      )
    end

    it 'keeps a value containing an equals sign intact' do
      parsed = described_class.parse('odysseus.git_ref=feature=x')

      expect(parsed['odysseus.git_ref']).to eq('feature=x')
    end

    it 'returns an empty hash for nil or empty input' do
      expect(described_class.parse(nil)).to eq({})
      expect(described_class.parse('')).to eq({})
    end
  end

  describe '.version_of' do
    it 'reads the version label from a docker ps entry' do
      container = { 'Labels' => 'odysseus.service=myapp,odysseus.version=abc123def456' }

      expect(described_class.version_of(container)).to eq('abc123def456')
    end

    it 'is nil when the container carries no version label' do
      expect(described_class.version_of({ 'Labels' => 'foo=bar' })).to be_nil
    end
  end
end
