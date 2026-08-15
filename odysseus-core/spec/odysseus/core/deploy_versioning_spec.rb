# spec/odysseus/core/deploy_versioning_spec.rb
#
# Exercised through a minimal host class rather than an orchestrator: the module
# is the contract every orchestrator shares, including sail-provided ones in
# other gems, so it is tested independently of any one of them.

require 'spec_helper'

RSpec.describe Odysseus::Core::DeployVersioning do
  # The helpers are private, so the host stands in for the run_container method
  # a real orchestrator calls them from. Reaching past the visibility with
  # `send` would exercise a call no includer makes, and would keep passing if
  # the mixin started publishing its internals.
  let(:host_class) do
    Class.new do
      include Odysseus::Core::DeployVersioning

      def initialize(config)
        @config = config
      end

      def run_options(image)
        { version: deploy_version_tag(image), labels: version_labels }
      end
    end
  end

  def with(deploy_version)
    host_class.new(deploy_version.nil? ? {} : { deploy_version: deploy_version })
  end

  def tag_for(deploy_version, image)
    with(deploy_version).run_options(image)[:version]
  end

  def labels_for(deploy_version)
    with(deploy_version).run_options('myapp:v1')[:labels]
  end

  let(:resolved) do
    Odysseus::DeployVersion.new(version: 'abc123def456', ref: 'main', deployer: 'dev@example.com')
  end

  describe '#deploy_version_tag' do
    it 'is the resolved version when the deploy has one' do
      expect(tag_for(resolved, 'myapp:ignored')).to eq('abc123def456')
    end

    # A caller passing --image still gets a self-describing container name.
    it 'falls back to the tag in the image reference' do
      expect(tag_for(nil, 'myapp-production:v9')).to eq('v9')
    end

    it 'handles an image reference carrying a registry port' do
      expect(tag_for(nil, 'registry.example.com:5000/myapp:v9')).to eq('v9')
    end
  end

  describe '#version_labels' do
    it 'always stamps the deploy time in UTC ISO 8601' do
      expect(labels_for(nil)['odysseus.deployed_at'])
        .to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it 'records the git ref when the version came from a commit' do
      expect(labels_for(resolved)['odysseus.git_ref']).to eq('main')
    end

    # An explicit --image says nothing about a commit, so claiming one would lie.
    it 'omits the git ref when there is no resolved version' do
      expect(labels_for(nil)).not_to have_key('odysseus.git_ref')
    end

    it 'omits the git ref when the resolved version has none' do
      tagless = Odysseus::DeployVersion.new(version: 'v9', ref: nil, deployer: 'dev@example.com')

      expect(labels_for(tagless)).not_to have_key('odysseus.git_ref')
    end
  end

  # Both were private in WebDeploy and JobDeploy before the extraction; sharing
  # the code should not have widened either orchestrator's public surface.
  describe 'visibility' do
    it 'keeps deploy_version_tag off the includer public API' do
      expect(with(nil)).not_to respond_to(:deploy_version_tag)
    end

    it 'keeps version_labels off the includer public API' do
      expect(with(nil)).not_to respond_to(:version_labels)
    end
  end
end
