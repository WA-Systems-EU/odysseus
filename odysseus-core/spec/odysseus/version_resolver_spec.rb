# spec/odysseus/version_resolver_spec.rb

require 'spec_helper'
require 'tmpdir'

RSpec.describe Odysseus::VersionResolver do
  let(:git) { instance_double(Odysseus::Git) }
  let(:warnings) { [] }
  let(:logger) do
    collected = warnings
    Object.new.tap do |l|
      l.define_singleton_method(:info) { |_msg| nil }
      l.define_singleton_method(:warn) { |msg| collected << msg }
    end
  end

  subject(:resolver) { described_class.new(config_dir: '/app', logger: logger) }

  before { allow(Odysseus::Git).to receive(:new).with('/app').and_return(git) }

  context 'with an explicit image tag' do
    before { allow(git).to receive(:committer_email).and_return('dev@example.com') }

    it 'uses it without asking git about the repository' do
      expect(git).not_to receive(:repository?)
      expect(git).not_to receive(:uncommitted_changes?)
      expect(git).not_to receive(:head_sha)

      resolved = resolver.resolve(image_tag: 'v1.2.3')

      expect(resolved.version).to eq('v1.2.3')
    end

    it 'still reports no ref, but names the deployer' do
      resolved = resolver.resolve(image_tag: 'v1.2.3')

      expect(resolved.ref).to be_nil
      expect(resolved.deployer).to eq('dev@example.com')
    end

    it 'falls back to $USER when git has no committer email, same as any other resolve' do
      allow(git).to receive(:committer_email).and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('USER', 'unknown').and_return('thomas')

      expect(resolver.resolve(image_tag: 'v1.2.3').deployer).to eq('thomas')
    end
  end

  context 'with an explicit image tag and no git repository at all' do
    # Uses a real, uninitialised temp directory and a real Odysseus::Git
    # rather than the double the rest of this file uses, so this proves the
    # $USER fallback answers even when there is no git repository to stub.
    before { allow(Odysseus::Git).to receive(:new).and_call_original }

    around do |example|
      Dir.mktmpdir do |not_a_repo|
        Dir.mktmpdir do |fake_home|
          original_home = Dir.home
          ENV['HOME'] = fake_home
          begin
            @dir = not_a_repo
            example.run
          ensure
            ENV['HOME'] = original_home
          end
        end
      end
    end

    subject(:resolver) { described_class.new(config_dir: @dir) }

    it 'still names a deployer, proving the $USER fallback answers without git' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('USER', 'unknown').and_return('pat')

      resolved = resolver.resolve(image_tag: 'v1.2.3')

      expect(resolved.version).to eq('v1.2.3')
      expect(resolved.ref).to be_nil
      expect(resolved.deployer).to eq('pat')
    end
  end

  context 'in a clean repository' do
    before do
      allow(git).to receive(:repository?).and_return(true)
      allow(git).to receive(:uncommitted_changes?).and_return(false)
      allow(git).to receive(:untracked_files?).and_return(false)
      allow(git).to receive(:head_sha).and_return('abc123def456')
      allow(git).to receive(:ref).and_return('main')
      allow(git).to receive(:committer_email).and_return('dev@example.com')
    end

    it 'resolves the version from HEAD' do
      expect(resolver.resolve.version).to eq('abc123def456')
    end

    it 'carries the ref and the deployer' do
      resolved = resolver.resolve

      expect(resolved.ref).to eq('main')
      expect(resolved.deployer).to eq('dev@example.com')
    end

    it 'falls back to $USER when git has no committer email' do
      allow(git).to receive(:committer_email).and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('USER', 'unknown').and_return('thomas')

      expect(resolver.resolve.deployer).to eq('thomas')
    end

    it 'warns about untracked files without aborting' do
      allow(git).to receive(:untracked_files?).and_return(true)

      expect(resolver.resolve.version).to eq('abc123def456')
      expect(warnings.join).to match(/untracked/i)
    end
  end

  context 'in a dirty repository' do
    before do
      allow(git).to receive(:repository?).and_return(true)
      allow(git).to receive(:uncommitted_changes?).and_return(true)
      allow(git).to receive(:committer_email).and_return('dev@example.com')
    end

    it 'refuses to resolve a version' do
      expect { resolver.resolve }
        .to raise_error(Odysseus::ConfigError, /uncommitted changes/i)
    end

    it 'names --image as the way through' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError, /--image/)
    end

    it 'still honours an explicit tag' do
      expect(resolver.resolve(image_tag: 'hotfix').version).to eq('hotfix')
    end
  end

  context 'in a repository with no commits' do
    before do
      allow(git).to receive(:repository?).and_return(true)
      allow(git).to receive(:uncommitted_changes?).and_return(false)
      allow(git).to receive(:head_sha).and_return(nil)
    end

    it 'refuses rather than building an empty version' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError, /no commits yet/i)
    end

    it 'names --image as the way through' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError, /--image/)
    end
  end

  context 'outside a repository' do
    before { allow(git).to receive(:repository?).and_return(false) }

    it 'refuses, naming the directory and --image' do
      expect { resolver.resolve }.to raise_error(Odysseus::ConfigError) { |error|
        expect(error.message).to include('/app')
        expect(error.message).to include('--image')
      }
    end
  end
end
