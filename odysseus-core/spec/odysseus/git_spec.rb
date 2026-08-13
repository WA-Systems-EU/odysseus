# spec/odysseus/git_spec.rb

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

RSpec.describe Odysseus::Git do
  # Build a real repository. Config is set locally so a developer's global
  # config cannot change the outcome.
  def make_repo(dir)
    Open3.capture3('git', 'init', '--initial-branch=main', chdir: dir)
    Open3.capture3('git', 'config', 'user.email', 'dev@example.com', chdir: dir)
    Open3.capture3('git', 'config', 'user.name', 'Dev', chdir: dir)
    File.write(File.join(dir, 'app.rb'), "puts 'v1'\n")
    Open3.capture3('git', 'add', '.', chdir: dir)
    Open3.capture3('git', 'commit', '-m', 'first', chdir: dir)
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  subject(:git) { described_class.new(@dir) }

  context 'in a git work tree' do
    before { make_repo(@dir) }

    it 'reports that it is a repository' do
      expect(git.repository?).to be true
    end

    it 'returns a 12 character head sha' do
      expect(git.head_sha).to match(/\A[0-9a-f]{12}\z/)
    end

    it 'returns the branch name' do
      expect(git.ref).to eq('main')
    end

    it 'returns the committer email from the repository config' do
      expect(git.committer_email).to eq('dev@example.com')
    end

    it 'is clean' do
      expect(git.uncommitted_changes?).to be false
      expect(git.untracked_files?).to be false
    end

    it 'reports a modified tracked file as uncommitted' do
      File.write(File.join(@dir, 'app.rb'), "puts 'v2'\n")

      expect(git.uncommitted_changes?).to be true
    end

    it 'does not treat an untracked file as uncommitted' do
      File.write(File.join(@dir, 'scratch.txt'), 'notes')

      expect(git.uncommitted_changes?).to be false
      expect(git.untracked_files?).to be true
    end

    it 'reports HEAD as the ref when detached' do
      sha = git.head_sha(length: 40)
      Open3.capture3('git', 'checkout', sha, chdir: @dir)

      expect(git.ref).to eq('HEAD')
    end
  end

  context 'outside a git work tree' do
    it 'reports that it is not a repository' do
      expect(git.repository?).to be false
    end
  end

  # git can exit 0 with empty stdout (e.g. HEAD in a repository state neither
  # method is documented to handle). VersionResolver's nil-guard exists
  # specifically to stop a DeployVersion with an empty version, and an empty
  # string would walk straight past `unless sha`/`unless git.repository?`
  # style guards, so blank output must normalise to nil like committer_email
  # already does.
  context 'when git exits 0 with empty output' do
    let(:success) { instance_double(Process::Status, success?: true) }

    before do
      allow(Open3).to receive(:capture3).and_return(['', '', success])
    end

    it 'treats a blank head_sha as absent rather than an empty string' do
      expect(git.head_sha).to be_nil
    end

    it 'treats a blank ref as absent rather than an empty string' do
      expect(git.ref).to be_nil
    end
  end
end
