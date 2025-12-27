# lib/odysseus/host_providers/aws_asg.rb

module Odysseus
  module HostProviders
    # AWS Auto Scaling Group host provider
    # Resolves hosts from EC2 instances in an ASG
    #
    # Config options:
    #   asg: ASG name (required)
    #   region: AWS region (required)
    #   use_private_ip: Use private IP instead of public (default: false)
    #   state: Only include instances in this lifecycle state (default: InService)
    #
    # AWS credentials are loaded from standard AWS credential chain:
    #   - Environment variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
    #   - Shared credentials file (~/.aws/credentials)
    #   - IAM instance profile (when running on EC2)
    class AwsAsg < Base
      def initialize(config)
        super
        @asg_name = config[:asg]
        @region = config[:region]
        @use_private_ip = config[:use_private_ip] || false
        @lifecycle_state = config[:state] || 'InService'

        validate_config!
      end

      # @return [Array<String>] list of instance IPs/hostnames
      def resolve
        require_aws_sdk!

        instances = fetch_asg_instances
        instances.map { |i| extract_address(i) }.compact
      end

      def name
        "aws_asg(#{@asg_name})"
      end

      private

      def validate_config!
        raise Odysseus::ConfigError, "AWS ASG provider requires 'asg' name" unless @asg_name
        raise Odysseus::ConfigError, "AWS ASG provider requires 'region'" unless @region
      end

      def require_aws_sdk!
        require 'aws-sdk-autoscaling'
        require 'aws-sdk-ec2'
      rescue LoadError
        raise Odysseus::ConfigError,
          "AWS SDK not installed. Add 'aws-sdk-autoscaling' and 'aws-sdk-ec2' to your Gemfile."
      end

      def fetch_asg_instances
        asg_client = Aws::AutoScaling::Client.new(region: @region)
        ec2_client = Aws::EC2::Client.new(region: @region)

        # Get instance IDs from ASG
        asg_response = asg_client.describe_auto_scaling_groups(
          auto_scaling_group_names: [@asg_name]
        )

        asg = asg_response.auto_scaling_groups.first
        raise Odysseus::ConfigError, "ASG '#{@asg_name}' not found" unless asg

        # Filter by lifecycle state
        instance_ids = asg.instances
          .select { |i| i.lifecycle_state == @lifecycle_state }
          .map(&:instance_id)

        return [] if instance_ids.empty?

        # Get instance details from EC2
        ec2_response = ec2_client.describe_instances(instance_ids: instance_ids)

        ec2_response.reservations.flat_map(&:instances)
      end

      def extract_address(instance)
        if @use_private_ip
          instance.private_ip_address
        else
          # Prefer public IP, fall back to private
          instance.public_ip_address || instance.private_ip_address
        end
      end
    end
  end
end
