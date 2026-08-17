# lib/odysseus/deploy_version.rb

module Odysseus
  # The identity of one deploy: the image tag, plus where it came from.
  # ref is nil when the version was given explicitly, because an arbitrary tag
  # says nothing about a commit. deployer is still known in that case — it
  # never depended on the tag identifying a commit.
  DeployVersion = Data.define(:version, :ref, :deployer)
end
