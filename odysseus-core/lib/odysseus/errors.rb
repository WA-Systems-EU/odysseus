# lib/odysseus/errors.rb

module Odysseus
  class Error < StandardError; end

  class ConfigError < Error; end
  class ConfigParseError < ConfigError; end
  class ConfigValidationError < ConfigError; end
  class ConfigMissingKeyError < ConfigError; end

  class DeployError < Error; end
  class RollbackError < DeployError; end
  class SSHError < DeployError; end
  class SSHConnectionError < SSHError; end
  class SSHCommandError < SSHError; end

  class ProxyError < Error; end
  class ProxyApiError < ProxyError; end

  class RegistryError < Error; end
  class RegistryPushError < RegistryError; end
  class RegistryAuthError < RegistryError; end

  class BuildError < Error; end
  class BuildFailedError < BuildError; end
  class BuildContextError < BuildError; end

  class GeneratorError < Error; end
  class DockerComposeGenerationError < GeneratorError; end
  class CaddyGenerationError < GeneratorError; end
end
