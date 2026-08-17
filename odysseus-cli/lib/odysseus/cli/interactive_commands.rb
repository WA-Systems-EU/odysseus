# odysseus-cli/lib/odysseus/cli/interactive_commands.rb
#
# `odysseus app shell`, `odysseus app console` and `odysseus dependency shell`.
# These three are the commands that hand a terminal over: they build an ssh
# command line and run it locally rather than going through the Docker client,
# because the session needs the caller's own tty. Split out of CLI so they live
# together and CLI itself stays under the project's class-length budget.
#
# Two shells stand between this file and the container, and each needs its own
# quoting. Escaping for one and not the other is how these commands came to
# break on an env value with a space in it.
#
# Those env values are no longer in the string at all — they go in an env file
# on the host, and only its path is named here — but the console command, the
# image and the SSH key paths still are, so both layers still matter.

require 'shellwords'

module Odysseus
  module CLI
    module InteractiveCommands
      # App shell
      def app_shell(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        role = (options[:role] || 'web').to_sym
        config = load_config(config_file)
        image = running_image(server, config, role)
        session_header('App Shell', server: server, role: role, image: image, command: '/bin/sh')

        with_container_env(server, config, config_file) do |env_file|
          remote = remote_command(['docker', 'run', '-it', '--rm', '--network', 'odysseus',
                                   *env_file_args(env_file), image, '/bin/sh'])
          run_interactive!(ssh_command(config, server, remote))
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # App console
      def app_console(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        role = (options[:role] || 'web').to_sym
        console_cmd = options[:cmd] || '/bin/sh'
        config = load_config(config_file)
        image = running_image(server, config, role)
        # Read before the env file is written: a --cmd that cannot be parsed is
        # not worth putting a file of secrets on the host for.
        words = console_words(console_cmd)
        session_header('App Console', server: server, role: role, image: image, command: console_cmd)

        with_container_env(server, config, config_file) do |env_file|
          remote = remote_command(['docker', 'run', '-it', '--rm', '--network', 'odysseus',
                                   *env_file_args(env_file), image, *words])
          run_interactive!(ssh_command(config, server, remote))
        end
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      # Dependency shell
      def dependency_shell(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        name = require_name!(options)

        config = load_config(config_file)
        service_name = "#{config[:service]}-#{name}"

        ssh = connect_to_server(server, config)
        begin
          docker = Odysseus::Docker::Client.new(ssh)
          containers = docker.list(service: service_name)

          if containers.empty?
            @ui.error "No running containers found for #{service_name}"
            exit 1
          end

          container_id = containers.first['ID']
        ensure
          ssh.close
        end

        remote = remote_command(['docker', 'exec', '-it', container_id, '/bin/sh'])
        run_interactive!(ssh_command(config, server, remote))
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end

      private

      # What these two print before the terminal goes away. `app shell web1`
      # used to print nothing at all: the first thing you saw was `/app $`, from
      # which the host, the role and the build serving it are all unreadable.
      #
      # The last line is the one worth the space. These commands `docker run` a
      # new container from the image that is serving, not `docker exec` into the
      # container taking traffic, and a shell prompt inside a container invites
      # exactly the opposite assumption — that a file written or a process
      # killed here lands on the running app. It does neither, and the container
      # goes when the session does.
      #
      # It all goes to stderr. The session's own stdout is the caller's:
      # `app console --cmd "rails runner 'puts Thing.count'" > count` is a
      # reasonable way to read a value out of a deployment, and a header in that
      # file would be a bug. Diagnostics go where diagnostics go.
      def session_header(title, server:, role:, image:, command:)
        @ui.header title, io: $stderr
        @ui.info 'Server', server, io: $stderr
        @ui.info 'Role', role, io: $stderr
        @ui.info 'Image', image, io: $stderr
        @ui.info 'Command', command, io: $stderr
        @ui.step 'New container from that image: the running app is untouched, and this one is discarded on exit.',
                 io: $stderr
        @ui.blank io: $stderr
      end

      # Layer 2, the REMOTE shell: ssh hands this string to the login shell on
      # the host, which splits it into words. Escaping here is what keeps an
      # argument containing a space — `--cmd "rails runner 'puts 1'"`, say —
      # one argument, instead of docker reading part of it as the image name.
      def remote_command(words)
        Shellwords.join(words)
      end

      # Layer 1, the LOCAL shell: `system` with a single string runs it through
      # /bin/sh here. Every word is escaped for that shell, `remote` included —
      # it has to survive as one word, or the local shell takes what is inside
      # it as commands of its own.
      def ssh_command(config, server, remote)
        keys = config[:ssh][:keys].flat_map { |k| ['-i', File.expand_path(k)] }
        Shellwords.join(['ssh', *keys, '-t', "#{config[:ssh][:user]}@#{server}", remote])
      end

      # Holds the container's environment — env.clear and env.secret both, the
      # same as a deploy injects — in a 0600 file on the host for as long as the
      # session lasts, and yields its path. Docker::Client owns the file: where
      # it lives, how it is permissioned and when it goes away.
      #
      # These values used to be `-e KEY=VALUE` in the command string, which is
      # where `ps` on the deploy target reads them from. Nothing but a path goes
      # there now, so a DATABASE_URL is no longer legible to every user on the
      # box for the length of the session.
      #
      # The file is removed when the block ends, however it ends: a session that
      # exits non-zero, an ssh that never connected, and Ctrl-C all pass back
      # through with_env_file's ensure. What that cannot cover is this process
      # being killed outright (SIGKILL, or the machine going down): no ensure
      # runs, so the file stays until something else removes it. It is mode 0600
      # inside that connection's env directory (HostPaths#env_dir —
      # /var/lib/odysseus/env for root, $HOME/.odysseus/env otherwise), which
      # write_env_file chmods to 0700 for every connection, so no other user on
      # the host can read it — but it is a file of secrets that nobody is
      # coming back for: the next deploy or one-off run writes its own rather
      # than tidying this one.
      def with_container_env(server, config, config_file, &)
        ssh = connect_to_server(server, config)

        begin
          docker = Odysseus::Docker::Client.new(ssh)
          docker.with_env_file(build_environment(config, config_file, ssh), &)
        ensure
          ssh.close
        end
      end

      # with_env_file yields nil when there is no environment to write, so a
      # config with no env at all does not get a flag pointing at nothing.
      def env_file_args(env_file)
        env_file ? ['--env-file', env_file] : []
      end

      # --cmd is a command line ("rails c"), so split it into words the way a
      # shell would before each is escaped: escaping it whole would ask docker
      # to exec a program literally named "rails c". Quoting the caller got
      # wrong is reported rather than passed on as a command that cannot parse.
      def console_words(console_cmd)
        Shellwords.split(console_cmd)
      rescue ArgumentError => e
        @ui.error "Could not read --cmd #{console_cmd.inspect}: #{e.message}"
        exit 1
      end

      # `system` returns false when the command exits non-zero and nil when it
      # could not be run at all; both were discarded here, so a refused ssh, a
      # missing image and a failed docker run all reported success. ssh exits
      # with the remote command's own status, so pass that on when we have it.
      def run_interactive!(command)
        return if system(command)

        status = $?&.exitstatus
        exit(status.nil? || status.zero? ? 1 : status)
      end
    end
  end
end
