# frozen_string_literal: true

require 'zeitwerk'

module Odysseus
  class << self
    def loader
      @loader ||= begin
        loader = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
        loader.inflector.inflect(
          'ssh' => 'SSH',
          'aws_asg' => 'AwsAsg'
        )
        # errors.rb doesn't follow Zeitwerk conventions (plural, defines multiple classes)
        loader.ignore("#{__dir__}/odysseus/errors.rb")
        loader.setup
        loader
      end
    end
  end
end

# Load errors manually before Zeitwerk (needed by other classes)
require_relative 'odysseus/errors'

Odysseus.loader
