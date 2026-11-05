# frozen_string_literal: true

# Process-wide registry of live markets: one MarketFeed per instrument.
#
# In-process, like HEXARENA's MatchCoordinator. The consequence is worth stating plainly: two
# Puma workers would each own their own book. Scaling that out is the roadmap item in
# AGENTS.md — the durable log already makes it tractable, because a second process can rebuild
# the book from `commands` and take over.
module EngineRegistry
  @feeds = {}
  @feeds_mutex = Mutex.new

  class << self
    def feed_for(instrument)
      # Create under the lock, but *start* outside it: starting a feed may build services that
      # need to look the feed up again, and a Mutex is not reentrant.
      feed = @feeds_mutex.synchronize { @feeds[instrument.id] ||= MarketFeed.new(instrument) }
      feed.start
      feed
    end

    # Every feed this process knows about, started or not.
    def feeds
      @feeds_mutex.synchronize { @feeds.values }
    end

    def warm_up!(instrument)
      feed_for(instrument).warm_up!
    end

    # Tests and the console need a way to drop in-memory state: the engines must never outlive
    # the rows whose transactions were rolled back.
    def reset!
      @feeds_mutex.synchronize do
        @feeds.each_value(&:stop)
        @feeds.clear
      end
    end
  end
end
