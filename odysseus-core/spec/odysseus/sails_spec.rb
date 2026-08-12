# spec/odysseus/sails_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Sails do
  # The registry is global state, so every example starts and ends clean.
  around do |example|
    described_class.reset!
    example.run
    described_class.reset!
  end

  let(:orchestrator_class) { Class.new }

  describe '.register' do
    it 'makes a strategy resolvable' do
      described_class.register(:rolling, orchestrator_class)

      expect(described_class.resolve(:rolling)).to be(orchestrator_class)
    end

    it 'accepts a string name and resolves it by symbol' do
      described_class.register('rolling', orchestrator_class)

      expect(described_class.resolve(:rolling)).to be(orchestrator_class)
    end

    it 'lets a later registration replace an earlier one' do
      replacement = Class.new
      described_class.register(:rolling, orchestrator_class)
      described_class.register(:rolling, replacement)

      expect(described_class.resolve(:rolling)).to be(replacement)
    end
  end

  describe '.resolve' do
    it 'returns nil for a strategy that was never registered' do
      expect(described_class.resolve(:canary)).to be_nil
    end
  end

  describe '.registered?' do
    it 'is true for a registered strategy' do
      described_class.register(:rolling, orchestrator_class)

      expect(described_class.registered?(:rolling)).to be true
    end

    it 'is true when asked with a string' do
      described_class.register(:rolling, orchestrator_class)

      expect(described_class.registered?('rolling')).to be true
    end

    it 'is false for an unknown strategy' do
      expect(described_class.registered?(:rolling)).to be false
    end
  end

  describe '.available' do
    it 'lists registered strategy names as symbols' do
      described_class.register(:rolling, orchestrator_class)
      described_class.register('canary', Class.new)

      expect(described_class.available).to contain_exactly(:rolling, :canary)
    end

    it 'is empty when nothing is registered' do
      expect(described_class.available).to be_empty
    end
  end

  describe '.reset!' do
    it 'forgets every registered strategy' do
      described_class.register(:rolling, orchestrator_class)

      described_class.reset!

      expect(described_class.available).to be_empty
      expect(described_class.registered?(:rolling)).to be false
    end
  end
end
