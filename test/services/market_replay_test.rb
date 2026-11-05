# frozen_string_literal: true

require "test_helper"

# Time travel. These are the tests that back the headline claim: the database stores commands, the
# book is derived, and a rebuild can be *proved* to have reproduced recorded history.
class MarketReplayTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @instrument = instruments(:pit_usd)
    @feed = MarketFeed.new(@instrument, ticker: false)
    @buyer = OrderEntry.new(@instrument, actor: "buyer", feed: @feed)
    @seller = OrderEntry.new(@instrument, actor: "seller", feed: @feed)
  end

  # Pairs of crossing orders, so the log contains fills, rests and cancellations, not just rests.
  def drive(rounds)
    rounds.times do |i|
      @buyer.submit(side: "buy", type: "limit", tif: "gtc", price: 9_900 + (i % 25), qty: 1,
                    command_id: "buy-#{i}")
      @seller.submit(side: "sell", type: "limit", tif: "gtc", price: 10_100 - (i % 25), qty: 1,
                     command_id: "sell-#{i}")
    end
    @feed.tick
    perform_enqueued_jobs
  end

  def test_a_replay_reproduces_the_live_book_exactly
    drive(10)

    replay = MarketReplay.at(@instrument)

    assert_equal @feed.command_count, replay.commands
    assert_equal @feed.fingerprint, replay.fingerprint
    assert_equal @feed.snapshot["bestBid"], replay.snapshot["bestBid"]
    assert_equal @feed.snapshot["bestAsk"], replay.snapshot["bestAsk"]
    assert_equal @feed.snapshot["restingOrders"], replay.snapshot["restingOrders"]
    assert_operator replay.events, :>, 0
  end

  def test_checkpoints_recorded_live_verify_against_the_replay
    drive(60) # 120 commands ⇒ at least one checkpoint, every 100 commands

    replay = MarketReplay.at(@instrument)

    assert_operator replay.verified_checkpoints, :>=, 1, "a checkpoint should have been captured"
    assert_empty replay.mismatches
    assert replay.faithful?
  end

  def test_replaying_to_a_checkpoint_reproduces_that_exact_book
    drive(60)

    checkpoint = BookCheckpoint.where(instrument_id: @instrument.id).ordered.first
    assert checkpoint, "the drive should have produced a checkpoint"

    history = MarketReplay.at(@instrument, upto: checkpoint.position)

    assert_equal checkpoint.position, history.commands
    assert_equal checkpoint.fingerprint, history.fingerprint,
                 "the book at command N *is* the fingerprint recorded at command N"
    assert_equal checkpoint.best_bid, history.snapshot["bestBid"]
    assert_equal checkpoint.best_ask, history.snapshot["bestAsk"]
  end

  def test_a_tampered_log_cannot_pretend_to_be_history
    drive(60)
    healthy = MarketReplay.at(@instrument)
    assert healthy.faithful?

    # Someone edits the log — a classic "just fix the recorded price" move.
    Command.where(instrument_id: @instrument.id).ordered.second
           .update_columns(payload: { "kind" => "submit", "id" => "tampered", "side" => "buy",
                                      "type" => "limit", "tif" => "gtc", "price" => 7_777,
                                      "qty" => 99, "actor" => "buyer" })

    tampered = MarketReplay.at(@instrument)

    refute_equal healthy.fingerprint, tampered.fingerprint
    refute tampered.faithful?, "a rewritten log must fail its own checkpoints"
    assert_operator tampered.mismatches.size, :>=, 1
  end

  def test_a_short_session_has_nothing_to_verify_yet
    drive(5) # 10 commands, and a checkpoint is captured every 100
    replay = MarketReplay.at(@instrument)

    assert_equal 0, replay.verified_checkpoints
    assert replay.faithful?, "nothing to disagree with is not the same as disagreeing"
    assert_operator replay.duration_ms, :>=, 0
  end

  def test_the_api_payload_carries_the_receipts
    drive(5)
    payload = MarketReplay.payload(@instrument)

    assert_equal @instrument.symbol, payload["symbol"]
    assert payload["faithful"]
    assert_equal 10, payload["replayedCommands"]
    assert_operator payload["replayedEvents"], :>, 0
    assert_operator payload["replayMs"], :>=, 0
    assert_equal [], payload["mismatches"]
  end
end
