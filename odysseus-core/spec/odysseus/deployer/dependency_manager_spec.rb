# spec/odysseus/deployer/dependency_manager_spec.rb

require 'spec_helper'

# Exercised through Executor's delegating API (deploy_dependency, remove_dependency,
# restart_dependency, upgrade_dependency, dependency_status, boot_dependencies) rather
# than by instantiating DependencyManager directly, because those six methods are
# the CLI's actual entry points (see odysseus-cli/lib/odysseus/cli/cli.rb) and the
# `connector: method(:connect_to_server)` seam is part of what needs covering.
RSpec.describe Odysseus::Deployer::DependencyManager do
  let(:fixture_file) { fixture_path('deploy-dependencies.yml') }
  let(:executor) { Odysseus::Deployer::Executor.new(fixture_file) }
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:orchestrator) { instance_double(Odysseus::Orchestrator::DependencyDeploy) }

  before do
    allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
    allow(mock_ssh).to receive(:close)
    allow(Odysseus::Orchestrator::DependencyDeploy).to receive(:new).and_return(orchestrator)
  end

  describe 'the four verbs' do
    before do
      allow(orchestrator).to receive(:deploy).and_return(success: true)
      allow(orchestrator).to receive(:remove).and_return(success: true)
      allow(orchestrator).to receive(:restart).and_return(success: true)
      allow(orchestrator).to receive(:upgrade).and_return(success: true)
    end

    {
      deploy_dependency: :deploy, remove_dependency: :remove,
      restart_dependency: :restart, upgrade_dependency: :upgrade
    }.each do |executor_method, orchestrator_method|
      describe "##{executor_method}" do
        it 'returns a Hash keyed by every host the dependency is configured on' do
          result = executor.public_send(executor_method, name: 'redis')

          expect(result.keys).to eq(%w[acc1.example.com acc2.example.com])
        end

        it 'coerces a String name to a Symbol for the orchestrator' do
          expect(orchestrator).to receive(orchestrator_method).with(name: :redis).twice.and_return(success: true)

          executor.public_send(executor_method, name: 'redis')
        end

        it 'raises with the exact message for an dependency not in config' do
          expect { executor.public_send(executor_method, name: 'nope') }
            .to raise_error(Odysseus::ConfigError, "Dependency 'nope' not found in config")
        end

        it 'raises with the exact message for a configured dependency with no hosts' do
          no_hosts_executor = Odysseus::Deployer::Executor.new(fixture_path('deploy-dependency-no-hosts.yml'))

          expect { no_hosts_executor.public_send(executor_method, name: 'ghost') }
            .to raise_error(Odysseus::ConfigError, 'No hosts configured for dependency ghost')
        end

        it 'closes one SSH connection per host' do
          expect(mock_ssh).to receive(:close).twice

          executor.public_send(executor_method, name: 'redis')
        end

        it 'still closes the connection when the orchestrator raises' do
          allow(orchestrator).to receive(orchestrator_method).and_raise(Odysseus::DeployError, 'boom')
          expect(mock_ssh).to receive(:close).at_least(:once)

          expect { executor.public_send(executor_method, name: 'redis') }
            .to raise_error(Odysseus::DeployError)
        end
      end
    end
  end

  describe '#dependency_status' do
    context 'with dependencies configured' do
      before do
        allow(orchestrator).to receive(:list_status).and_return(
          [
            { name: :redis, service: 'myapp-redis', image: 'redis:7', running: true,
              container_id: 'abc123', has_proxy: false },
            { name: :sidekiq, service: 'myapp-sidekiq', image: 'sidekiq:latest', running: false,
              container_id: nil, has_proxy: false }
          ]
        )
      end

      # This is the pin for the get_status -> list_status fix: DependencyDeploy
      # exposes #list_status (no args, every dependency on the host), not a
      # per-dependency #get_status. Because `orchestrator` is a verifying
      # double (instance_double(Odysseus::Orchestrator::DependencyDeploy)),
      # stubbing a method DependencyDeploy does not define — such as
      # get_status — raises immediately, so this example fails loudly the
      # moment #status_on regresses to the old, broken call.
      it 'returns the status for the requested dependency with host set, via list_status' do
        statuses = executor.dependency_status

        redis_entries = statuses.select { |s| s[:name] == :redis }
        expect(redis_entries.map { |s| s[:host] }).to eq(%w[acc1.example.com acc2.example.com])
        expect(redis_entries.first).to include(running: true, container_id: 'abc123')
      end

      it 'reports every dependency on every host it is configured on, dependency-then-host' do
        statuses = executor.dependency_status

        entries = statuses.map { |s| [s[:name], s[:host]] }
        expect(entries).to eq(
          [
            [:redis, 'acc1.example.com'], [:redis, 'acc2.example.com'],
            [:sidekiq, 'acc1.example.com']
          ]
        )
      end

      it 'closes one SSH connection per host queried' do
        expect(mock_ssh).to receive(:close).exactly(3).times

        executor.dependency_status
      end

      it 'still closes the connection when list_status raises' do
        allow(orchestrator).to receive(:list_status).and_raise(Odysseus::SSHCommandError, 'no docker')
        expect(mock_ssh).to receive(:close).at_least(:once)

        expect { executor.dependency_status }.to raise_error(Odysseus::SSHCommandError)
      end
    end

    context 'with no dependencies configured' do
      let(:executor) { Odysseus::Deployer::Executor.new(fixture_path('deploy.yml')) }

      it 'returns an empty array without connecting anywhere' do
        expect(Odysseus::Deployer::SSH).not_to receive(:new)

        expect(executor.dependency_status).to eq([])
      end
    end
  end

  describe '#boot_dependencies' do
    context 'with dependencies configured' do
      before do
        allow(orchestrator).to receive(:deploy).and_return(success: true)
      end

      it 'returns a Hash keyed by dependency name' do
        expect(executor.boot_dependencies.keys).to eq(%i[redis sidekiq])
      end
    end

    context 'with no dependencies configured' do
      let(:executor) { Odysseus::Deployer::Executor.new(fixture_path('deploy.yml')) }

      it 'returns an empty Hash without connecting anywhere' do
        expect(Odysseus::Deployer::SSH).not_to receive(:new)

        expect(executor.boot_dependencies).to eq({})
      end
    end
  end

  describe 'the SSH connection every verb and status query opens' do
    before { allow(orchestrator).to receive(:list_status).and_return([]) }

    it 'passes host, user, keys and use_tailscale through' do
      expect(Odysseus::Deployer::SSH).to receive(:new).with(
        host: 'acc1.example.com', user: 'root', keys: ['~/.ssh/id_ed25519'],
        use_tailscale: true, verbose: false
      ).at_least(:once).and_return(mock_ssh)

      executor.dependency_status
    end

    it 'carries verbose: true through when the executor was built verbose' do
      verbose_executor = Odysseus::Deployer::Executor.new(fixture_file, verbose: true)

      expect(Odysseus::Deployer::SSH).to receive(:new).with(
        host: 'acc1.example.com', user: 'root', keys: ['~/.ssh/id_ed25519'],
        use_tailscale: true, verbose: true
      ).at_least(:once).and_return(mock_ssh)

      verbose_executor.dependency_status
    end
  end

  # The three examples below construct DependencyManager directly with config
  # shapes the real parser never produces — a hash with no :dependencies key,
  # an dependency hash with no :hosts key, and a host whose list_status omits
  # an dependency it is configured for. Going through Executor and the real
  # parser can only ever exercise the normalized shape (config/parser.rb
  # defaults :dependencies to {} and every dependency to a :hosts array), so
  # the defensive guards at dependency_manager.rb's `&.any?`, `if acc_status`
  # and `|| []` can never be reached that way, and mutating any of them away
  # left the rest of this file green. Direct construction is the only way to
  # pin them, so it is used here even though the rest of this file avoids it.
  describe 'defensive fallbacks against a config shape the parser never produces' do
    let(:connector) { ->(_host) { mock_ssh } }

    it 'treats a missing :dependencies key as none configured, not a NoMethodError on nil' do
      manager = described_class.new(config: {}, secrets_loader: nil, connector: connector)

      expect(manager.status).to eq([])
    end

    it 'skips an dependency that list_status does not report, rather than recording a nil entry' do
      manager = described_class.new(
        config: { dependencies: { redis: { hosts: ['acc1.example.com'] } } },
        secrets_loader: nil, connector: connector
      )
      allow(orchestrator).to receive(:list_status).and_return([])

      expect(manager.status).to eq([])
    end

    it 'treats a missing :hosts key on an dependency as no hosts, not a NoMethodError on nil' do
      manager = described_class.new(
        config: { dependencies: { redis: {} } }, secrets_loader: nil, connector: connector
      )

      expect { manager.deploy(name: 'redis') }
        .to raise_error(Odysseus::ConfigError, 'No hosts configured for dependency redis')
    end
  end
end
