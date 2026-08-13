# spec/odysseus/plugins_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Plugins do
  # The fixture directory goes on the load path so `require 'fake_sail'`
  # resolves — the same way a real gem's lib directory would.
  around do |example|
    Odysseus::Sails.reset!
    $LOAD_PATH.unshift(fixture_path('plugins'))
    example.run
  ensure
    $LOAD_PATH.delete(fixture_path('plugins'))
    $LOADED_FEATURES.reject! { |f| f.include?('fake_sail') }
    Odysseus::Sails.reset!
  end

  describe '.load!' do
    it 'requires each named plugin, so its registration runs' do
      described_class.load!('plugins' => ['fake_sail'])

      expect(Odysseus::Sails.registered?(:fake)).to be true
    end

    it 'accepts sails as an alias for plugins' do
      described_class.load!('sails' => ['fake_sail'])

      expect(Odysseus::Sails.registered?(:fake)).to be true
    end

    it 'does nothing when neither key is present' do
      expect { described_class.load!('service' => 'myapp') }.not_to raise_error
      expect(Odysseus::Sails.available).to be_empty
    end

    it 'loads nothing for an empty list' do
      described_class.load!('plugins' => [])

      expect(Odysseus::Sails.available).to be_empty
    end

    # Silently preferring one would let someone edit the wrong key and see no
    # effect, which is the failure mode a mistyped retain_versions already cost
    # a diagnosis round-trip.
    it 'refuses a config carrying both keys' do
      expect { described_class.load!('plugins' => ['a'], 'sails' => ['b']) }
        .to raise_error(Odysseus::ConfigError, /both `plugins:` and `sails:`/)
    end

    it 'names the gem that could not be loaded' do
      expect { described_class.load!('plugins' => ['odysseus-sail-nonexistent']) }
        .to raise_error(Odysseus::ConfigError, /odysseus-sail-nonexistent/)
    end

    it 'suggests how to fix a missing gem' do
      expect { described_class.load!('plugins' => ['odysseus-sail-nonexistent']) }
        .to raise_error(Odysseus::ConfigError, /gem install/)
    end

    it 'refuses a list that is not an array' do
      expect { described_class.load!('plugins' => 'odysseus-sail-rolling') }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end

    it 'refuses a list containing something that is not a string' do
      expect { described_class.load!('plugins' => [{ 'name' => 'x' }]) }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end

    it 'refuses a key present with no value' do
      expect { described_class.load!('plugins' => nil) }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end
  end
end
