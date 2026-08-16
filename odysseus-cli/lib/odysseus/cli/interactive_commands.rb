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

        remote = remote_command(['docker', 'run', '-it', '--rm', '--network', 'odysseus',
                                 *env_args(config), image, '/bin/sh'])
        run_interactive!(ssh_command(config, server, remote))
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

        remote = remote_command(['docker', 'run', '-it', '--rm', '--network', 'odysseus',
                                 *env_args(config), image, *console_words(console_cmd)])
        run_interactive!(ssh_command(config, server, remote))
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

      # Layer 2, the REMOTE shell: ssh hands this string to the login shell on
      # the host, which splits it into words. Escaping here is what keeps an
      # env value with a space in it one argument, instead of docker reading
      # the second half of it as the image name.
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

      # env.clear as docker flags. The -e KEY=VALUE mechanism is unchanged; the
      # values are simply no longer interpolated raw. Secrets do not belong on
      # a command line and are not put there — that is a separate change.
      def env_args(config)
        (config[:env][:clear] || {}).flat_map { |k, v| ['-e', "#{k}=#{v}"] }
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
