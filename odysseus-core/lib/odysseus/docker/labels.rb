# lib/odysseus/docker/labels.rb

module Odysseus
  module Docker
    # docker ps --format '{{json .}}' reports labels as one flat string:
    # "k=v,k2=v2". This turns that back into a hash.
    module Labels
      VERSION_KEY = 'odysseus.version'.freeze

      # @param raw [String, nil] the Labels field of a docker ps entry
      # @return [Hash{String => String}]
      def self.parse(raw)
        return {} if raw.nil? || raw.empty?

        raw.split(',').each_with_object({}) do |pair, acc|
          key, value = pair.split('=', 2)
          acc[key] = value.to_s unless key.nil? || key.empty?
        end
      end

      # @param container [Hash] a docker ps entry
      # @return [String, nil] the deployed version, when labelled
      def self.version_of(container)
        parse(container['Labels'])[VERSION_KEY]
      end
    end
  end
end
