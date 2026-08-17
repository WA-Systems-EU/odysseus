# lib/odysseus/version_resolver.rb

module Odysseus
  # Turns an optional --image tag plus the state of the work tree into the
  # version a deploy will use. The rules live here rather than in Executor so
  # they can be tested without a config file or an SSH connection.
  class VersionResolver
    SHA_LENGTH = 12

    # @param config_dir [String] directory holding deploy.yml
    # @param logger [Object, nil] responds to #info and #warn
    def initialize(config_dir:, logger: nil)
      @config_dir = config_dir
      @logger = logger
    end

    # @param image_tag [String, nil] explicit tag; wins over git when given
    # @return [DeployVersion]
    # @raise [Odysseus::ConfigError] when no version can be established
    def resolve(image_tag: nil)
      # ref stays nil here: an arbitrary explicit tag has no commit it honestly
      # identifies, and recording HEAD would assert a link that may not exist.
      # (The no-tag path below refuses on uncommitted changes for exactly this
      # reason — so that when it does record a ref, the tag actually identifies
      # the code.) deployer is available regardless, so there is no such reason
      # to withhold it.
      return DeployVersion.new(version: image_tag, ref: nil, deployer: deployer) if image_tag

      unless git.repository?
        raise Odysseus::ConfigError,
              "#{@config_dir} is not a git repository, so the version cannot be taken from a " \
              'commit. Pass --image to name the version explicitly.'
      end

      if git.uncommitted_changes?
        raise Odysseus::ConfigError,
              'The working tree has uncommitted changes, so the image tag would not identify ' \
              'the code being deployed. Commit them, or pass --image to name the version.'
      end

      sha = git.head_sha(length: SHA_LENGTH)

      unless sha
        raise Odysseus::ConfigError,
              "#{@config_dir} is a git repository with no commits yet, so there is no version to " \
              'deploy. Commit first, or pass --image to name the version.'
      end

      warn_about_untracked_files

      DeployVersion.new(version: sha, ref: git.ref, deployer: deployer)
    end

    # Who is running this command: git's configured email, falling back to the
    # shell user. Works outside a repository — `git config user.email` reads
    # global config — so a rollback can name a deployer even when the version
    # came from a host rather than a commit.
    #
    # @return [String]
    def deployer
      git.committer_email || ENV.fetch('USER', 'unknown')
    end

    private

    def git
      @git ||= Odysseus::Git.new(@config_dir)
    end

    # The build context includes untracked files unless .dockerignore excludes
    # them, so they can change the image while the tag stays the same. Worth
    # saying out loud; not worth refusing over.
    def warn_about_untracked_files
      return unless git.untracked_files?
      return unless @logger.respond_to?(:warn)

      @logger.warn('Working tree has untracked files; they may enter the image without changing its tag')
    end
  end
end
