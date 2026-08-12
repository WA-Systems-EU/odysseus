# lib/odysseus/host_providers/static.rb

module Odysseus
  module HostProviders
    # Static host provider - returns a fixed list of hosts
    # This is the default provider when hosts are specified directly in config
    class Static < Base
      # @param config [Hash] configuration with :hosts key
      def initialize(config)
        super
        @hosts = config[:hosts] || []
      end

      # @return [Array<String>] the static list of hosts
      def resolve
        @hosts
      end

      def name
        'static'
      end
    end
  end
end
