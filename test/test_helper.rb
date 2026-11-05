ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # The engines live in the process, not in the database, so they outlive each test's
    # transaction. Reset them between tests or one test's book leaks into the next.
    #
    # Runs single-threaded on purpose: PIT has a process-wide registry of live markets
    # (EngineRegistry), which is exactly the kind of shared state that parallel tests break.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Callback form on purpose. `def setup` would *override* ActiveSupport::TestCase#setup, and
    # callbacks registered here run before a subclass's own `setup do` block — so a test class that
    # installs its fixtures/markets in a setup block is never reset out from under itself.
    setup do
      EngineRegistry.reset!
    end

    teardown do
      EngineRegistry.reset!
    end
  end
end
