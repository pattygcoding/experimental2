# frozen_string_literal: true

module PIT
  # Two ladders of PriceLevels, best first: bids descending, asks ascending.
  #
  # Insertion is a binary search, so resting an order is O(log L) to find the level plus
  # O(1) to append at it (arrival order = time priority). Owns no policy: it is a data
  # structure, not an engine.
  class OrderBook
    attr_reader :bids, :asks

    def initialize
      @bids = []
      @asks = []
    end

    def ladder(side) = side == :buy ? @bids : @asks

    def best_bid = @bids.first&.price
    def best_ask = @asks.first&.price
    def best_bid_order = @bids.first&.head
    def best_ask_order = @asks.first&.head

    def spread
      return nil unless @bids.first && @asks.first

      @asks.first.price - @bids.first.price
    end

    def mid
      return nil unless @bids.first && @asks.first

      (@asks.first.price + @bids.first.price) / 2
    end

    def last_trade_price = @last_trade_price

    def last_trade_price=(price)
      @last_trade_price = price
    end

    # Resting stays legal even when the book is crossed mid-match (the engine only rests
    # an order once it can no longer trade). Invariants are asserted, not enforced here.
    def crossed?
      return false unless best_bid && best_ask

      best_bid >= best_ask
    end

    def rest(order)
      level = find_level(order.side, order.price) || insert_level(order.side, order.price)
      level.add(order)
    end

    def find_level(side, price)
      book = ladder(side)
      index = insertion_index(book, price, side)
      level = book[index]
      level if level && level.price == price
    end

    def drop_level(side, level)
      return unless level.empty?

      ladder(side).delete(level)
    end

    # [[price, qty, cumulative, orders], ...] best-first, for the ladder UI and the tape.
    def depth(side, levels = 10)
      cumulative = 0
      ladder(side).first(levels).map do |level|
        cumulative += level.qty
        { price: level.price, qty: level.qty, cumulative: cumulative, orders: level.size }
      end
    end

    def each_resting
      return enum_for(:each_resting) unless block_given?

      @bids.each { |level| level.each { |order| yield order } }
      @asks.each { |level| level.each { |order| yield order } }
    end

    def resting_count = @bids.sum(&:size) + @asks.sum(&:size)

    def resting_qty(side) = ladder(side).sum(&:qty)

    def clear
      @bids = []
      @asks = []
    end

    private

    # Bids: strictly better means a *higher* price. Asks: strictly better means lower.
    def better?(candidate, than, side)
      side == :buy ? candidate > than : candidate < than
    end

    # Index of the first level that is not better than `price`; equal prices live here,
    # and are contiguous, which is what makes find_level a single comparison.
    def insertion_index(book, price, side)
      low = 0
      high = book.size
      while low < high
        mid = (low + high) / 2
        if better?(book[mid].price, price, side)
          low = mid + 1
        else
          high = mid
        end
      end
      low
    end

    def insert_level(side, price)
      book = ladder(side)
      index = insertion_index(book, price, side)
      level = PriceLevel.new(price)
      book.insert(index, level)
      level
    end
  end
end
