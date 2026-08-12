# frozen_string_literal: true

require_relative "lib/odysseus/cli/version"

Gem::Specification.new do |spec|
  spec.name          = "odysseus-cli"
  spec.version       = Odysseus::CLI::VERSION
  spec.authors       = ["Thomas"]
  spec.email         = ["thomas@imfiny.com"]
  spec.summary       = "CLI for Odysseus deployment tool"
  spec.description   = "Command-line interface for deploying with Odysseus"
  spec.homepage      = "https://github.com/WA-Systems-EU/odysseus"
  spec.license       = "MIT"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/trunk/odysseus-cli/CHANGELOG.md"

  spec.files         = Dir["lib/**/*", "bin/*", "README.md", "LICENSE.txt"]
  spec.executables   = ["odysseus"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2.0"

  # Lockstep with core: the CLI relies on deploy behaviour fixed in 0.3.2.
  spec.add_dependency "odysseus-core", "~> 0.3", ">= 0.3.2"

  spec.add_development_dependency "pry-byebug", "~> 3.10"
  spec.add_development_dependency "rspec", "~> 3.12"
end
