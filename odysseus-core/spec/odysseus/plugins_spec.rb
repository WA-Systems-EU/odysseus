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
    $LOADED_FEATURES.reject! { |f| f.start_with?(fixture_path('plugins')) }
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
        .to raise_error(Odysseus::ConfigError, /gem install odysseus-sail-nonexistent/)
    end

    # Even in the ordinary case the underlying error is quoted, so a load that
    # failed for some other reason than absence is not described as absence.
    it 'quotes the load error for a gem that is not there at all' do
      expect { described_class.load!('plugins' => ['odysseus-sail-nonexistent']) }
        .to raise_error(Odysseus::ConfigError, /cannot load such file/)
    end

    it 'points at the key the config used when telling the user to drop it' do
      expect { described_class.load!('plugins' => ['odysseus-sail-nonexistent']) }
        .to raise_error(Odysseus::ConfigError, /remove it from `plugins:`/)
    end

    # `gem install` is no use inside an app bundle, where the gem has to be
    # declared before bundler will let it be required at all.
    it 'mentions the Gemfile a bundled run would need' do
      expect { described_class.load!('plugins' => ['odysseus-sail-nonexistent']) }
        .to raise_error(Odysseus::ConfigError, /Gemfile/)
    end

    # A plugin that is installed but whose own dependency is missing used to
    # report as if the plugin were absent, advising an install that could not
    # fix it. The file that actually failed has to reach the user.
    it 'names the file an installed plugin failed to require' do
      expect { described_class.load!('plugins' => ['broken_sail']) }
        .to raise_error(Odysseus::ConfigError, /odysseus_missing_dependency/)
    end

    it 'does not blame the plugin gem when the plugin itself was found' do
      expect { described_class.load!('plugins' => ['broken_sail']) }
        .to raise_error(Odysseus::ConfigError, /installed but failed to load/)
    end

    it 'refuses a list that is not an array' do
      expect { described_class.load!('plugins' => 'odysseus-sail-rolling') }
        .to raise_error(Odysseus::ConfigError, /`plugins:` must be a list of gem names/)
    end

    it 'refuses a list containing something that is not a string' do
      expect { described_class.load!('plugins' => [{ 'name' => 'x' }]) }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end

    it 'refuses a key present with no value' do
      expect { described_class.load!('plugins' => nil) }
        .to raise_error(Odysseus::ConfigError, /list of gem names/)
    end

    # The `sails:` alias exists because it is the project's own vocabulary, so
    # a diagnostic that quotes `plugins:` sends the user looking for a key that
    # is not in their file.
    context 'when the config used the sails alias' do
      it 'quotes sails in the shape error' do
        expect { described_class.load!('sails' => 'odysseus-sail-rolling') }
          .to raise_error(Odysseus::ConfigError, /`sails:` must be a list of gem names/)
      end

      it 'quotes sails in the advice for a missing gem' do
        expect { described_class.load!('sails' => ['odysseus-sail-nonexistent']) }
          .to raise_error(Odysseus::ConfigError, /remove it from `sails:`/)
      end
    end
  end
end
