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

      %w[deploy rollback build pussh status containers logs cleanup validate dependency app secrets]
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

  describe 'dependency' do
    it 'prints its subcommands when none is given' do
      stdout, _stderr, status = run_cli('dependency')

      expect(stdout).to include('Usage: odysseus dependency <subcommand>')
      %w[boot boot-all remove restart upgrade status logs exec shell]
        .each { |sub| expect(stdout).to include(sub) }
      expect(status.exitstatus).to eq(1)
    end

    it 'rejects an unknown subcommand' do
      _stdout, _stderr, status = run_cli('dependency', 'levitate')

      expect(status.exitstatus).to eq(1)
    end

    it 'requires --name for boot' do
      stdout, _stderr, status = run_cli('dependency', 'boot', '--config', fixture_path('deploy.yml'))

      expect(stdout).to include('Dependency name required')
      expect(status.exitstatus).to eq(1)
    end

    it 'requires a server for logs' do
      stdout, _stderr, status = run_cli('dependency', 'logs', '--name', 'db')

      expect(stdout).to include('requires a server argument')
      expect(status.exitstatus).to eq(1)
    end

    it 'accepts dep as a shorthand' do
      stdout, _stderr, status = run_cli('dep')

      expect(stdout).to include('Usage: odysseus dependency <subcommand>')
      expect(status.exitstatus).to eq(1)
    end
  end

  # `accessory` was the name until 0.4.4. It keeps working for one release so
  # app repos and muscle memory can migrate, but says so, because a silent
  # alias never gets migrated away from.
  describe 'the deprecated accessory alias' do
    it 'still dispatches to the dependency subcommands' do
      stdout, _stderr, status = run_cli('accessory')

      expect(stdout).to include('Usage: odysseus dependency <subcommand>')
      expect(status.exitstatus).to eq(1)
    end

    it 'warns that the name has changed, naming the replacement' do
      stdout, _stderr, _status = run_cli('accessory')

      expect(stdout).to match(/accessory.*renamed.*dependency/im)
    end

    it 'does not warn when the current name is used' do
      stdout, _stderr, _status = run_cli('dependency')

      expect(stdout).not_to match(/renamed/i)
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

  describe 'rollback' do
    it 'reports a config file that does not exist' do
      stdout, _stderr, status = run_cli('rollback', '--config', 'nope.yml')

      expect(stdout).to include('Config file not found')
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
