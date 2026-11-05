# frozen_string_literal: true

require "test_helper"

# Order entry is the boundary: untrusted input in, a validated engine command out. Market rules
# (tick, lot, liquidity, priority) belong to the engine — what is checked here is *shape*, and that
# the actor is never something the caller gets to choose.
class OrderEntryTest < ActiveSupport::TestCase
  setup do
    @instrument = instruments(:pit_usd)
    @feed = MarketFeed.new(@instrument, ticker: false)
    @entry = OrderEntry.new(@instrument, actor: "trusted", feed: @feed)
  end

  def test_a_well_formed_order_becomes_a_command_and_a_book
    result = @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: 5,
                           command_id: "ok-1")

    assert_equal false, result.duplicate
    assert_equal 10_000, @feed.snapshot["bestBid"]
    assert_equal [ "Accepted", "Rested" ],
                 result.events.map { |event| event.class.name.split("::").last }
  end

  def test_the_actor_comes_from_the_server_never_from_the_request
    @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: 5,
                  actor: "someone-else", command_id: "spoof")

    record = Command.find_by!(command_id: "spoof")

    assert_equal "trusted", record.actor
    assert_equal "trusted", record.payload["actor"]
    assert_equal 1, @feed.actor_orders("trusted").size
    assert_empty @feed.actor_orders("someone-else"), "the request cannot claim another trader's book"
  end

  def test_a_command_id_is_generated_when_the_form_does_not_supply_one
    first = @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: 1)
    second = @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: 1)

    assert_equal [ false, false ], [ first.duplicate, second.duplicate ]
    assert_equal 2, Command.where(instrument_id: @instrument.id).count
    assert_equal 2, Command.where(instrument_id: @instrument.id).distinct.count(:command_id)
  end

  def test_unknown_sides_types_and_tifs_are_refused_before_the_log
    [ [ "side", "sideways" ], [ "type", "stop" ], [ "tif", "forever" ] ].each do |field, value|
      error = assert_raises(OrderEntry::InvalidCommand) do
        @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: 1, command_id: "bad",
                      field.to_sym => value)
      end
      assert_match(/#{field}/, error.message)
    end

    assert_equal 0, Command.where(instrument_id: @instrument.id).count
    assert_equal 0, @feed.command_count
  end

  def test_non_numeric_prices_and_quantities_are_refused_before_the_log
    assert_raises(OrderEntry::InvalidCommand) do
      @entry.submit(side: "buy", type: "limit", tif: "gtc", price: "ten thousand", qty: 1)
    end
    assert_raises(OrderEntry::InvalidCommand) do
      @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: "1.5")
    end

    assert_equal 0, @feed.command_count
  end

  def test_a_market_order_does_not_require_a_price
    @entry.submit(side: "buy", type: "market", qty: 1, command_id: "mkt")

    assert_nil Command.find_by!(command_id: "mkt").payload["price"]
  end

  def test_a_limit_order_does_require_one
    assert_raises(OrderEntry::InvalidCommand) do
      @entry.submit(side: "buy", type: "limit", tif: "gtc", qty: 1)
    end
  end

  def test_market_rules_are_the_engines_job_and_surface_as_rejections
    valid = @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 10_000, qty: 1,
                          command_id: "fine")
    assert_equal 1, valid.position
    assert_equal [ :Accepted, :Rested ], event_names(valid.events)

    instrument = instruments(:pit_eur) # tick 5, lot 10
    entry = OrderEntry.new(instrument, actor: "trusted", feed: MarketFeed.new(instrument, ticker: false))

    off_tick = entry.submit(side: "buy", type: "limit", tif: "gtc", price: 1_003, qty: 20,
                            command_id: "off-tick")
    odd_lot = entry.submit(side: "buy", type: "limit", tif: "gtc", price: 1_005, qty: 15,
                           command_id: "odd-lot")

    assert_equal [ :invalid_price ], off_tick.events.map(&:reason),
                 "the engine decides tick and lot rules, not the form"
    assert_equal [ :invalid_lot_size ], odd_lot.events.map(&:reason)
  end

  def event_names(events)
    events.map { |event| event.class.name.split("::").last.to_sym }
  end

  def test_cancelling_an_unknown_order_is_a_rejection_not_a_crash
    result = @entry.cancel(9_999_999)

    assert_equal :unknown_order, result.events.first.reason
    assert_equal 1, @feed.command_count, "the attempt is still logged"
  end

  def test_amending_keeps_the_order_in_the_book
    @entry.submit(side: "buy", type: "limit", tif: "gtc", price: 9_900, qty: 5, command_id: "amend-me")
    order_id = @feed.actor_orders("trusted").first["orderId"]

    result = @entry.amend(order_id, price: 9_900, qty: 8)

    assert_equal "Amended", result.events.first.class.name.split("::").last
    assert_equal 8, @feed.actor_orders("trusted").first["qty"]
    assert_equal 8, @feed.snapshot["bids"].first[:qty]
  end

  def test_cancelling_removes_it_from_your_working_orders
    @entry.submit(side: "sell", type: "limit", tif: "gtc", price: 10_100, qty: 3, command_id: "cancel-me")
    order_id = @feed.actor_orders("trusted").first["orderId"]

    @entry.cancel(order_id)

    assert_empty @feed.actor_orders("trusted")
    assert_equal 0, @feed.snapshot["restingOrders"]
  end
end
