# spec/odysseus/cli/bin_spec.rb
#
# Exercises the executable the way a user runs it, so argument dispatch, usage
# text and exit codes are covered. Nothing here touches a server: every example
# stops at argument handling.

require 'spec_helper'

RSpec.describe 'bin/odysseus' do
  describe 'with no arguments' do
    it 'prints usage and exits non-zero' do
      stdout, _stderr, status = run_cli

      expect(stdout).to include('Usage: odysseus <command> [options]')
      expect(status.exitstatus).to eq(1)
    end

    it 'lists the commands it accepts' do
      stdout, _stderr, _status = run_cli

      %w[deploy build pussh status containers logs cleanup validate accessory app secrets]
        .each { |command| expect(stdout).to include(command) }
    end
  end

  describe 'with an unknown command' do
    it 'prints usage and exits non-zero' do
      stdout, _stderr, status = run_cli('teleport')

      expect(stdout).to include('Usage: odysseus <command> [options]')
      expect(status.exitstatus).to eq(1)
    end
  end

  describe 'commands that need a server argument' do
    %w[status containers logs cleanup].each do |command|
      it "#{command} reports the missing server and exits non-zero" do
        stdout, _stderr, status = run_cli(command)

        expect(stdout).to include("#{command} requires a server argument")
        expect(status.exitstatus).to eq(1)
      end
    end
  end

  describe 'accessory' do
    it 'prints its subcommands when none is given' do
      stdout, _stderr, status = run_cli('accessory')

      expect(stdout).to include('Usage: odysseus accessory <subcommand>')
      %w[boot boot-all remove restart upgrade status logs exec shell]
        .each { |sub| expect(stdout).to include(sub) }
      expect(status.exitstatus).to eq(1)
    end

    it 'rejects an unknown subcommand' do
      _stdout, _stderr, status = run_cli('accessory', 'levitate')

      expect(status.exitstatus).to eq(1)
    end

    it 'requires --name for boot' do
      stdout, _stderr, status = run_cli('accessory', 'boot', '--config', fixture_path('deploy.yml'))

      expect(stdout).to include('Accessory name required')
      expect(status.exitstatus).to eq(1)
    end

    it 'requires a server for logs' do
      stdout, _stderr, status = run_cli('accessory', 'logs', '--name', 'db')

      expect(stdout).to include('requires a server argument')
      expect(status.exitstatus).to eq(1)
    end
  end

  describe 'app' do
    it 'prints its subcommands when none is given' do
      stdout, _stderr, status = run_cli('app')

      expect(stdout).to include('Usage: odysseus app <subcommand> <server>')
      %w[shell exec console].each { |sub| expect(stdout).to include(sub) }
      expect(status.exitstatus).to eq(1)
    end

    it 'requires a server' do
      stdout, _stderr, status = run_cli('app', 'exec', '--command', 'true')

      expect(stdout).to include('requires a server argument')
      expect(status.exitstatus).to eq(1)
    end

    it 'requires --command for exec' do
      stdout, _stderr, status = run_cli(
        'app', 'exec', 'web1.example.com', '--config', fixture_path('deploy.yml')
      )

      expect(stdout).to include('Command required')
      expect(status.exitstatus).to eq(1)
    end
  end

  describe 'secrets' do
    it 'prints its subcommands when none is given' do
      stdout, _stderr, status = run_cli('secrets')

      expect(stdout).to include('Usage: odysseus secrets <subcommand>')
      %w[generate-key encrypt decrypt edit].each { |sub| expect(stdout).to include(sub) }
      expect(status.exitstatus).to eq(1)
    end

    it 'generates a master key' do
      stdout, _stderr, status = run_cli('secrets', 'generate-key')

      expect(stdout).to match(/[0-9a-f]{64}/)
      expect(status.exitstatus).to eq(0)
    end

    it 'refuses to encrypt without an input file' do
      stdout, _stderr, status = run_cli('secrets', 'encrypt')

      expect(stdout).to include('Input file required')
      expect(status.exitstatus).to eq(1)
    end

    it 'reports an input file that does not exist' do
      stdout, _stderr, status = run_cli('secrets', 'encrypt', '--input', 'nope.yml')

      expect(stdout).to include('Input file not found')
      expect(status.exitstatus).to eq(1)
    end
  end

  describe 'validate' do
    it 'accepts a valid config and summarises it' do
      stdout, _stderr, status = run_cli('validate', '--config', fixture_path('deploy.yml'))

      expect(stdout).to include('Configuration is valid')
      expect(stdout).to include('myapp')
      expect(status.exitstatus).to eq(0)
    end

    it 'reports a config file that does not exist' do
      stdout, _stderr, status = run_cli('validate', '--config', 'nope.yml')

      expect(stdout).to include('Validation failed')
      expect(status.exitstatus).to eq(1)
    end
  end

  describe 'version' do
    it 'reports the version and exits zero' do
      stdout, _stderr, status = run_cli('version')

      expect(stdout).to include(Odysseus::CLI::VERSION)
      expect(status.exitstatus).to eq(0)
    end

    it 'is also available as --version' do
      stdout, _stderr, status = run_cli('--version')

      expect(stdout).to include(Odysseus::CLI::VERSION)
      expect(status.exitstatus).to eq(0)
    end

    it 'reports the core version too, since deploy behaviour lives there' do
      stdout, _stderr, _status = run_cli('version')

      expect(stdout).to include(Odysseus::Core::VERSION)
    end
  end
end
