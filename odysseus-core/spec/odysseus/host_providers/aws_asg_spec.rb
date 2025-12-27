# spec/odysseus/host_providers/aws_asg_spec.rb

require 'spec_helper'

RSpec.describe Odysseus::HostProviders::AwsAsg do
  let(:valid_config) do
    {
      asg: 'my-web-asg',
      region: 'us-east-1',
      use_private_ip: false,
      state: 'InService'
    }
  end

  describe '#initialize' do
    it 'accepts valid configuration' do
      provider = described_class.new(valid_config)
      expect(provider.name).to eq('aws_asg(my-web-asg)')
    end

    it 'raises error when asg name is missing' do
      config = valid_config.dup
      config.delete(:asg)

      expect { described_class.new(config) }
        .to raise_error(Odysseus::ConfigError, /requires 'asg' name/)
    end

    it 'raises error when region is missing' do
      config = valid_config.dup
      config.delete(:region)

      expect { described_class.new(config) }
        .to raise_error(Odysseus::ConfigError, /requires 'region'/)
    end

    it 'defaults use_private_ip to false' do
      config = { asg: 'test-asg', region: 'us-west-2' }
      provider = described_class.new(config)
      # Provider created successfully with defaults
      expect(provider.name).to eq('aws_asg(test-asg)')
    end

    it 'defaults state to InService' do
      config = { asg: 'test-asg', region: 'us-west-2' }
      provider = described_class.new(config)
      expect(provider.name).to eq('aws_asg(test-asg)')
    end
  end

  describe '#resolve' do
    let(:provider) { described_class.new(valid_config) }

    context 'when AWS SDK is not installed' do
      before do
        allow(provider).to receive(:require).with('aws-sdk-autoscaling').and_raise(LoadError)
      end

      it 'raises ConfigError with helpful message' do
        expect { provider.resolve }
          .to raise_error(Odysseus::ConfigError, /AWS SDK not installed/)
      end
    end

    context 'when AWS SDK is available' do
      let(:asg_client) { double('Aws::AutoScaling::Client') }
      let(:ec2_client) { double('Aws::EC2::Client') }

      before do
        # Stub the AWS SDK require
        allow(provider).to receive(:require_aws_sdk!)

        # Create mock classes that accept keyword arguments
        mock_asg_class = Class.new do
          def initialize(**opts); end
        end
        mock_ec2_class = Class.new do
          def initialize(**opts); end
        end

        # Stub client creation
        stub_const('Aws::AutoScaling::Client', mock_asg_class)
        stub_const('Aws::EC2::Client', mock_ec2_class)
        allow(Aws::AutoScaling::Client).to receive(:new).and_return(asg_client)
        allow(Aws::EC2::Client).to receive(:new).and_return(ec2_client)
      end

      it 'returns instance IPs from ASG' do
        asg_instance1 = double('ASGInstance', instance_id: 'i-111', lifecycle_state: 'InService')
        asg_instance2 = double('ASGInstance', instance_id: 'i-222', lifecycle_state: 'InService')
        asg = double('ASG', instances: [asg_instance1, asg_instance2])
        asg_response = double('ASGResponse', auto_scaling_groups: [asg])

        ec2_instance1 = double('EC2Instance', public_ip_address: '1.2.3.4', private_ip_address: '10.0.0.1')
        ec2_instance2 = double('EC2Instance', public_ip_address: '5.6.7.8', private_ip_address: '10.0.0.2')
        reservation = double('Reservation', instances: [ec2_instance1, ec2_instance2])
        ec2_response = double('EC2Response', reservations: [reservation])

        allow(asg_client).to receive(:describe_auto_scaling_groups)
          .with(auto_scaling_group_names: ['my-web-asg'])
          .and_return(asg_response)
        allow(ec2_client).to receive(:describe_instances)
          .with(instance_ids: ['i-111', 'i-222'])
          .and_return(ec2_response)

        expect(provider.resolve).to eq(['1.2.3.4', '5.6.7.8'])
      end

      it 'returns private IPs when use_private_ip is true' do
        config = valid_config.merge(use_private_ip: true)
        provider = described_class.new(config)
        allow(provider).to receive(:require_aws_sdk!)

        asg_instance = double('ASGInstance', instance_id: 'i-111', lifecycle_state: 'InService')
        asg = double('ASG', instances: [asg_instance])
        asg_response = double('ASGResponse', auto_scaling_groups: [asg])

        ec2_instance = double('EC2Instance', public_ip_address: '1.2.3.4', private_ip_address: '10.0.0.1')
        reservation = double('Reservation', instances: [ec2_instance])
        ec2_response = double('EC2Response', reservations: [reservation])

        allow(asg_client).to receive(:describe_auto_scaling_groups).and_return(asg_response)
        allow(ec2_client).to receive(:describe_instances).and_return(ec2_response)

        expect(provider.resolve).to eq(['10.0.0.1'])
      end

      it 'filters instances by lifecycle state' do
        asg_instance1 = double('ASGInstance', instance_id: 'i-111', lifecycle_state: 'InService')
        asg_instance2 = double('ASGInstance', instance_id: 'i-222', lifecycle_state: 'Terminating')
        asg = double('ASG', instances: [asg_instance1, asg_instance2])
        asg_response = double('ASGResponse', auto_scaling_groups: [asg])

        ec2_instance = double('EC2Instance', public_ip_address: '1.2.3.4', private_ip_address: '10.0.0.1')
        reservation = double('Reservation', instances: [ec2_instance])
        ec2_response = double('EC2Response', reservations: [reservation])

        allow(asg_client).to receive(:describe_auto_scaling_groups).and_return(asg_response)
        allow(ec2_client).to receive(:describe_instances)
          .with(instance_ids: ['i-111']) # Only InService instance
          .and_return(ec2_response)

        expect(provider.resolve).to eq(['1.2.3.4'])
      end

      it 'returns empty array when ASG has no instances' do
        asg = double('ASG', instances: [])
        asg_response = double('ASGResponse', auto_scaling_groups: [asg])

        allow(asg_client).to receive(:describe_auto_scaling_groups).and_return(asg_response)

        expect(provider.resolve).to eq([])
      end

      it 'raises error when ASG not found' do
        asg_response = double('ASGResponse', auto_scaling_groups: [])

        allow(asg_client).to receive(:describe_auto_scaling_groups).and_return(asg_response)

        expect { provider.resolve }
          .to raise_error(Odysseus::ConfigError, /ASG 'my-web-asg' not found/)
      end

      it 'falls back to private IP when public IP is nil' do
        asg_instance = double('ASGInstance', instance_id: 'i-111', lifecycle_state: 'InService')
        asg = double('ASG', instances: [asg_instance])
        asg_response = double('ASGResponse', auto_scaling_groups: [asg])

        ec2_instance = double('EC2Instance', public_ip_address: nil, private_ip_address: '10.0.0.1')
        reservation = double('Reservation', instances: [ec2_instance])
        ec2_response = double('EC2Response', reservations: [reservation])

        allow(asg_client).to receive(:describe_auto_scaling_groups).and_return(asg_response)
        allow(ec2_client).to receive(:describe_instances).and_return(ec2_response)

        expect(provider.resolve).to eq(['10.0.0.1'])
      end
    end
  end

  describe '#name' do
    it 'includes the ASG name' do
      provider = described_class.new(valid_config)
      expect(provider.name).to eq('aws_asg(my-web-asg)')
    end
  end
end
