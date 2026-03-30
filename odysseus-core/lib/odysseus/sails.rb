# lib/odysseus/sails.rb

module Odysseus
  module Sails
    class << self
      # Registry of available deploy strategy plugins (sails)
      def strategies
        @strategies ||= {}
      end

      # Register a deploy strategy
      # @param name [Symbol] strategy name (e.g., :rolling)
      # @param klass [Class] orchestrator class
      def register(name, klass)
        strategies[name.to_sym] = klass
      end

      # Look up a registered strategy
      # @param name [Symbol] strategy name
      # @return [Class, nil] orchestrator class or nil
      def resolve(name)
        strategies[name.to_sym]
      end

      # Check if a strategy is registered
      # @param name [Symbol] strategy name
      # @return [Boolean]
      def registered?(name)
        strategies.key?(name.to_sym)
      end

      # List all registered strategy names
      # @return [Array<Symbol>]
      def available
        strategies.keys
      end

      # Reset registry (for testing)
      def reset!
        @strategies = {}
      end
    end
  end
end
