# frozen_string_literal: true

module PIT
  # A resting or in-flight order.
  #
  # This is the one deliberately mutable object in the engine: it sits in the hot loop and
  # `remaining` / `status` / `price` / `seq` change as it trades, is amended or cancelled.
  # Everything else in PIT is immutable. The external projection of an order is rebuilt
  # from the events, never read back out of this object.
  class Order
    attr_reader :id, :actor, :side, :type, :tif, :command_id, :actor_hash
    attr_accessor :price, :qty, :remaining, :status, :seq, :stp_blocked

    STATUSES = %i[open filled cancelled].freeze

    def initialize(id:, actor:, side:, type:, price:, qty:, tif:, seq:, command_id: nil)
      @id = Integer(id)
      @actor = actor.to_s
      @side = side
      @type = type
      @tif = tif
      @price = price
      @qty = Integer(qty)
      @remaining = @qty
      @seq = Integer(seq)
      @command_id = command_id
      @status = :open
      @stp_blocked = false
      # The actor is the only attribute of an order that can never change after it is accepted, so its
      # bytes are folded once here rather than on every book fingerprint. Worth it: folding actors
      # byte-wise cost 19.6 ms of a 28.9 ms fingerprint on a 13k-order book (measured).
      @actor_hash = Hasher.fold(Hasher::OFFSET_BASIS, @actor)
    end

    def buy? = @side == :buy
    def sell? = @side == :sell
    def market? = @type == :market
    def filled = @qty - @remaining
    def open? = @status == :open
    def liquid? = @remaining.positive?

    def to_s
      "#<PIT::Order ##{id} #{side} #{remaining}/#{qty}@#{price} seq=#{seq} actor=#{actor} #{status}>"
    end

    def inspect = to_s # rubocop-friendly, and Data-style typos become obvious in test output

    private_constant :STATUSES
  end
end
