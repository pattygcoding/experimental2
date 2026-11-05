# frozen_string_literal: true

require_relative "../engine_test_helper"

# The core suite: the properties the whole design depends on. If one of these goes red, the
# engine's contract moved — read AGENTS.md before "fixing" it.
class EngineTest < Minitest::Test
  include EngineTestHelper

  # ── price priority ────────────────────────────────────────────────────────────────

  def test_fills_print_at_the_makers_price_not_the_takers
    engine = build_engine
    submit(engine, id: "rest-1", side: :sell, price: 10_000, qty: 5, actor: "mm")
    submit(engine, id: "rest-2", side: :sell, price: 9_999, qty: 5, actor: "mm")
    assert_equal 9_999, engine.book.best_ask, "the better ask must be at the top of the ladder"

    events = submit(engine, id: "taker", side: :buy, price: 10_100, qty: 5, actor: "taker")
    fill = events_named(events, :Fill).first

    assert_equal 9_999, fill.price, "the taker got price improvement; the print is the maker's price"
    assert_equal 5, fill.qty
    assert_equal :buy, fill.aggressor
    assert_equal "mm", fill.maker_actor
    assert_equal 10_000, engine.book.best_ask, "the untouched ask is still resting"
    assert_consistent!(engine)
  end

  def test_arrival_order_decides_who_trades_first_at_the_same_price
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 3, actor: "first")
    submit(engine, id: "2", side: :sell, price: 10_000, qty: 3, actor: "second")

    fills = events_named(submit(engine, id: "3", side: :buy, price: 10_000, qty: 4, actor: "taker"), :Fill)

    assert_equal %w[first second], fills.map(&:maker_actor)
    assert_equal [ 3, 1 ], fills.map(&:qty)
    assert_consistent!(engine)
  end

  def test_a_partially_filled_order_keeps_its_place_in_the_queue
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 10, actor: "head")
    submit(engine, id: "2", side: :sell, price: 10_000, qty: 10, actor: "tail")

    submit(engine, id: "3", side: :buy, price: 10_000, qty: 4, actor: "taker")
    fills = events_named(submit(engine, id: "4", side: :buy, price: 10_000, qty: 4, actor: "taker"), :Fill)

    assert_equal [ "head" ], fills.map(&:maker_actor), "the price level head stays at the head"
    assert_equal 2, engine.book.find_level(:sell, 10_000).head.remaining
    assert_consistent!(engine)
  end

  def test_an_order_that_cannot_trade_rests_and_is_announced
    engine = build_engine
    events = submit(engine, id: "1", side: :buy, price: 9_900, qty: 7, actor: "mm")

    assert_equal %w[Accepted Rested], event_names(events)
    assert_equal 7, events_named(events, :Rested).first.qty
    assert_equal 9_900, engine.book.best_bid
    assert_nil engine.book.best_ask
    assert_consistent!(engine)
  end

  def test_cancelling_removes_exactly_the_remainder
    engine = build_engine
    submit(engine, id: "1", side: :buy, price: 9_900, qty: 7, actor: "mm")
    order_id = engine.open_orders.first.id

    cancelled = events_named(cancel(engine, id: "2", order_id: order_id), :Cancelled).first

    assert_equal 7, cancelled.qty
    assert_equal :requested, cancelled.reason
    assert_equal 0, engine.book.resting_count
    assert_nil engine.book.best_bid
    assert_consistent!(engine)
  end

  # ── validation: a bad command never touches the book ──────────────────────────────

  def test_off_tick_odd_lot_and_impossible_orders_are_rejected
    engine = build_engine(tick_size: 5, lot_size: 10)

    reasons = [
      submit(engine, id: "1", side: :buy, price: 1_003, qty: 10),   # off-tick
      submit(engine, id: "2", side: :buy, price: 1_005, qty: 15),   # odd lot
      submit(engine, id: "3", side: :buy, price: 1_005, qty: 0),    # nothing to trade
      submit(engine, id: "4", side: :buy, price: -1_005, qty: 10),  # impossible
      cancel(engine, id: "5", order_id: 99_999),                    # unknown order
      amend(engine, id: "6", order_id: 99_999, price: 1_005, qty: 10)
    ].map { |events| events_named(events, :Rejected).first.reason }

    assert_equal %i[invalid_price invalid_lot_size invalid_lot_size invalid_price
                    unknown_order unknown_order], reasons
    assert_equal 0, engine.book.resting_count
    assert_equal 0, engine.seq, "a rejected command must not consume a sequence number"
    assert_consistent!(engine)
  end

  def test_a_market_order_may_not_carry_a_price
    engine = build_engine
    events = submit(engine, id: "1", side: :buy, qty: 5, price: 10_000, type: :market)
    assert_equal :invalid_price, events_named(events, :Rejected).first.reason
  end
  # ── determinism: the property everything else leans on ────────────────────────────

  def test_the_same_command_stream_always_produces_the_same_fingerprint
    first = build_engine
    second = build_engine

    seeded_commands(seed: 2024, count: 300, engine: first)
    seeded_commands(seed: 2024, count: 300, engine: second)

    assert_equal first.fingerprint, second.fingerprint
    assert_equal first.book.resting_count, second.book.resting_count
    assert_equal first.counters[:fills], second.counters[:fills]
    assert_consistent!(first)
  end

  def test_different_seeds_produce_different_books
    first = build_engine
    second = build_engine

    seeded_commands(seed: 1, count: 200, engine: first)
    seeded_commands(seed: 2, count: 200, engine: second)

    refute_equal first.fingerprint, second.fingerprint
  end

  def test_configuration_is_part_of_the_fingerprint
    coarse = build_engine(tick_size: 10)
    fine = build_engine(tick_size: 1)

    [ coarse, fine ].each { |engine| submit(engine, id: "1", side: :buy, price: 1_000, qty: 1) }

    refute_equal coarse.fingerprint, fine.fingerprint,
                 "engines with different tick sizes must never agree on a fingerprint"
  end

  def test_quantity_is_conserved_across_a_crossing
    engine = build_engine
    submit(engine, id: "1", side: :sell, price: 10_000, qty: 12, actor: "mm")
    submit(engine, id: "2", side: :sell, price: 10_001, qty: 8, actor: "mm")
    resting_before = engine.book.resting_qty(:sell)

    fills = events_named(submit(engine, id: "3", side: :buy, price: 10_001, qty: 15, actor: "taker"), :Fill)

    assert_equal 15, fills.sum(&:qty)
    assert_equal resting_before - fills.sum(&:qty), engine.book.resting_qty(:sell),
                 "every traded lot must have left the resting book"
    assert_equal 5, engine.book.resting_qty(:sell), "the untouched 5 lots of the second ask remain"
    assert_consistent!(engine)
  end

  def test_the_prng_stream_is_stable_and_bounded
    assert_equal PIT::Prng.new(7).next_u64, PIT::Prng.new(7).next_u64
    refute_equal PIT::Prng.new(7).next_u64, PIT::Prng.new(8).next_u64
    assert_includes 10..20, PIT::Prng.new(99).between(10, 20)
    assert_equal 0, PIT::Prng.new(1).int(1)
  end
end
