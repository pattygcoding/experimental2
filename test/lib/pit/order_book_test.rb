# frozen_string_literal: true

require_relative "../engine_test_helper"

# The ladder itself: binary-search insertion, depth aggregation, and the ordering that price
# priority depends on.
class OrderBookTest < Minitest::Test
  include EngineTestHelper

  def test_bids_sort_descending_and_asks_ascending
    engine = build_engine
    [ 9_995, 9_990, 9_999, 9_997 ].each_with_index do |price, index|
      submit(engine, id: "b#{index}", side: :buy, price: price, qty: 1)
    end
    [ 10_005, 10_010, 10_001, 10_003 ].each_with_index do |price, index|
      submit(engine, id: "a#{index}", side: :sell, price: price, qty: 1)
    end

    assert_equal [ 9_999, 9_997, 9_995, 9_990 ], engine.book.bids.map(&:price)
    assert_equal [ 10_001, 10_003, 10_005, 10_010 ], engine.book.asks.map(&:price)
    assert_consistent!(engine)
  end

  def test_orders_at_the_same_price_share_one_level
    engine = build_engine
    3.times { |i| submit(engine, id: "x#{i}", side: :buy, price: 9_999, qty: 2) }

    assert_equal 1, engine.book.bids.size
    assert_equal 3, engine.book.bids.first.size
    assert_equal 6, engine.book.bids.first.qty
    assert_consistent!(engine)
  end

  def test_depth_aggregates_cumulative_quantity
    engine = build_engine
    submit(engine, id: "1", side: :buy, price: 9_999, qty: 4)
    submit(engine, id: "2", side: :buy, price: 9_998, qty: 6)
    submit(engine, id: "3", side: :buy, price: 9_997, qty: 5)

    depth = engine.book.depth(:buy, 3)

    assert_equal [ 9_999, 9_998, 9_997 ], depth.map { |row| row[:price] }
    assert_equal [ 4, 10, 15 ], depth.map { |row| row[:cumulative] }
    assert_equal [ 1, 1, 1 ], depth.map { |row| row[:orders] }
  end

  def test_depth_is_limited_to_the_requested_levels
    engine = build_engine
    20.times { |i| submit(engine, id: "o#{i}", side: :sell, price: 10_000 + i, qty: 1) }

    assert_equal 5, engine.book.depth(:sell, 5).size
    assert_equal 20, engine.book.resting_count
  end

  def test_emptying_a_level_removes_it_from_the_ladder
    engine = build_engine
    submit(engine, id: "1", side: :buy, price: 9_999, qty: 5)
    id = engine.book.best_bid_order.id

    cancel(engine, id: "2", order_id: id)

    assert_empty engine.book.bids
    assert_nil engine.book.best_bid
    assert_nil engine.book.spread
    assert_nil engine.book.mid
    assert_consistent!(engine)
  end

  def test_spread_and_mid_come_from_the_touch
    engine = build_engine
    submit(engine, id: "1", side: :buy, price: 9_998, qty: 1)
    submit(engine, id: "2", side: :sell, price: 10_002, qty: 1)

    assert_equal 4, engine.book.spread
    assert_equal 10_000, engine.book.mid
    refute engine.book.crossed?
  end

  def test_the_tape_keeps_the_most_recent_fills
    engine = build_engine
    300.times do |i|
      submit(engine, id: "s#{i}", side: :sell, price: 10_000, qty: 1, actor: "mm")
      submit(engine, id: "b#{i}", side: :buy, price: 10_000, qty: 1, actor: "taker")
    end

    assert_equal PIT::Engine::TAPE_LIMIT, engine.tape(1_000).size
    assert_equal 300, engine.trade_seq
    assert_equal 300, engine.counters[:fills]
    assert_consistent!(engine)
  end
end
