# frozen_string_literal: true

module PIT
  class InvariantViolation < StandardError; end

  # The properties the engine must never break, checked as a unit after *every* command in
  # the fuzz test. If a matching rule change breaks one of these, the suite says which and
  # where — which is the entire reason this module exists.
  #
  #   1. no crossed book                  best_bid < best_ask
  #   2. ladder ordering                  bids strictly descending, asks strictly ascending
  #   3. no empty level left behind
  #   4. FIFO within a level              arrival (seq) ascending
  #   5. every resting order is open      status == :open
  #   6. every resting order has qty      remaining > 0
  #   7. orders rest on their own side    order.side == ladder side
  #   8. orders rest at their level       order.price == level.price, tick-aligned
  #   9. no order is resting twice
  #  10. resting orders are registered    engine.orders[id] is the same object
  #  11. nothing open is missing          every open order is in the book
  #  12. bookkeeping adds up              level.qty == sum(remaining), counts match
  #  13. sequences are monotonic          engine.seq >= every order's seq
  #  14. the actor hash is honest         order.actor_hash == fold(order.actor)
  module Invariants
    module_function

    def assert_consistent!(engine)
      check_not_crossed(engine.book)
      check_ladder(engine, :buy)
      check_ladder(engine, :sell)
      check_open_orders_are_resting(engine)
      check_totals(engine)
      true
    end

    def check_not_crossed(book)
      return unless book.crossed?

      raise InvariantViolation, "book is crossed: best_bid=#{book.best_bid} best_ask=#{book.best_ask}"
    end

    def check_ladder(engine, side)
      previous_price = nil
      seen = {}

      engine.book.ladder(side).each do |level|
        if level.empty?
          raise InvariantViolation, "empty price level #{level.price} left on the #{side} ladder"
        end

        if previous_price
          out_of_order = side == :buy ? level.price >= previous_price : level.price <= previous_price
          if out_of_order
            raise InvariantViolation,
                  "#{side} ladder out of order: #{level.price} follows #{previous_price}"
          end
        end

        expected_qty = level.orders.sum(&:remaining)
        unless level.qty == expected_qty
          raise InvariantViolation,
                "level #{level.price} carries qty=#{level.qty} but its orders sum to #{expected_qty}"
        end

        seqs = level.orders.map(&:seq)
        unless seqs == seqs.sort
          raise InvariantViolation, "level #{level.price} is not FIFO by arrival: seqs=#{seqs.inspect}"
        end

        level.each do |order|
          check_resting_order(engine, order, side, level, seen)
        end

        previous_price = level.price
      end
    end

    def check_resting_order(engine, order, side, level, seen)
      unless order.open?
        raise InvariantViolation, "order #{order.id} is #{order.status} but still resting at #{order.price}"
      end

      unless order.remaining.positive?
        raise InvariantViolation, "order #{order.id} rests with remaining=#{order.remaining}"
      end

      unless order.side == side
        raise InvariantViolation, "order #{order.id} is a #{order.side} but rests on the #{side} ladder"
      end

      unless order.price == level.price
        raise InvariantViolation, "order #{order.id} at #{order.price} rests in level #{level.price}"
      end

      unless (order.price % engine.tick_size).zero?
        raise InvariantViolation, "order #{order.id} price #{order.price} is off-tick (tick #{engine.tick_size})"
      end

      raise InvariantViolation, "order #{order.id} rests on more than one level" if seen[order.id]

      seen[order.id] = true

      registered = engine.orders[order.id]
      unless registered.equal?(order)
        raise InvariantViolation, "order #{order.id} rests but is not the registered order object"
      end

      unless order.actor_hash == PIT::Hasher.fold(PIT::Hasher::OFFSET_BASIS, order.actor)
        raise InvariantViolation, "order #{order.id} has an actor_hash that does not match its actor"
      end

      return if engine.seq >= order.seq

      raise InvariantViolation, "order #{order.id} seq #{order.seq} is ahead of engine seq #{engine.seq}"
    end

    def check_open_orders_are_resting(engine)
      engine.orders.each_value do |order|
        next unless order.open?
        next if resting?(engine.book, order)

        raise InvariantViolation, "open order #{order.id} (#{order.side} #{order.remaining}@#{order.price}) is not in the book"
      end
    end

    def check_totals(engine)
      %i[buy sell].each do |side|
        computed = engine.book.ladder(side).sum { |level| level.orders.sum(&:remaining) }
        tracked = engine.book.resting_qty(side)
        unless computed == tracked
          raise InvariantViolation, "#{side} resting qty tracked=#{tracked} but computed=#{computed}"
        end
      end

      enumerated = engine.book.each_resting.count
      tracked = engine.book.resting_count
      return if enumerated == tracked

      raise InvariantViolation, "resting count tracked=#{tracked} but enumerated=#{enumerated}"
    end

    def resting?(book, order)
      level = book.find_level(order.side, order.price)
      return false unless level

      level.orders.any? { |candidate| candidate.equal?(order) }
    end
  end
end
