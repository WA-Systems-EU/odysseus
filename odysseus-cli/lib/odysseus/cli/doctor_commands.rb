# odysseus-cli/lib/odysseus/cli/doctor_commands.rb
#
# `odysseus doctor`.
# Split out of CLI so the command surface for it lives together and CLI
# itself stays under the project's class-length budget.

module Odysseus
  module CLI
    module DoctorCommands
      # Read-only diagnosis of every host in the config, as the user the config
      # names. Its own command rather than a mode of `setup`, because it lasts:
      # "is this host usable by odysseus as my deploy user" is worth asking on
      # any host, including one a provisioning tool built.
      def doctor(options = {})
        config_file = options[:config] || 'deploy.yml'
        config = load_config(config_file)

        @ui.header 'Odysseus Doctor'
        @ui.info 'Service', config[:service]
        @ui.info 'Deploy user', config[:ssh][:user]
        @ui.blank

        worst = :ok

        executor = Odysseus::Deployer::Executor.new(config_file)

        executor.host_roles.each_key do |host|
          @ui.section host
          ssh = connect_to_server(host, config)

          begin
            Odysseus::HostVerifier.new(ssh: ssh, config: config).verify.each do |result|
              worst = escalate(worst, result.status)
              render_check(result)
            end
          rescue StandardError => e
            # A check failing is a Result with status: :fail, produced by
            # HostVerifier without raising. This rescues something else: the
            # connection itself dying mid-survey. A drop there can surface as
            # IOError, Net::SSH::Disconnect (a RuntimeError) or
            # Errno::EPIPE/ECONNRESET (a SystemCallError) — three branches of
            # StandardError with no narrower ancestor in common, so nothing
            # tighter than StandardError could catch all of them in one
            # rescue. A narrower rescue would also reintroduce the defect
            # this exists to fix: one host's failure aborting the survey for
            # everyone after it. The risk of that width is masking a genuine
            # HostVerifier bug as "host unreachable"; naming the exception's
            # own class and message in the detail is what keeps a
            # NoMethodError legible as a bug rather than indistinguishable
            # from a dropped connection.
            worst = escalate(worst, :fail)
            render_check(
              Odysseus::HostVerifier::Result.new(
                check: :reachable, status: :fail, detail: "#{host}: #{e.class}: #{e.message}"
              )
            )
          ensure
            ssh.close
          end
        end

        @ui.blank
        case worst
        when :fail then exit 1
        when :warn then @ui.warn 'Deploys will work, but read the warnings above.'
        else @ui.success 'This host is ready.'
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      private

      def render_check(result)
        line = "#{result.check}: #{result.detail}"

        case result.status
        when :ok then @ui.step_ok line
        when :warn then @ui.warn line
        else @ui.step_fail line
        end
      end

      # :fail beats :warn beats :ok, so one bad check decides the exit code
      # however many good ones surround it.
      def escalate(current, status)
        order = { ok: 0, warn: 1, fail: 2 }
        order[status] > order[current] ? status : current
      end
    end
  end
end
