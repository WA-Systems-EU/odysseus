# odysseus-cli/lib/odysseus/cli/setup_commands.rb
#
# `odysseus setup`.
# Split out of CLI for the same reason as DoctorCommands: cli.rb is close to
# its Metrics/ClassLength budget.

module Odysseus
  module CLI
    module SetupCommands
      # The Ubuntu cloud image's own default user, so a stock image works
      # untouched by the time --as would otherwise be needed.
      DEFAULT_IDENTITY = 'ubuntu'.freeze

      # Prepares every host in the config so odysseus can deploy to it as a
      # non-root user: creates the deploy user, its group, its
      # authorized_keys and its state dir. Its own command rather than a mode
      # of `doctor`, because doctor only reads; this one changes the host.
      #
      # Connects as the bootstrap identity (--as, default 'ubuntu') rather
      # than config[:ssh][:user] -- that deploy user existing is the point of
      # this command, so it cannot be assumed to exist yet, let alone be
      # reachable, before setup has run.
      #
      # The public key to install is resolved once, before any host is
      # touched -- before even the first connection opens. A created user
      # with no way to log in is the worst outcome this command has, and
      # resolving first means that failure can never happen after host 1 of
      # 3 is already changed: the whole run refuses, or none of it does.
      def setup(options = {})
        config_file = options[:config] || 'deploy.yml'
        config = load_config(config_file)
        identity = options[:as] || DEFAULT_IDENTITY

        refuse_root_deploy_user!(config)
        keys = Odysseus::Setup::PublicKey.resolve(keys: config[:ssh][:keys], explicit: Array(options[:key]))

        @ui.header 'Odysseus Setup'
        @ui.info 'Service', config[:service]
        @ui.info 'Bootstrap identity', identity
        @ui.blank

        worst = :ok
        executor = Odysseus::Deployer::Executor.new(config_file)

        executor.host_roles.each_key do |host|
          @ui.section host
          ssh = connect_as(identity, host, config)

          begin
            escalation = Odysseus::Setup::Escalation.new(ssh: ssh, as: identity)
            preparer = Odysseus::Setup::Preparer.new(ssh: ssh, config: config, escalation: escalation, keys: keys)

            preparer.prepare.each do |result|
              worst = escalate(worst, result.status)
              render_result(result)
            end
          rescue StandardError => e
            # Mirrors DoctorCommands#doctor's rescue: a step failing is a
            # Result with status: :fail, produced by Preparer without
            # raising. This rescues the connection itself dying mid-run,
            # which can surface as IOError, Net::SSH::Disconnect (a
            # RuntimeError) or Errno::EPIPE/ECONNRESET (a SystemCallError) --
            # three branches of StandardError with no narrower ancestor in
            # common. Narrower would also reintroduce the defect this fixes:
            # one host's failure aborting setup for every host after it.
            worst = escalate(worst, :fail)
            render_result(
              Odysseus::Setup::Preparer::Result.new(
                step: :connection, status: :fail, detail: "#{host}: #{e.class}: #{e.message}"
              )
            )
          ensure
            ssh.close
          end
        end

        @ui.blank
        case worst
        when :fail then exit 1
        when :warn then @ui.warn 'Setup finished, but read the warnings above.'
        else @ui.success 'Hosts are ready.'
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      private

      # `ssh.user: root` is not a case setup half-supports -- it is refused
      # by name, before the key is even resolved. Deploying as root already
      # works today with no setup at all (root needs no user, no group, no
      # authorized_keys of its own), so every step setup would otherwise run
      # is either a no-op mistaken for progress or, worse, a mutation of
      # root's own account (`usermod -aG docker root`) that the command's
      # "it never modifies root's configuration" promise forbids outright.
      # Refusing here, rather than growing setup a root-flavoured code path,
      # is the point: this command's job ends at getting one non-root user
      # ready, not at supporting every identity a deploy could use.
      #
      # `ssh.user` (the identity being created) and `--as` (the bootstrap
      # identity connected as, which defaults to ubuntu and may legitimately
      # be root) name different things; only the former is refused here.
      def refuse_root_deploy_user!(config)
        return unless config[:ssh][:user] == 'root'

        raise Odysseus::SetupError,
              '`ssh.user` is `root`: setup exists to enable non-root deploys, root needs no ' \
              'preparation, and deploying as root already works with no setup at all. Change ' \
              '`ssh.user` in deploy.yml to the non-root user you want to deploy as.'
      end

      # :changed renders distinctly from :ok (step_info's copper arrow, not
      # step_ok's mint check) so a re-run visibly reports what it did versus
      # what was already correct -- the point of running it twice.
      def render_result(result)
        line = "#{result.step}: #{result.detail}"

        case result.status
        when :ok then @ui.step_ok line
        when :changed then @ui.step_info line
        when :warn then @ui.warn line
        else @ui.step_fail line
        end
      end

      # :fail beats :warn beats :ok/:changed, so one bad step decides the
      # exit code however many good ones surround it. :changed ranks with
      # :ok, not above it: it is still a step that finished cleanly, and only
      # a :fail may set a non-zero exit.
      def escalate(current, status)
        order = { ok: 0, changed: 0, warn: 1, fail: 2 }
        order[status] > order[current] ? status : current
      end

      # setup's connections differ from connect_to_server's in two ways at
      # once: the identity (the bootstrap --as, not config[:ssh][:user] --
      # see #setup) and use_tailscale. Both are setup's alone among the
      # eleven callers of connect_to_server, so this stays a private helper
      # here rather than a second keyword grafted onto a method every other
      # command already uses correctly.
      #
      # use_tailscale: false because connect_to_server's hardcoded true
      # (cli.rb) makes SSH append Tailscale troubleshooting advice to every
      # connection timeout (deployer/ssh.rb). setup targets exactly the
      # fresh hosts that do not have Tailscale yet, so on the one command
      # where a timeout is most likely, that advice would be actively
      # misleading.
      def connect_as(identity, host, config)
        Odysseus::Deployer::SSH.new(
          host: host,
          user: identity,
          keys: config[:ssh][:keys],
          use_tailscale: false
        )
      end
    end
  end
end
