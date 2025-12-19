# odysseus-cli/lib/odysseus/cli/cli.rb

require 'odysseus'
require 'odysseus/deployer/executor'
require 'odysseus/config/parser'
require 'odysseus/generators/docker_compose'
require 'odysseus/generators/caddy'
require 'pastel'

module Odysseus
  module CLI
    class CLI
      def initialize
        @pastel = Pastel.new
      end

      # Deploy command
      # Usage: odysseus deploy <server> [--config FILE] [--image TAG] [--dry-run]
      def deploy(server, options = {})
        config_file = options[:config] || 'config/deploy.yml'
        image_tag = options[:image] || 'latest'
        dry_run = options[:'dry-run'] || false

        puts @pastel.cyan("🚀 Odysseus Deploy")
        puts @pastel.blue("Server: #{server}")
        puts @pastel.blue("Config: #{config_file}")
        puts @pastel.blue("Image tag: #{image_tag}")
        puts ""

        executor = Odysseus::Deployer::Executor.new(config_file)
        executor.deploy(server: server, image_tag: image_tag, dry_run: dry_run)

        puts @pastel.green("✓ Deploy complete!")
      rescue Odysseus::Error => e
        puts @pastel.red("✗ Error: #{e.message}")
        exit 1
      end

      # Generate command
      # Usage: odysseus generate <type> [--config FILE]
      def generate(type, options = {})
        config_file = options[:config] || 'config/deploy.yml'

        parser = Odysseus::Config::Parser.new(config_file)
        config = parser.parse

        case type
        when 'docker-compose'
          content = Odysseus::Generators::DockerCompose.new(config).generate
          puts content
        when 'caddyfile'
          content = Odysseus::Generators::Caddy.new(config).generate
          puts content
        else
          puts @pastel.red("Unknown type: #{type}")
          exit 1
        end
      rescue Odysseus::Error => e
        puts @pastel.red("✗ Error: #{e.message}")
        exit 1
      end

      # Validate command
      # Usage: odysseus validate [--config FILE]
      def validate(options = {})
        config_file = options[:config] || 'config/deploy.yml'

        puts @pastel.cyan("Validating #{config_file}...")

        parser = Odysseus::Config::Parser.new(config_file)
        config = parser.parse

        puts @pastel.green("✓ Configuration is valid!")
        puts ""
        puts "Service: #{config[:service]}"
        puts "Image: #{config[:image]}"
        puts "Servers: #{config[:servers].keys.join(', ')}"
        puts "Proxy hosts: #{config[:proxy][:hosts]&.join(', ')}"
      rescue Odysseus::Error => e
        puts @pastel.red("✗ Validation failed: #{e.message}")
        exit 1
      end
    end
  end
end
