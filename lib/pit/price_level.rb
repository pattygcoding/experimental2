# frozen_string_literal: true

module PIT
  # All the resting orders at one price, in arrival order (FIFO) — this is the "time"
  # half of price-time priority. `qty` is the total remaining at the level, kept
  # incrementally so depth bars and the crossed-book invariant are both O(1).
  class PriceLevel
    attr_reader :price, :orders
    attr_accessor :qty

    def initialize(price)
      @price = Integer(price)
      @orders = []
      @qty = 0
    end

    def add(order)
      @orders << order
      @qty += order.remaining
      order
    end

    # Fast path: the head is by far the most common thing to remove (it just traded).
    def remove(order)
      if @orders.first.equal?(order)
        @orders.shift
      else
        return nil unless @orders.delete(order)
      end

      @qty -= order.remaining
      order
    end

    def head = @orders.first
    def head_seq = @orders.first&.seq
    def size = @orders.size
    def empty? = @orders.empty?

    def each(&block) = @orders.each(&block)

    def to_s = "#<PIT::PriceLevel #{price} x#{qty} orders=#{size}>"
    def inspect = to_s
  end
end
