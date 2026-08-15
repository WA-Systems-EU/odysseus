# lib/odysseus/plugins.rb

module Odysseus
  # Loads the gems named in deploy.yml's `plugins:` (or `sails:`) list, so that
  # the sail and host-provider registries have something in them.
  #
  # Runs before config validation, because the validator is what asks whether a
  # named strategy is registered. That ordering is why this validates its own
  # shape rather than leaving it to Validators::Config like every other key.
  #
  # Requiring a gem name read from a config file is a real capability, and is
  # documented as such: deploy.yml already runs arbitrary docker commands as
  # root on the target hosts, so this widens visibility rather than trust.
  module Plugins
    # `sails:` matches the project's own vocabulary; `plugins:` is what someone
    # guesses without reading the docs. Both work, but not together.
    KEYS = %w[plugins sails].freeze

    # @param raw_config [Hash] the string-keyed hash straight from YAML
    # @raise [Odysseus::ConfigError] on an ambiguous pair, a bad shape, or a
    #   gem that will not load
    def self.load!(raw_config)
      key, names = names_from(raw_config)
      return if key.nil?

      unless names.is_a?(Array) && names.all?(String)
        raise Odysseus::ConfigError,
              "`#{key}:` must be a list of gem names, got #{names.inspect}"
      end

      names.each { |name| require_plugin(name, key) }
      nil
    end

    # Returns the key the config actually used alongside its value, so every
    # diagnostic can quote the key the user wrote rather than whichever of the
    # two aliases we happen to name first.
    #
    # @return [Array(String, Object)] the key and its value, or [nil, nil]
    def self.names_from(raw_config)
      present = KEYS.select { |key| raw_config.key?(key) }

      if present.length > 1
        raise Odysseus::ConfigError,
              'deploy.yml has both `plugins:` and `sails:` — use one; they name the same thing'
      end

      present.empty? ? [nil, nil] : [present.first, raw_config[present.first]]
    end

    def self.require_plugin(name, key)
      require name
    rescue LoadError => e
      raise Odysseus::ConfigError, load_failure_message(name, key, e)
    end

    # A plugin whose own `require` fails is installed already, so repeating the
    # install advice sends the user after a gem they have. The two cases read
    # differently, and both carry the file that was actually missing — without
    # it, a sail missing its SDK is indistinguishable from a sail missing.
    def self.load_failure_message(name, key, error)
      if error.path && error.path != name
        "The plugin `#{name}` named in deploy.yml is installed but failed to load: #{error.message}."
      else
        "Could not load the plugin `#{name}` named in deploy.yml (#{error.message}). Add it to your " \
          "Gemfile or run `gem install #{name}`, or remove it from `#{key}:`."
      end
    end

    private_class_method :names_from, :require_plugin, :load_failure_message
  end
end
