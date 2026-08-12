# lib/odysseus/deploy_version.rb

module Odysseus
  # The identity of one deploy: the image tag, plus where it came from.
  # ref and deployer are nil when the version was given explicitly, because an
  # arbitrary tag says nothing about a commit.
  DeployVersion = Data.define(:version, :ref, :deployer)
end
