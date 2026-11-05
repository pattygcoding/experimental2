# frozen_string_literal: true

require_relative "../engine_test_helper"

# Self-trade prevention: the three policies, and the invariant that no policy may ever leave
# a crossed book behind.
class SelfTradeTest < Minitest::Test
  include EngineTestHelper

  def test_cancel_resting_cancels_our_own_order_and_keeps_matching
    engine = build_engine(self_trade: :cancel_resting)
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 4, actor: "me")
    submit(engine, id: "2", side: :sell, price: 10_000, qty: 4, actor: "someone-else")

    events = submit(engine, id: "3", side: :buy, price: 10_000, qty: 8, actor: "me")

    cancelled = events_named(events, :Cancelled).first
    assert_equal :self_trade, cancelled.reason
    assert_equal 4, cancelled.qty
    fills = events_named(events, :Fill)
    assert_equal [ "someone-else" ], fills.map(&:maker_actor)
    assert_equal 4, fills.sum(&:qty)
    assert_equal 4, engine.open_orders.first.remaining, "our own bid rested with the remainder"
    assert_consistent!(engine)
  end

  def test_skip_kills_the_takers_remainder_and_never_crosses_the_book
    engine = build_engine(self_trade: :skip)
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 4, actor: "me")

    events = submit(engine, id: "2", side: :buy, price: 10_000, qty: 10, actor: "me")

    assert_empty events_named(events, :Fill)
    killed = events_named(events, :Cancelled).first
    assert_equal :self_trade, killed.reason
    assert_equal 10, killed.qty
    assert_equal 10_000, engine.book.best_ask
    assert_nil engine.book.best_bid, "the blocked remainder must not rest inside our own ask"
    refute engine.book.crossed?
    assert_consistent!(engine)
  end

  def test_off_allows_a_self_trade
    engine = build_engine(self_trade: :off)
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 4, actor: "me")

    events = submit(engine, id: "2", side: :buy, price: 10_000, qty: 4, actor: "me")

    fill = events_named(events, :Fill).first
    assert_equal "me", fill.maker_actor
    assert_equal "me", fill.taker_actor
    assert_equal 0, engine.book.resting_count
    assert_consistent!(engine)
  end

  def test_a_fok_self_trade_does_not_partially_fill
    engine = build_engine(self_trade: :cancel_resting)
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 4, actor: "me")
    submit(engine, id: "2", side: :sell, price: 10_000, qty: 4, actor: "someone-else")

    events = submit(engine, id: "3", side: :buy, price: 10_000, qty: 12, tif: :fok, actor: "me")

    assert_equal :insufficient_liquidity, events_named(events, :Rejected).first.reason,
                 "only 4 of the 12 lots were ours to take, so the FOK is killed whole"
    assert_equal 8, engine.book.resting_qty(:sell), "neither resting order was touched"
    assert_consistent!(engine)
  end
end
