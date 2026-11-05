# frozen_string_literal: true

require_relative "../engine_test_helper"

# Who is allowed to touch an order.
#
# This suite exists because of a real bug: the actor on a Cancel or Amend command was never compared
# with the order's actor, so the synthetic flow spent its time amending and cancelling orders other
# traders had placed — and nothing failed, because every book invariant still held.
class OwnershipTest < Minitest::Test
  include EngineTestHelper

  def setup
    @engine = build_engine
    submit(@engine, id: "1", side: :buy, price: 9_900, qty: 5, actor: "owner")
    @order_id = @engine.open_orders.first.id
  end

  def test_an_actor_can_cancel_their_own_order
    events = cancel(@engine, id: "2", order_id: @order_id, actor: "owner")

    assert_equal :requested, events_named(events, :Cancelled).first.reason
    assert_equal 0, @engine.book.resting_count
  end

  def test_another_actor_cannot_cancel_your_order
    events = cancel(@engine, id: "2", order_id: @order_id, actor: "stranger")

    assert_equal :unknown_order, events_named(events, :Rejected).first.reason
    assert_equal 5, @engine.book.resting_qty(:buy), "the order is untouched"
    assert_consistent!(@engine)
  end

  def test_another_actor_cannot_amend_your_order
    events = amend(@engine, id: "2", order_id: @order_id, price: 8_000, qty: 1, actor: "stranger")

    assert_equal :unknown_order, events_named(events, :Rejected).first.reason
    assert_equal 9_900, @engine.book.best_bid, "the price is untouched"
    assert_equal 5, @engine.book.resting_qty(:buy)
    assert_consistent!(@engine)
  end

  # A stranger gets the same answer as for an id that never existed: the engine must not confirm that
  # another trader's order is out there.
  def test_a_foreign_order_is_indistinguishable_from_an_unknown_one
    foreign = cancel(@engine, id: "1", order_id: @order_id, actor: "stranger")
    missing = cancel(@engine, id: "2", order_id: 999_999, actor: "stranger")

    assert_equal events_named(missing, :Rejected).first.reason, events_named(foreign, :Rejected).first.reason
  end

  def test_the_owner_can_still_act_after_a_stranger_was_refused
    cancel(@engine, id: "1", order_id: @order_id, actor: "stranger")
    events = amend(@engine, id: "2", order_id: @order_id, price: 9_900, qty: 9, actor: "owner")

    assert_equal true, events_named(events, :Amended).first.kept_priority
    assert_equal 9, @engine.book.resting_qty(:buy)
  end

  def test_a_fuzzed_market_never_touches_a_stranger_s_order
    engine = build_engine
    fuzz = PIT::Fuzz.new(seed: 31337)

    fuzz.each(engine, 400) do |command|
      order = engine.order(command.order_id) if command.respond_to?(:order_id)
      engine.apply(command)
      next unless order

      assert_equal order.actor, command.actor,
                   "the fuzzer must address an order as the actor that owns it"
    end

    assert_consistent!(engine)
  end
end
