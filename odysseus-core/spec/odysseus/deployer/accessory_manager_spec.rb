# spec/odysseus/deployer/accessory_manager_spec.rb

require 'spec_helper'

# Exercised through Executor's delegating API (deploy_accessory, remove_accessory,
# restart_accessory, upgrade_accessory, accessory_status, boot_accessories) rather
# than by instantiating AccessoryManager directly, because those six methods are
# the CLI's actual entry points (see odysseus-cli/lib/odysseus/cli/cli.rb) and the
# `connector: method(:connect_to_server)` seam is part of what needs covering.
RSpec.describe Odysseus::Deployer::AccessoryManager do
  let(:fixture_file) { fixture_path('deploy-accessories.yml') }
  let(:executor) { Odysseus::Deployer::Executor.new(fixture_file) }
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:orchestrator) { instance_double(Odysseus::Orchestrator::AccessoryDeploy) }

  before do
    allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
    allow(mock_ssh).to receive(:close)
    allow(Odysseus::Orchestrator::AccessoryDeploy).to receive(:new).and_return(orchestrator)
  end

  describe 'the four verbs' do
    before do
      allow(orchestrator).to receive(:deploy).and_return(success: true)
      allow(orchestrator).to receive(:remove).and_return(success: true)
      allow(orchestrator).to receive(:restart).and_return(success: true)
      allow(orchestrator).to receive(:upgrade).and_return(success: true)
    end

    {
      deploy_accessory: :deploy, remove_accessory: :remove,
      restart_accessory: :restart, upgrade_accessory: :upgrade
    }.each do |executor_method, orchestrator_method|
      describe "##{executor_method}" do
        it 'returns a Hash keyed by every host the accessory is configured on' do
          result = executor.public_send(executor_method, name: 'redis')

          expect(result.keys).to eq(%w[acc1.example.com acc2.example.com])
        end

        it 'coerces a String name to a Symbol for the orchestrator' do
          expect(orchestrator).to receive(orchestrator_method).with(name: :redis).twice.and_return(success: true)

          executor.public_send(executor_method, name: 'redis')
        end

        it 'raises with the exact message for an accessory not in config' do
          expect { executor.public_send(executor_method, name: 'nope') }
            .to raise_error(Odysseus::ConfigError, "Accessory 'nope' not found in config")
        end

        it 'raises with the exact message for a configured accessory with no hosts' do
          no_hosts_executor = Odysseus::Deployer::Executor.new(fixture_path('deploy-accessory-no-hosts.yml'))

          expect { no_hosts_executor.public_send(executor_method, name: 'ghost') }
            .to raise_error(Odysseus::ConfigError, 'No hosts configured for accessory ghost')
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

  describe '#accessory_status' do
    context 'with accessories configured' do
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

      # This is the pin for the get_status -> list_status fix: AccessoryDeploy
      # exposes #list_status (no args, every accessory on the host), not a
      # per-accessory #get_status. Because `orchestrator` is a verifying
      # double (instance_double(Odysseus::Orchestrator::AccessoryDeploy)),
      # stubbing a method AccessoryDeploy does not define — such as
      # get_status — raises immediately, so this example fails loudly the
      # moment #status_on regresses to the old, broken call.
      it 'returns the status for the requested accessory with host set, via list_status' do
        statuses = executor.accessory_status

        redis_entries = statuses.select { |s| s[:name] == :redis }
        expect(redis_entries.map { |s| s[:host] }).to eq(%w[acc1.example.com acc2.example.com])
        expect(redis_entries.first).to include(running: true, container_id: 'abc123')
      end

      it 'reports every accessory on every host it is configured on, accessory-then-host' do
        statuses = executor.accessory_status

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

        executor.accessory_status
      end

      it 'still closes the connection when list_status raises' do
        allow(orchestrator).to receive(:list_status).and_raise(Odysseus::SSHCommandError, 'no docker')
        expect(mock_ssh).to receive(:close).at_least(:once)

        expect { executor.accessory_status }.to raise_error(Odysseus::SSHCommandError)
      end
    end

    context 'with no accessories configured' do
      let(:executor) { Odysseus::Deployer::Executor.new(fixture_path('deploy.yml')) }

      it 'returns an empty array without connecting anywhere' do
        expect(Odysseus::Deployer::SSH).not_to receive(:new)

        expect(executor.accessory_status).to eq([])
      end
    end
  end

  describe '#boot_accessories' do
    context 'with accessories configured' do
      before do
        allow(orchestrator).to receive(:deploy).and_return(success: true)
      end

      it 'returns a Hash keyed by accessory name' do
        expect(executor.boot_accessories.keys).to eq(%i[redis sidekiq])
      end
    end

    context 'with no accessories configured' do
      let(:executor) { Odysseus::Deployer::Executor.new(fixture_path('deploy.yml')) }

      it 'returns an empty Hash without connecting anywhere' do
        expect(Odysseus::Deployer::SSH).not_to receive(:new)

        expect(executor.boot_accessories).to eq({})
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

      executor.accessory_status
    end

    it 'carries verbose: true through when the executor was built verbose' do
      verbose_executor = Odysseus::Deployer::Executor.new(fixture_file, verbose: true)

      expect(Odysseus::Deployer::SSH).to receive(:new).with(
        host: 'acc1.example.com', user: 'root', keys: ['~/.ssh/id_ed25519'],
        use_tailscale: true, verbose: true
      ).at_least(:once).and_return(mock_ssh)

      verbose_executor.accessory_status
    end
  end
end
