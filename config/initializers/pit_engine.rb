# frozen_string_literal: true

# The matching engine is plain Ruby and is deliberately NOT autoloaded or reloadable (see
# config/application.rb). It is required exactly once, at boot.
#
# Why: a reload mid-match would replace PIT::Engine's class while MarketFeed is holding an
# instance of it, and a matching engine is not something you want hot-swapped under a live book.
# Engine changes should be deliberate, and the engine test suite (`bin/rails test:engine`) is how
# you find out whether they were safe.
require Rails.root.join("lib/pit").to_s

# Stop the feeds on exit. Without this, a `bin/rails runner` or a Ctrl-C'd server can leave a
# ticker thread holding the SQLite file open — which on Windows means `db:drop`/`db:reset` fail with
# a permission error, and eventually means writing to a database nobody is reading.
at_exit do
  EngineRegistry.reset!
rescue StandardError => e
  Rails.logger.error("[pit] failed to stop feeds on exit: #{e.class}: #{e.message}") if defined?(Rails.logger)
end
