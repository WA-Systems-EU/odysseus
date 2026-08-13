# lib/odysseus/retention_plan.rb

module Odysseus
  # What retention decided for one host.
  #
  # remove  versions whose images should be deleted, **oldest first**, so a
  #         partial failure leaves the newest behind
  # keep    versions retained, newest first — reported so an operator can see
  #         what the window covers without re-deriving it
  #
  # Both hold versions, not image references; the caller pairs them with the
  # configured image name.
  RetentionPlan = Data.define(:remove, :keep)
end
