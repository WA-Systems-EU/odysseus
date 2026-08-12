# spec/spec_helper.rb

require 'rspec'
require 'open3'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'odysseus'
require 'odysseus/cli/cli'
require 'odysseus/cli/version'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

CLI_ROOT = File.expand_path('..', __dir__)

def fixture_path(name)
  File.expand_path("fixtures/#{name}", __dir__)
end

# Run the real executable the way a user does, so argument dispatch, usage text
# and exit codes are covered without loading bin/odysseus into this process.
#
# @return [Array(String, String, Process::Status)] stdout, stderr, status
def run_cli(*)
  Open3.capture3(
    RbConfig.ruby, '-I', File.join(CLI_ROOT, 'lib'), File.join(CLI_ROOT, 'bin', 'odysseus'), *,
    chdir: CLI_ROOT
  )
end
