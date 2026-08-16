# odysseus-cli/lib/odysseus/cli/interactive_commands.rb
#
# `odysseus app shell`, `odysseus app console` and `odysseus dependency shell`.
# These three are the commands that hand a terminal over: they build an ssh
# command line and run it locally rather than going through the Docker client,
# because the session needs the caller's own tty. Split out of CLI so they live
# together and CLI itself stays under the project's class-length budget.

module Odysseus
  module CLI
    module InteractiveCommands
      # App shell
      def app_shell(server, options = {})
        config_file = options[:config] || 'deploy.yml'
        role = (options[:role] || 'web').to_sym
        config = load_config(config_file)
        image = running_image(server, config, role)

        ssh_keys = config[:ssh][:keys].map { |k| "-i #{File.expand_path(k)}" }.join(' ')
        env_flags = config[:env][:clear]&.map { |k, v| "-e #{k}=#{v}" }&.join(' ') || ''

        remote = "docker run -it --rm --network odysseus #{env_flags} #{image} /bin/sh"
        system("ssh #{ssh_keys} -t #{config[:ssh][:user]}@#{server} '#{remote}'")
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

        ssh_keys = config[:ssh][:keys].map { |k| "-i #{File.expand_path(k)}" }.join(' ')
        env_flags = config[:env][:clear]&.map { |k, v| "-e #{k}=#{v}" }&.join(' ') || ''

        remote = "docker run -it --rm --network odysseus #{env_flags} #{image} #{console_cmd}"
        system("ssh #{ssh_keys} -t #{config[:ssh][:user]}@#{server} '#{remote}'")
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

        ssh_keys = config[:ssh][:keys].map { |k| "-i #{File.expand_path(k)}" }.join(' ')
        system("ssh #{ssh_keys} -t #{config[:ssh][:user]}@#{server} 'docker exec -it #{container_id} /bin/sh'")
      rescue Odysseus::Error => e
        @ui.error e.message
        exit 1
      end
    end
  end
end
