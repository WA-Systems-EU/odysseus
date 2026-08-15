# spec/fixtures/plugins/broken_sail.rb
# A plugin that is installed but does not load — the shape of a real sail whose
# own dependency is missing, e.g. odysseus-sail-aws-asg without aws-sdk-autoscaling.
# The LoadError this raises names a file that is not the plugin itself.

require 'odysseus_missing_dependency'
