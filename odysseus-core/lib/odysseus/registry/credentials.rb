# lib/odysseus/registry/credentials.rb

module Odysseus
  module Registry
    # The credential a deploy host needs to pull a private image.
    #
    # Resolved from exactly one source. Sources are not a cascade on purpose:
    # falling through from a named secret to an environment variable is how a
    # deploy authenticates with the wrong credential and reports success.
    #
    # Deliberately not routed through Core::Environment, whose secret_value
    # falls back to the deploy target's own environment -- a host that happens
    # to have REGISTRY_TOKEN set for an unrelated reason has no business
    # authenticating someone else's deploy.
    class Credentials
      ENV_VAR = 'ODYSSEUS_REGISTRY_PASSWORD'.freeze

      # @param registry [Hash] config[:registry]
      # @param secrets_loader [Odysseus::Secrets::Loader, nil]
      # @param env [Hash] the environment of the machine running odysseus,
      #   never the deploy host's
      def initialize(registry, secrets_loader:, env: ENV)
        @registry = registry || {}
        @secrets_loader = secrets_loader
        @env = env
      end

      def server = @registry[:server]
      def username = @registry[:username]

      # @raise [Odysseus::ConfigError] when both sources are set, or when a
      #   named secret is not in the file
      # @return [String, nil] nil means public-image mode, which is valid
      def password
        raise Odysseus::ConfigError, both_sources_message if literal && secret_key

        return from_secrets if secret_key
        return literal_with_deprecation_warning if literal

        value = @env[ENV_VAR]
        value unless value.nil? || value.empty?
      end

      # @return [Boolean] whether a server is configured at all, which is what
      #   switches distribution away from pussh
      def configured?
        !server.nil? && !server.to_s.empty?
      end

      # @return [Boolean] whether a host login is possible
      def complete?
        return false unless configured?
        return false if username.nil? || username.to_s.empty?

        pw = password
        !pw.nil? && !pw.empty?
      end

      private

      def literal = @registry[:password]
      def secret_key = @registry[:password_secret]

      # #password is called more than once per deploy -- #complete? checks it,
      # then HostSession reads it again to log in -- so the warning is gated
      # on an instance flag rather than printed every call. One Credentials
      # per deploy (Executor memoizes it), so this is one notice per deploy,
      # not one per host or per role.
      def literal_with_deprecation_warning
        unless @warned_literal_password
          warn 'registry.password is deprecated and will be removed one release after this one. ' \
               'Use registry.password_secret to read the credential from the encrypted secrets file instead.'
          @warned_literal_password = true
        end

        literal
      end

      def from_secrets
        value = @secrets_loader&.get(secret_key)
        raise Odysseus::ConfigError, missing_secret_message if value.nil? || value.to_s.empty?

        value.to_s
      end

      def missing_secret_message
        "registry.password_secret names '#{secret_key}', which is not in the secrets file. " \
          'Add it there, or set registry.password instead.'
      end

      def both_sources_message
        'registry has both password and password_secret set. Pick one: password_secret reads the ' \
          'encrypted secrets file, password is the literal value in deploy.yml.'
      end
    end
  end
end
