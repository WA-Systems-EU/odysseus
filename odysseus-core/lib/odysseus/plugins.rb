# lib/odysseus/plugins.rb

module Odysseus
  # Loads the gems named in deploy.yml's `plugins:` list, so that the sail and
  # host-provider registries have something in them.
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
      names = names_from(raw_config)
      return if names.nil? && !key_present?(raw_config)

      unless names.is_a?(Array) && names.all?(String)
        raise Odysseus::ConfigError,
              "`plugins:` must be a list of gem names, got #{names.inspect}"
      end

      names.each { |name| require_plugin(name) }
      nil
    end

    def self.key_present?(raw_config)
      KEYS.any? { |key| raw_config.key?(key) }
    end

    def self.names_from(raw_config)
      present = KEYS.select { |key| raw_config.key?(key) }

      if present.length > 1
        raise Odysseus::ConfigError,
              'deploy.yml has both `plugins:` and `sails:` — use one; they name the same thing'
      end

      present.empty? ? nil : raw_config[present.first]
    end

    def self.require_plugin(name)
      require name
    rescue LoadError
      raise Odysseus::ConfigError,
            "Could not load the plugin `#{name}` named in deploy.yml. Install it with " \
            "`gem install #{name}`, or remove it from `plugins:`."
    end

    private_class_method :key_present?, :names_from, :require_plugin
  end
end
