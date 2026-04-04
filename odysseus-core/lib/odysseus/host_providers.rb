# lib/odysseus/host_providers.rb

module Odysseus
  module HostProviders
    class << self
      # Registry of available host providers
      def providers
        @providers ||= {
          static: Static
        }
      end

      # Build a host provider from role configuration
      # @param role_config [Hash] role configuration from deploy.yml
      # @return [Base] host provider instance
      def build(role_config)
        if role_config[:aws] && providers[:aws_asg]
          providers[:aws_asg].new(role_config[:aws])
        elsif role_config[:aws]
          raise Odysseus::ConfigError,
                "AWS ASG host provider not available — is the odysseus-sail-aws-asg gem loaded?"
        elsif role_config[:hosts]
          Static.new(hosts: role_config[:hosts])
        else
          Static.new(hosts: [])
        end
      end

      # Resolve hosts from role configuration
      # @param role_config [Hash] role configuration from deploy.yml
      # @return [Array<String>] list of resolved hosts
      def resolve(role_config)
        provider = build(role_config)
        provider.resolve
      end

      # Register a custom host provider
      # @param name [Symbol] provider name
      # @param klass [Class] provider class (must inherit from Base)
      def register(name, klass)
        unless klass < Base
          raise ArgumentError, "Provider must inherit from Odysseus::HostProviders::Base"
        end
        providers[name] = klass
      end
    end
  end
end
