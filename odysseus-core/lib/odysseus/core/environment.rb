# lib/odysseus/core/environment.rb

module Odysseus
  module Core
    # The environment a container starts with: the clear values from deploy.yml
    # merged with the secret ones, each read from the encrypted secrets file
    # when one is configured and from the deploy target's own environment
    # otherwise. A secret that is set in neither place is left out rather than
    # injected empty.
    #
    # A class, where the neighbouring DeployVersioning and VolumeNamespacer are
    # mixins. Those are only ever included by orchestrators, which all carry
    # @config, @ssh and @secrets_loader, so a mixin costs them nothing. This one
    # has a third caller: the CLI's one-off commands (`app exec`, `shell`,
    # `console`) need the same environment, and the CLI is not an orchestrator —
    # it has none of those ivars. Passing the collaborators in is what makes the
    # code reusable from there; a mixin would make the CLI grow state it has no
    # other use for just to satisfy this module's expectations.
    class Environment
      # @param config [Hash] parsed deploy config; only config[:env] is read
      # @param secrets_loader [Odysseus::Secrets::Loader, nil] encrypted secrets, when configured
      # @param ssh [Odysseus::Deployer::SSH] connection used to read the host's own environment
      def initialize(config:, secrets_loader:, ssh:)
        @config = config
        @secrets_loader = secrets_loader
        @ssh = ssh
      end

      # @return [Hash{String => String}] variables to inject into the container
      def build
        env_config = @config[:env] || {}
        env = {}

        # Clear env vars (hardcoded values)
        env_config[:clear]&.each do |key, value|
          env[key.to_s] = value.to_s
        end

        # Secret env vars - first try encrypted file, then server environment
        env_config[:secret]&.each do |key|
          value = secret_value(key)
          env[key.to_s] = value if value
        end

        env
      end

      private

      # @return [String, nil] the secret's value, nil when it is set nowhere
      def secret_value(key)
        if @secrets_loader&.configured?
          value = @secrets_loader.get(key)
          return value.to_s if value
        end

        # Fall back to server's environment
        value = @ssh.execute("echo $#{key}").strip
        value unless value.empty?
      end
    end
  end
end
