Gem::Specification.new do |spec|
  spec.name          = "odysseus-cli"
  spec.version       = "0.2.0"
  spec.authors       = ["Your Name"]
  spec.email         = ["your@email.com"]
  spec.summary       = "CLI for Odysseus deployment tool"
  spec.description   = "Command-line interface for deploying with Odysseus"
  spec.homepage      = "https://github.com/WaSystems/odysseus"
  spec.license       = "LGPL-3.0-only"

  spec.files         = Dir["lib/**/*", "bin/*", "README.md", "LICENSE"]
  spec.executables   = ["odysseus"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0"

  spec.add_dependency "odysseus-core", "~> 0.2"
  spec.add_dependency "pastel", "~> 0.8"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "pry-byebug", "~> 3.10"
end
