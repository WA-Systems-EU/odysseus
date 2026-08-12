# lib/odysseus/host_providers/base.rb

module Odysseus
  module HostProviders
    # Base class for host providers
    # Host providers resolve hostnames/IPs from different sources
    # (static lists, AWS ASG, etc.)
    class Base
      # @param config [Hash] provider-specific configuration
      def initialize(config)
        @config = config
      end

      # Resolve and return list of hosts
      # @return [Array<String>] list of hostnames or IPs
      def resolve
        raise NotImplementedError, 'Subclasses must implement #resolve'
      end

      # Provider name for display/logging
      # @return [String]
      def name
        self.class.name.split('::').last
      end
    end
  end
end
