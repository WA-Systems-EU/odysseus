# lib/odysseus/git.rb

require 'open3'

module Odysseus
  # Answers questions about a local git work tree. Knows nothing about deploys:
  # the rules that turn these answers into a version live in VersionResolver.
  class Git
    # @param dir [String] directory inside the work tree
    def initialize(dir)
      @dir = dir
    end

    # @return [Boolean] true when dir is inside a git work tree
    def repository?
      _, status = capture('rev-parse', '--git-dir')
      status.success?
    end

    # @param length [Integer] characters of the object name to return
    # @return [String, nil] abbreviated commit sha of HEAD
    def head_sha(length: 12)
      out, status = capture('rev-parse', "--short=#{length}", 'HEAD')
      status.success? ? out : nil
    end

    # Tracked modifications only. Untracked files are reported separately: they
    # are usually local noise, and blocking on them would make deploys hostile.
    # @return [Boolean]
    def uncommitted_changes?
      out, status = capture('status', '--porcelain', '--untracked-files=no')
      status.success? && !out.empty?
    end

    # @return [Boolean] true when the work tree has files git is not tracking
    def untracked_files?
      out, status = capture('ls-files', '--others', '--exclude-standard')
      status.success? && !out.empty?
    end

    # @return [String, nil] branch name, or 'HEAD' when detached
    def ref
      out, status = capture('rev-parse', '--abbrev-ref', 'HEAD')
      status.success? ? out : nil
    end

    # @return [String, nil] user.email as git resolves it for this repository
    def committer_email
      out, status = capture('config', 'user.email')
      status.success? && !out.empty? ? out : nil
    end

    private

    def capture(*)
      stdout, _stderr, status = Open3.capture3('git', *, chdir: @dir)
      [stdout.strip, status]
    rescue Errno::ENOENT
      # git is not installed; treat as "not a repository" rather than crashing.
      ['', FailedStatus.new]
    end

    # Stands in for a Process::Status when git could not be executed at all.
    class FailedStatus
      def success?
        false
      end
    end
  end
end
