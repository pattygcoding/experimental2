# frozen_string_literal: true

require_relative "../engine_test_helper"

# The amend rules. The one that matters: changing the *quantity* at the same price keeps your
# place in the queue; changing the *price* sends you to the back.
class AmendTest < Minitest::Test
  include EngineTestHelper

  def test_amending_at_the_same_price_keeps_queue_priority
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 5, actor: "amended")
    submit(engine, id: "2", side: :sell, price: 10_000, qty: 5, actor: "behind")
    amended_id = engine.book.find_level(:sell, 10_000).head.id

    amended = events_named(amend(engine, id: "3", order_id: amended_id, price: 10_000, qty: 8), :Amended).first
    assert amended.kept_priority, "a same-price amendment keeps its place"

    fills = events_named(submit(engine, id: "4", side: :buy, price: 10_000, qty: 6, actor: "taker"), :Fill)
    assert_equal [ "amended" ], fills.map(&:maker_actor)
    assert_equal 2, engine.book.find_level(:sell, 10_000).head.remaining
    assert_consistent!(engine)
  end

  def test_changing_the_price_loses_queue_priority
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 5, actor: "was-first")
    submit(engine, id: "2", side: :sell, price: 10_000, qty: 5, actor: "behind")
    amended_id = engine.book.find_level(:sell, 10_000).head.id

    events = amend(engine, id: "3", order_id: amended_id, price: 10_002, qty: 5)
    assert_equal false, events_named(events, :Amended).first.kept_priority
    assert_equal 10_000, engine.book.best_ask, "the price change moved it to the back of the book"

    fills = events_named(submit(engine, id: "4", side: :buy, price: 10_002, qty: 2, actor: "taker"), :Fill)
    assert_equal [ "behind" ], fills.map(&:maker_actor)
    assert_consistent!(engine)
  end

  def test_an_amendment_into_the_market_trades_immediately
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 5, actor: "mm")
    submit(engine, id: "2", side: :buy, price: 9_900, qty: 5, actor: "bidder")
    bid_id = engine.book.best_bid_order.id

    events = amend(engine, id: "3", order_id: bid_id, price: 10_000, qty: 5)

    assert_equal [ 5 ], events_named(events, :Fill).map(&:qty)
    assert_equal 0, engine.book.resting_count
    assert_consistent!(engine)
  end

  def test_amending_below_the_filled_quantity_is_rejected
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 6, actor: "mm")
    submit(engine, id: "2", side: :buy, price: 10_000, qty: 10, actor: "bidder")

    order = engine.open_orders.first
    assert_equal 6, order.filled
    assert_equal 4, order.remaining

    events = amend(engine, id: "3", order_id: order.id, price: 10_000, qty: 5)

    assert_equal :below_filled, events_named(events, :Rejected).first.reason
    assert_equal 4, order.remaining, "a rejected amendment leaves the order alone"
    assert_consistent!(engine)
  end

  def test_amending_a_cancelled_order_is_rejected
    engine = build_engine
    submit(engine, id: "1", side: :buy, price: 9_900, qty: 5, actor: "mm")
    id = engine.open_orders.first.id
    cancel(engine, id: "2", order_id: id)

    events = amend(engine, id: "3", order_id: id, price: 9_905, qty: 5)
    assert_equal :not_open, events_named(events, :Rejected).first.reason
    assert_equal 0, engine.book.resting_count
    assert_consistent!(engine)
  end

  def test_off_tick_amendments_are_rejected
    engine = build_engine(tick_size: 5)
    submit(engine, id: "1", side: :buy, price: 9_900, qty: 5, actor: "mm")
    id = engine.open_orders.first.id

    events = amend(engine, id: "2", order_id: id, price: 9_901, qty: 5)
    assert_equal :invalid_price, events_named(events, :Rejected).first.reason
    assert_equal 9_900, engine.book.best_bid
    assert_consistent!(engine)
  end
end
