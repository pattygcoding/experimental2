# frozen_string_literal: true

require_relative "../engine_test_helper"

# Time-in-force and market orders: what happens to the part of an order that did not trade.
class TifTest < Minitest::Test
  include EngineTestHelper

  def test_ioc_fills_what_it_can_and_kills_the_rest
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 5, actor: "mm")

    events = submit(engine, id: "2", side: :buy, price: 10_000, qty: 9, tif: :ioc, actor: "taker")

    assert_equal [ 5 ], events_named(events, :Fill).map(&:qty)
    killed = events_named(events, :Cancelled).first
    assert_equal 4, killed.qty
    assert_equal :ioc, killed.reason
    assert_equal 0, engine.book.resting_count, "an IOC order must never rest"
    assert_consistent!(engine)
  end

  def test_ioc_with_no_liquidity_is_killed_without_touching_the_book
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 5, actor: "mm")

    events = submit(engine, id: "2", side: :buy, price: 9_000, qty: 5, tif: :ioc, actor: "taker")

    assert_equal :ioc, events_named(events, :Cancelled).first.reason
    assert_equal 5, engine.book.resting_qty(:sell)
    assert_equal 1, engine.book.resting_count
    assert_consistent!(engine)
  end

  def test_fok_is_all_or_nothing
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 5, actor: "mm")

    events = submit(engine, id: "2", side: :buy, price: 10_000, qty: 6, tif: :fok, actor: "taker")

    rejected = events_named(events, :Rejected).first
    assert_equal :insufficient_liquidity, rejected.reason
    assert_empty events_named(events, :Fill), "a rejected FOK must not trade at all"
    assert_equal 5, engine.book.resting_qty(:sell), "the book is untouched by a killed FOK"
    assert_consistent!(engine)
  end

  def test_fok_fills_completely_when_the_liquidity_is_there
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 4, actor: "mm-a")
    submit(engine, id: "2", side: :sell, price: 10_001, qty: 4, actor: "mm-b")

    events = submit(engine, id: "3", side: :buy, price: 10_001, qty: 8, tif: :fok, actor: "taker")

    assert_equal [ 4, 4 ], events_named(events, :Fill).map(&:qty)
    assert_equal [ 10_000, 10_001 ], events_named(events, :Fill).map(&:price)
    assert_equal 0, engine.book.resting_count
    assert_consistent!(engine)
  end

  def test_market_orders_walk_the_ladder_and_kill_the_remainder
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 3, actor: "mm-a")
    submit(engine, id: "2", side: :sell, price: 10_005, qty: 3, actor: "mm-b")

    events = submit(engine, id: "3", side: :buy, qty: 10, type: :market, actor: "taker")

    fills = events_named(events, :Fill)
    assert_equal [ 3, 3 ], fills.map(&:qty)
    assert_equal [ 10_000, 10_005 ], fills.map(&:price)
    killed = events_named(events, :Cancelled).first
    assert_equal 4, killed.qty
    assert_equal :no_liquidity, killed.reason
    assert_equal 0, engine.book.resting_count
    assert_consistent!(engine)
  end

  def test_a_market_order_into_an_empty_book_is_simply_cancelled
    engine = build_engine
    events = submit(engine, id: "1", side: :buy, qty: 5, type: :market, actor: "taker")

    assert_equal [ :no_liquidity ], events_named(events, :Cancelled).map(&:reason)
    assert_equal 0, engine.book.resting_count
    assert_consistent!(engine)
  end

  def test_a_gtc_order_with_no_liquidity_rests
    engine = build_engine
    events = submit(engine, id: "1", side: :buy, price: 9_995, qty: 5, tif: :gtc, actor: "mm")

    assert_equal 1, events_named(events, :Rested).size
    assert_equal 1, engine.book.resting_count
    assert_consistent!(engine)
  end
end
