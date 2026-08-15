# spec/fixtures/plugins/fake_sail.rb
# Really required by plugins_spec via $LOAD_PATH, so the spec proves a gem's
# registration side effect actually happens. Stubbing Kernel#require would only
# assert that the stub was called.

Odysseus::Sails.register(:fake, Class.new)
