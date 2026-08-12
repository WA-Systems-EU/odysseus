# spec/odysseus/core/volume_namespacer_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::Core::VolumeNamespacer do
  let(:test_class) do
    Class.new do
      include Odysseus::Core::VolumeNamespacer

      attr_accessor :docker_mock, :log_messages

      def initialize
        @log_messages = []
      end

      def log(msg, level = :info)
        @log_messages << { message: msg, level: level }
      end

      private

      def docker_client
        @docker_mock
      end
    end
  end

  let(:namespacer) { test_class.new }
  let(:mock_docker) { instance_double(Odysseus::Docker::Client) }

  before do
    namespacer.docker_mock = mock_docker
    allow(mock_docker).to receive(:volume_exists?).and_return(false)
  end

  describe '#namespace_volumes' do
    it 'returns nil for nil volumes' do
      expect(namespacer.namespace_volumes(nil, service: 'myapp')).to be_nil
    end

    it 'prefixes named volumes with the service name' do
      volumes = ['data:/var/lib/postgresql/data']
      result = namespacer.namespace_volumes(volumes, service: 'myapp')
      expect(result).to eq(['myapp-data:/var/lib/postgresql/data'])
    end

    it 'leaves host path volumes unchanged' do
      volumes = ['/var/lib/odysseus/myapp/postgres:/var/lib/postgresql/data']
      result = namespacer.namespace_volumes(volumes, service: 'myapp')
      expect(result).to eq(['/var/lib/odysseus/myapp/postgres:/var/lib/postgresql/data'])
    end

    it 'preserves volume mode (ro/rw)' do
      volumes = ['data:/var/lib/postgresql/data:ro']
      result = namespacer.namespace_volumes(volumes, service: 'myapp')
      expect(result).to eq(['myapp-data:/var/lib/postgresql/data:ro'])
    end

    it 'does not double-prefix already namespaced volumes' do
      volumes = ['myapp-data:/var/lib/postgresql/data']
      result = namespacer.namespace_volumes(volumes, service: 'myapp')
      expect(result).to eq(['myapp-data:/var/lib/postgresql/data'])
    end

    it 'handles multiple volumes' do
      volumes = [
        'data:/var/lib/postgresql/data',
        '/host/path:/container/path',
        'cache:/tmp/cache'
      ]
      result = namespacer.namespace_volumes(volumes, service: 'myapp')
      expect(result).to eq([
                             'myapp-data:/var/lib/postgresql/data',
                             '/host/path:/container/path',
                             'myapp-cache:/tmp/cache'
                           ])
    end

    context 'when old un-namespaced volume exists on server' do
      before do
        allow(mock_docker).to receive(:volume_exists?).with('myapp-data').and_return(false)
        allow(mock_docker).to receive(:volume_exists?).with('data').and_return(true)
      end

      it 'reuses the old volume to avoid data loss' do
        volumes = ['data:/var/lib/postgresql/data']
        result = namespacer.namespace_volumes(volumes, service: 'myapp')
        expect(result).to eq(['data:/var/lib/postgresql/data'])
      end

      it 'logs a deprecation warning with migration instructions' do
        namespacer.namespace_volumes(['data:/var/lib/postgresql/data'], service: 'myapp')

        warnings = namespacer.log_messages.select { |m| m[:level] == :warn }
        expect(warnings.size).to eq(2)
        expect(warnings.first[:message]).to include('not namespaced')
        expect(warnings.last[:message]).to include('docker volume create')
      end
    end

    context 'when new namespaced volume already exists' do
      before do
        allow(mock_docker).to receive(:volume_exists?).with('myapp-data').and_return(true)
      end

      it 'uses the namespaced volume' do
        volumes = ['data:/var/lib/postgresql/data']
        result = namespacer.namespace_volumes(volumes, service: 'myapp')
        expect(result).to eq(['myapp-data:/var/lib/postgresql/data'])
      end
    end

    context 'when docker client is not available' do
      before do
        namespacer.docker_mock = nil
      end

      it 'falls through to namespaced volume (fresh deploy)' do
        volumes = ['data:/var/lib/postgresql/data']
        result = namespacer.namespace_volumes(volumes, service: 'myapp')
        expect(result).to eq(['myapp-data:/var/lib/postgresql/data'])
      end
    end
  end
end
