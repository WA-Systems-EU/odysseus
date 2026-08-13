# spec/odysseus/deployer/retention_sweeper_spec.rb
#
# Exercised through Executor#prune_old_images rather than by constructing the
# sweeper, because that is the path a deploy takes.

require 'spec_helper'

RSpec.describe Odysseus::Deployer::RetentionSweeper do
  let(:mock_ssh) { instance_double(Odysseus::Deployer::SSH) }
  let(:mock_orchestrator) { instance_double(Odysseus::Orchestrator::WebDeploy) }

  describe 'sweeping through Executor#prune_old_images' do
    let(:retain_two) { Odysseus::Deployer::Executor.new(fixture_path('deploy-retain-two.yml')) }
    let(:mock_docker) { instance_double(Odysseus::Docker::Client) }
    let(:deploy_log) { instance_double(Odysseus::DeployLog) }

    def entry(version, at)
      Odysseus::DeployLog::Entry.new(
        at: at, version: version, role: 'web', ref: 'main',
        deployer: 'dev@example.com', kind: 'deployed', from: nil
      )
    end

    before do
      allow(Odysseus::Deployer::SSH).to receive(:new).and_return(mock_ssh)
      allow(mock_ssh).to receive(:close)
      allow(Odysseus::Docker::Client).to receive(:new).and_return(mock_docker)
      allow(Odysseus::DeployLog).to receive(:new).and_return(deploy_log)
      allow(deploy_log).to receive(:entries).and_return(
        [entry('v1', '2026-08-01T09:00:00Z'), entry('v2', '2026-08-02T09:00:00Z'),
         entry('v3', '2026-08-03T09:00:00Z')]
      )
      allow(mock_docker).to receive(:image_tags).and_return(%w[v3 v2 v1])
      allow(mock_docker).to receive(:versions_in_use).and_return(['v3'])
      allow(mock_docker).to receive(:remove_image)
    end

    it 'removes the images outside the retain window, fully qualified' do
      expect(mock_docker).to receive(:remove_image).with('myapp-production:v1')

      retain_two.prune_old_images
    end

    it 'keeps the versions inside the retain window' do
      expect(mock_docker).not_to receive(:remove_image).with('myapp-production:v3')
      expect(mock_docker).not_to receive(:remove_image).with('myapp-production:v2')

      retain_two.prune_old_images
    end

    it 'returns the versions removed, keyed by host' do
      expect(retain_two.prune_old_images).to eq('web1.example.com' => ['v1'])
    end

    it 'protects the versions of every container on the host, across all its roles' do
      expect(mock_docker).to receive(:versions_in_use).with(['myapp']).and_return(%w[v3 v1])
      expect(mock_docker).not_to receive(:remove_image)

      retain_two.prune_old_images
    end

    it 'skips a host with no deploy log rather than guessing from image order' do
      allow(deploy_log).to receive(:entries).and_return([])
      # Guards against a mutant that drops the early return: with an empty
      # history, RetentionPlanner would still compute an empty remove list
      # from real image_tags/versions_in_use calls, making the return value
      # alone insufficient to prove the host was skipped rather than surveyed
      # and found to have nothing eligible.
      expect(mock_docker).not_to receive(:image_tags)
      expect(mock_docker).not_to receive(:versions_in_use)
      expect(mock_docker).not_to receive(:remove_image)

      expect(retain_two.prune_old_images).to eq('web1.example.com' => [])
    end

    # The deploy has already succeeded and traffic has already switched by the
    # time this runs. An image docker refuses to delete must be a logged skip.
    it 'continues after a removal docker refuses, and still reports the rest' do
      allow(deploy_log).to receive(:entries).and_return(
        [entry('v1', '2026-08-01T09:00:00Z'), entry('v2', '2026-08-02T09:00:00Z'),
         entry('v3', '2026-08-03T09:00:00Z'), entry('v4', '2026-08-04T09:00:00Z')]
      )
      allow(mock_docker).to receive(:image_tags).and_return(%w[v4 v3 v2 v1])
      allow(mock_docker).to receive(:versions_in_use).and_return(['v4'])
      allow(mock_docker).to receive(:remove_image).with('myapp-production:v1')
                                                  .and_raise(Odysseus::SSHCommandError, 'image is in use')
      allow(mock_docker).to receive(:remove_image).with('myapp-production:v2')

      expect(retain_two.prune_old_images).to eq('web1.example.com' => ['v2'])
    end

    it 'survives a raw connection error without failing the caller' do
      allow(mock_docker).to receive(:remove_image).and_raise(IOError, 'connection reset')

      expect { retain_two.prune_old_images }.not_to raise_error
    end

    # sweep_host's own rescue also catches StandardError, so "does not raise"
    # alone cannot tell a per-image rescue from a per-host one: either would
    # leave the caller unharmed. The observable difference is whether pruning
    # continues to the next version after a raw connection error, the same way
    # it already does after docker's own refusal.
    it 'continues to the next version after a raw connection error, not just after a docker refusal' do
      allow(deploy_log).to receive(:entries).and_return(
        [entry('v1', '2026-08-01T09:00:00Z'), entry('v2', '2026-08-02T09:00:00Z'),
         entry('v3', '2026-08-03T09:00:00Z'), entry('v4', '2026-08-04T09:00:00Z')]
      )
      allow(mock_docker).to receive(:image_tags).and_return(%w[v4 v3 v2 v1])
      allow(mock_docker).to receive(:versions_in_use).and_return(['v4'])
      allow(mock_docker).to receive(:remove_image).with('myapp-production:v1')
                                                  .and_raise(IOError, 'connection reset')
      allow(mock_docker).to receive(:remove_image).with('myapp-production:v2')

      expect(retain_two.prune_old_images).to eq('web1.example.com' => ['v2'])
    end

    it 'closes the connection it opened, even when a removal raises' do
      allow(mock_docker).to receive(:remove_image).and_raise(IOError, 'connection reset')
      expect(mock_ssh).to receive(:close)

      retain_two.prune_old_images
    end
  end
end
