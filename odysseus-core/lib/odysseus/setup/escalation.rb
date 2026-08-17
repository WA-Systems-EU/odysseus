# lib/odysseus/setup/escalation.rb

module Odysseus
  module Setup
    # How `odysseus setup` gets root on the host it is preparing.
    #
    # The bootstrap identity is named by --as and defaults to `ubuntu`, so
    # needing sudo is the common path rather than the exception: Ubuntu's LTS
    # cloud images ship that user with passwordless sudo already configured.
    # A root bootstrap must not touch sudo at all — minimal images often do not
    # have it installed.
    #
    # The probe exists because a sudo password prompt cannot be answered:
    # Net::SSH runs with non_interactive: true, so a prompt hangs and then
    # fails with nothing useful said. Asking up front turns that into one
    # sentence before anything has been changed.
    class Escalation
      ROOT = 'root'.freeze

      # @param ssh [Odysseus::Deployer::SSH] connection as the bootstrap identity
      # @param as [String] that identity's username
      def initialize(ssh:, as:)
        @ssh = ssh
        @as = as
      end

      # @return [Boolean] whether commands need a sudo prefix
      def sudo?
        @as != ROOT
      end

      # @raise [Odysseus::SetupError] when escalation is not available
      def probe!
        return unless sudo?

        @ssh.execute('sudo -n true')
      rescue Odysseus::Error => e
        raise Odysseus::SetupError,
              "#{@as} cannot escalate with passwordless sudo, which odysseus setup requires: " \
              "#{e.message.lines.first.to_s.strip}. Odysseus cannot answer a password prompt. " \
              'Use --as root on a host where root can log in, or give this user NOPASSWD sudo.'
      end

      # @param command [String] a command that needs root
      # @return [String] its output
      def run(command)
        @ssh.execute(sudo? ? "sudo -n #{command}" : command)
      end
    end
  end
end
