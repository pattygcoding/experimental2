# frozen_string_literal: true

# A deterministic market participant, so the book is alive the moment you open the page.
#
# It submits through the same OrderEntry path as a human, which means its orders are in the
# write-ahead log too: a replay includes the bot's activity, and a live market and a replayed
# market agree on their fingerprint.
#
# Honest note on determinism: the bot is seeded, so a fresh market with only the bot in it is
# reproducible from `instruments.seed`. As soon as a human clicks, the *future* is no longer
# predictable — but the *past* still is, which is the property that matters here.
class SyntheticFlow
  BURST_INTERVAL = 0.25
  ACTORS = %w[synthetic-alpha synthetic-beta synthetic-gamma].freeze

  def initialize(feed, instrument)
    @feed = feed
    @instrument = instrument
    @prng = PIT::Fuzz.new(seed: instrument.seed, tick: instrument.tick_size, lot: instrument.lot_size)
    @entries = {}
    @rate = instrument.synthetic_rate.clamp(1, 50)
    @submitted = 0
    @rejected = 0
    @running = false
    @thread = nil
  end

  def start
    @running = true
    @thread = Thread.new { run }
    @thread.name = "pit-synthetic-#{@instrument.symbol}"
    @thread.abort_on_exception = false
    self
  end

  def stop
    @running = false
    thread = @thread
    @thread = nil
    thread&.wakeup
    thread&.join(2)
  end

  def running? = @running

  def stats
    { rate: @rate, submitted: @submitted, rejected: @rejected, running: @running }
  end

  private

  def run
    per_burst = [ (@rate * BURST_INTERVAL).round, 1 ].max

    while @running
      sleep BURST_INTERVAL
      per_burst.times { submit_one } if @running
    end
  rescue StandardError => e
    Rails.logger.error("[pit] synthetic flow for #{@instrument.symbol} died: #{e.class}: #{e.message}")
    @running = false
  end

  # The engine state is read through the feed, so the bot only ever sees a consistent book.
  #
  # Each bot command carries its own actor (PIT::Fuzz picks between several), and each actor gets
  # its own OrderEntry — so the synthetic market is a market with several participants in it, not
  # one participant crossing itself. An order may have been filled by the time a command lands:
  # the engine then rejects it with `unknown_order`, which is correct — and counted here.
  def submit_one
    command = @prng.command(@feed.engine_view)
    entry_for(command.actor).admit(command, id: "#{@feed.boot_token}-#{command.id}")
    @submitted += 1
  rescue StandardError
    @rejected += 1
  end

  def entry_for(actor)
    @entries[actor] ||= OrderEntry.new(@instrument, actor: actor, feed: @feed)
  end
end
