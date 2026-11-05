# frozen_string_literal: true

require "test_helper"

# The feed is where the three ordering rules live: log before apply, both inside the lock, nothing
# else may mutate the engine. These tests pin the consequences.
#
# Feeds are built with `ticker: false` so nothing publishes in the background: each test drives
# #tick itself and asserts on exactly one frame.
class MarketFeedTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @instrument = instruments(:pit_usd)
    @feed = MarketFeed.new(@instrument, ticker: false)
    @entry = OrderEntry.new(@instrument, actor: "tester", feed: @feed)
  end

  def submit(attributes = {})
    @entry.submit({ side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: 5 }.merge(attributes))
  end

  def test_a_command_is_logged_before_it_reaches_the_engine
    result = submit(command_id: "log-me")

    record = Command.find_by!(instrument_id: @instrument.id, command_id: "log-me")

    assert_equal 1, record.position
    assert_equal "submit", record.kind
    assert_equal "tester", record.actor
    assert_equal({ "kind" => "submit", "id" => "log-me", "side" => "buy", "type" => "limit",
                   "tif" => "gtc", "price" => 10_000, "qty" => 5, "actor" => "tester" },
                 record.payload)
    assert_equal 1, result.position
    assert_equal 1, @feed.command_count
  end

  def test_positions_reflect_the_order_the_commands_arrived_in
    positions = Array.new(5) { |i| submit(command_id: "seq-#{i}", qty: 1).position }

    assert_equal [ 1, 2, 3, 4, 5 ], positions
    assert_equal [ 1, 2, 3, 4, 5 ], Command.where(instrument_id: @instrument.id).ordered.pluck(:position)
  end

  def test_a_duplicate_command_id_is_ignored_without_side_effects
    first = submit(command_id: "same-id")
    second = submit(command_id: "same-id")

    assert_equal false, first.duplicate
    assert_equal true, second.duplicate
    assert_empty second.events, "a duplicate must not produce events"
    assert_equal 1, Command.where(instrument_id: @instrument.id, command_id: "same-id").count
    assert_equal 1, @feed.snapshot["restingOrders"], "the duplicate did not rest a second order"
    assert_equal 5, @feed.actor_orders("tester").first["remaining"]
    assert_equal 1, @feed.command_count, "a duplicate must not consume a position"
  end

  # Regression: a duplicate that slipped past the idempotency check burned a position, and because
  # the counter was then rewound onto that same number, *every* later command collided with the
  # unique index and was answered as a duplicate. The market was wedged for good.
  def test_the_feed_keeps_taking_commands_after_duplicates
    %w[a-1 a-1 b-1 b-1 a-1].each { |id| submit(command_id: id) }

    assert_equal 2, Command.where(instrument_id: @instrument.id).count

    later = submit(command_id: "after-the-duplicates", price: 10_100)

    assert_equal false, later.duplicate
    assert_equal 3, later.position
    assert_equal 3, @feed.command_count
  end

  def test_warm_up_resumes_from_the_maximum_position_not_from_a_row_count
    # A log with a hole in it, exactly as a lost insert race leaves behind.
    [ 1, 2, 3, 5 ].each do |position|
      Command.create!(instrument_id: @instrument.id, position: position, kind: "submit",
                      actor: "tester", command_id: "warm-#{position}",
                      payload: { "kind" => "submit", "id" => "warm-#{position}", "side" => "buy",
                                 "type" => "limit", "tif" => "gtc", "price" => 9_900, "qty" => 1,
                                 "actor" => "tester" })
    end

    fresh = MarketFeed.new(@instrument, ticker: false)

    assert_equal 4, fresh.warm_up_commands
    assert_equal 5, fresh.command_count, "the counter must resume above the highest position"
    assert_equal 4, fresh.snapshot["restingOrders"]

    result = OrderEntry.new(@instrument, actor: "tester", feed: fresh)
                       .submit(side: "buy", type: "limit", tif: "gtc", price: 9_800, qty: 1,
                               command_id: "after-warm-up")

    assert_equal false, result.duplicate
    assert_equal 6, result.position
  end

  def test_a_checkpoint_is_captured_every_hundred_commands
    MarketFeed::CHECKPOINT_EVERY.times { |i| submit(command_id: "ck-#{i}", price: 9_800 + (i % 50)) }
    @feed.tick
    perform_enqueued_jobs

    checkpoint = BookCheckpoint.find_by!(instrument_id: @instrument.id,
                                         position: MarketFeed::CHECKPOINT_EVERY)

    assert_equal MarketFeed::CHECKPOINT_EVERY, checkpoint.position
    assert_equal @feed.fingerprint, checkpoint.fingerprint,
                 "the checkpoint must be the fingerprint the engine had at that command"
    assert_equal @feed.snapshot["restingOrders"], checkpoint.resting_orders
    assert_equal @feed.snapshot["bestBid"], checkpoint.best_bid
  end

  def test_the_tick_thread_hands_persistence_to_a_job
    MarketFeed::CHECKPOINT_EVERY.times { |i| submit(command_id: "async-#{i}", price: 9_700 + (i % 20)) }

    assert_equal 0, BookCheckpoint.where(instrument_id: @instrument.id).count

    assert_enqueued_jobs 1, only: PersistMarketEventsJob do
      @feed.tick
    end

    assert_equal 0, BookCheckpoint.where(instrument_id: @instrument.id).count,
                 "the tick enqueued the write; it did not do it"

    perform_enqueued_jobs
    assert_equal 1, BookCheckpoint.where(instrument_id: @instrument.id).count
  end

  def test_a_market_order_is_logged_with_a_null_price
    @entry.submit(side: "buy", type: "market", qty: 1, command_id: "mkt")

    assert_nil Command.find_by!(command_id: "mkt").payload["price"]
  end

  def test_statistics_expose_the_fingerprint_and_the_tick_budget
    submit(command_id: "stats-1")
    @feed.tick
    stats = @feed.stats

    assert_equal @instrument.symbol, stats[:symbol]
    assert_equal 1, stats[:commands]
    assert_equal 1, stats[:resting]
    assert_equal @feed.fingerprint, stats[:fingerprint]
    assert_operator stats[:tick_p50_ms], :>=, 0
    assert_equal 1, stats[:frames]
  end
end
