# frozen_string_literal: true

require_relative 'lib/odysseus/cli/version'

Gem::Specification.new do |spec|
  spec.name          = 'odysseus-cli'
  spec.version       = Odysseus::CLI::VERSION
  spec.authors       = ['Thomas']
  spec.email         = ['thomas@imfiny.com']
  spec.summary       = 'CLI for Odysseus deployment tool'
  spec.description   = 'Command-line interface for deploying with Odysseus'
  spec.homepage      = 'https://github.com/WA-Systems-EU/odysseus'
  spec.license       = 'MIT'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri']   = "#{spec.homepage}/blob/trunk/odysseus-cli/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files         = Dir['lib/**/*', 'bin/*', 'README.md', 'LICENSE.txt', 'CHANGELOG.md']
  spec.executables   = ['odysseus']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.2.0'

  # Lockstep with core: the CLI relies on the deploy behaviour released in 0.4.0.
  spec.add_dependency 'odysseus-core', '~> 0.5.0'
end
