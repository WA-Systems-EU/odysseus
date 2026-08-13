# spec/odysseus/core/deploy_versioning_spec.rb
#
# Exercised through a minimal host class rather than an orchestrator: the module
# is the contract every orchestrator shares, including sail-provided ones in
# other gems, so it is tested independently of any one of them.

require 'spec_helper'

RSpec.describe Odysseus::Core::DeployVersioning do
  let(:host_class) do
    Class.new do
      include Odysseus::Core::DeployVersioning

      def initialize(config)
        @config = config
      end
    end
  end

  def with(deploy_version)
    host_class.new(deploy_version.nil? ? {} : { deploy_version: deploy_version })
  end

  let(:resolved) do
    Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
  end

  describe '#deploy_version_tag' do
    it 'is the resolved version when the deploy has one' do
      expect(with(resolved).deploy_version_tag('myapp:ignored')).to eq('abc123def456')
    end

    # A caller passing --image still gets a self-describing container name.
    it 'falls back to the tag in the image reference' do
      expect(with(nil).deploy_version_tag('myapp-production:v9')).to eq('v9')
    end

    it 'handles an image reference carrying a registry port' do
      expect(with(nil).deploy_version_tag('registry.example.com:5000/myapp:v9')).to eq('v9')
    end
  end

  describe '#version_labels' do
    it 'always stamps the deploy time in UTC ISO 8601' do
      expect(with(nil).version_labels['odysseus.deployed_at'])
        .to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'records the git ref when the version came from a commit' do
      expect(with(resolved).version_labels['odysseus.git_ref']).to eq('main')
    end

    # An explicit --image says nothing about a commit, so claiming one would lie.
    it 'omits the git ref when there is no resolved version' do
      expect(with(nil).version_labels).not_to have_key('odysseus.git_ref')
    end

    it 'omits the git ref when the resolved version has none' do
      tagless = Odysseus::DeployVersion.new(version: 'v9', ref: nil, deployer: 'dev@example.com')

      expect(with(tagless).version_labels).not_to have_key('odysseus.git_ref')
    end
  end
end
