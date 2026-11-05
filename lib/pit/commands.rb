# frozen_string_literal: true

module PIT
  # Commands are the only way to mutate the book, and the unit of the write-ahead log.
  #
  # They are immutable (Data) and they carry *intent only* — no prices the engine trusts
  # blind, no order ids the engine accepts from the client for new orders. Order ids are
  # assigned by the engine from a monotonic counter, which is what makes replay exact.
  #
  # `id` is the caller's command id (a string). It is echoed in Rejected events and used
  # for idempotency in the Rails layer; the engine itself never requires it to be unique.
  module Commands
    Submit = Data.define(:id, :side, :type, :price, :qty, :tif, :actor) do
      def market? = type == :market
      def limit? = type == :limit
      def buy? = side == :buy
      def sell? = side == :sell
    end

    Cancel = Data.define(:id, :order_id, :actor)
    Amend = Data.define(:id, :order_id, :price, :qty, :actor)

    SIDES = %i[buy sell].freeze
    TYPES = %i[limit market].freeze
    TIFF = %i[gtc ioc fok].freeze

    module_function

    def submit(id:, side:, qty:, price: nil, type: :limit, tif: :gtc, actor: "anonymous")
      raise ArgumentError, "side must be one of #{SIDES.inspect}" unless SIDES.include?(side)
      raise ArgumentError, "type must be one of #{TYPES.inspect}" unless TYPES.include?(type)
      raise ArgumentError, "tif must be one of #{TIFF.inspect}" unless TIFF.include?(tif)

      Submit.new(id: id.to_s, side: side, type: type, price: price, qty: qty, tif: tif, actor: actor.to_s)
    end

    # A market order is an IOC limit order with no price ceiling/floor.
    def market(id:, side:, qty:, actor: "anonymous")
      submit(id: id, side: side, qty: qty, type: :market, tif: :ioc, price: nil, actor: actor)
    end

    def cancel(id:, order_id:, actor: "anonymous")
      Cancel.new(id: id.to_s, order_id: Integer(order_id), actor: actor.to_s)
    end

    def amend(id:, order_id:, price:, qty:, actor: "anonymous")
      Amend.new(id: id.to_s, order_id: Integer(order_id), price: price, qty: qty, actor: actor.to_s)
    end

    # Canonical form, used by the fuzzer, the WAL and the replay tests so that a command
    # logged by Rails can be rebuilt byte-for-byte.
    def to_h(command)
      case command
      when Submit
        { "kind" => "submit", "id" => command.id, "side" => command.side.to_s,
          "type" => command.type.to_s, "tif" => command.tif.to_s, "price" => command.price,
          "qty" => command.qty, "actor" => command.actor }
      when Cancel
        { "kind" => "cancel", "id" => command.id, "order_id" => command.order_id, "actor" => command.actor }
      when Amend
        { "kind" => "amend", "id" => command.id, "order_id" => command.order_id,
          "price" => command.price, "qty" => command.qty, "actor" => command.actor }
      else
        raise ArgumentError, "not a command: #{command.inspect}"
      end
    end

    def from_h(hash)
      hash = hash.transform_keys(&:to_s)
      case hash.fetch("kind")
      when "submit"
        submit(id: hash.fetch("id"), side: hash.fetch("side").to_sym, qty: Integer(hash.fetch("qty")),
               price: hash["price"] && Integer(hash["price"]), type: hash.fetch("type", "limit").to_sym,
               tif: hash.fetch("tif", "gtc").to_sym, actor: hash.fetch("actor", "anonymous"))
      when "cancel"
        cancel(id: hash.fetch("id"), order_id: Integer(hash.fetch("order_id")), actor: hash.fetch("actor", "anonymous"))
      when "amend"
        amend(id: hash.fetch("id"), order_id: Integer(hash.fetch("order_id")), price: Integer(hash.fetch("price")),
              qty: Integer(hash.fetch("qty")), actor: hash.fetch("actor", "anonymous"))
      else
        raise ArgumentError, "unknown command kind #{hash["kind"].inspect}"
      end
    end
  end
end
