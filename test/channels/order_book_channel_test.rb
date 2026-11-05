# frozen_string_literal: true

require "test_helper"

# The socket is one-way: it carries state down and nothing else. These tests pin the frames a
# browser gets on connect, and the streams it is attached to.
class OrderBookChannelTest < ActionCable::Channel::TestCase
  tests OrderBookChannel

  setup do
    @instrument = instruments(:pit_usd)
    stub_connection trader: "trader-under-test"
  end

  test "subscribing streams the market and the trader's own book" do
    subscribe symbol: @instrument.symbol

    assert_has_stream "pit:market:#{@instrument.symbol}"
    assert_has_stream "pit:actor:trader-under-test"
  end

  test "the first paint arrives immediately, it does not wait for a tick" do
    subscribe symbol: @instrument.symbol

    types = transmissions.map { |frame| frame["type"] }

    assert_equal %w[snapshot yourOrders hello], types
    snapshot = transmissions.first
    assert_equal @instrument.symbol, snapshot["symbol"]
    assert_equal MarketFeed::SNAPSHOT_HZ, snapshot["tickRate"]
    assert_includes snapshot.keys, "stateHash",
                    "the tick ships the O(1) rolling hash; the full fingerprint is a REST read"
    assert_equal [], snapshot["bids"]
    assert_equal [], transmissions.second["orders"]
  end

  test "the hello frame tells the browser who it is" do
    subscribe symbol: @instrument.symbol

    hello = transmissions.last
    assert_equal "trader-under-test", hello["trader"]
    assert_equal @instrument.symbol, hello["symbol"]
  end

  test "a symbol that does not exist is rejected" do
    subscribe symbol: "NOPE-USD"

    assert subscription.rejected?
    assert_no_streams
  end

  test "the symbol is case insensitive" do
    subscribe symbol: @instrument.symbol.downcase

    assert_has_stream "pit:market:#{@instrument.symbol}"
  end

  test "a tick broadcasts exactly one snapshot frame to the market stream" do
    feed = MarketFeed.new(@instrument, ticker: false)
    feed.apply(PIT::Commands.submit(id: "c1", side: :buy, price: 9_999, qty: 3, actor: "someone"))

    payloads = capture_broadcasts("pit:market:#{@instrument.symbol}") { feed.tick }

    snapshots = payloads.select { |frame| frame["type"] == "snapshot" }
    events = payloads.select { |frame| frame["type"] == "events" }

    assert_equal 1, snapshots.size, "one snapshot per tick, no matter how busy the market was"
    assert_equal 1, events.size
    assert_equal 9_999, snapshots.first["bestBid"]
    assert_equal 1, snapshots.first["restingOrders"]
    assert_equal %w[accepted rested], events.first["events"].map { |event| event["type"] }
  end

  test "orders placed by one trader are pushed to that trader's stream only" do
    feed = MarketFeed.new(@instrument, ticker: false)
    feed.apply(PIT::Commands.submit(id: "c1", side: :buy, price: 9_999, qty: 3, actor: "someone-else"))

    # A tick drains the pending events, so the two streams have to be inspected around one tick.
    theirs = capture_broadcasts("pit:actor:someone-else") { feed.tick }

    assert_equal 1, theirs.size
    assert_equal "yourOrders", theirs.first["type"]
    assert_equal 1, theirs.first["orders"].size
    assert_empty broadcasts("pit:actor:trader-under-test"),
                 "this trader never traded, so nothing was ever pushed to their stream"
  end
end
