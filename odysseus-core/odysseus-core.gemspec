# frozen_string_literal: true

require_relative 'lib/odysseus/core/version'

Gem::Specification.new do |spec|
  spec.name = 'odysseus-core'
  spec.version = Odysseus::Core::VERSION
  spec.authors = ['Thomas']
  spec.email = ['thomas@imfiny.com']

  spec.summary = 'Core library for Odysseus deployment tool'
  spec.description = 'Core library providing configuration parsing, deployers, and orchestrators for Odysseus'
  spec.homepage = 'https://github.com/WA-Systems-EU/odysseus'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/WA-Systems-EU/odysseus'
  spec.metadata['changelog_uri'] = 'https://github.com/WA-Systems-EU/odysseus/blob/trunk/odysseus-core/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .rubocop.yml])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'base64'  # Required in Ruby 3.4+
  spec.add_dependency 'logger'  # Required in Ruby 4.0+
  spec.add_dependency 'net-scp', '~> 4.0'
  spec.add_dependency 'net-ssh', '~> 7.2'
  spec.add_dependency 'zeitwerk', '~> 2.6'
end
