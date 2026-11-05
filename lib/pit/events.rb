# frozen_string_literal: true

module PIT
  # What the engine produced. Events are immutable facts, in total order, and they are
  # the only thing the outside world (and the rolling hash) sees.
  module Events
    Accepted  = Data.define(:seq, :order_id, :side, :type, :tif, :price, :qty, :actor)
    Rested    = Data.define(:seq, :order_id, :price, :qty, :actor)
    Fill      = Data.define(:seq, :trade_seq, :price, :qty, :maker_order_id, :maker_actor,
                            :taker_order_id, :taker_actor, :aggressor)
    Cancelled = Data.define(:seq, :order_id, :qty, :reason, :actor)
    Amended   = Data.define(:seq, :order_id, :price, :qty, :kept_priority, :actor)
    Done      = Data.define(:seq, :order_id, :actor)
    Rejected  = Data.define(:command_id, :reason, :actor)

    module_function

    # Canonical string form: folded into the engine's rolling hash, so that two runs
    # which differ only in a rejected order still fingerprint differently.
    def signature(event)
      case event
      when Accepted
        "AC seq=#{event.seq} o=#{event.order_id} #{event.side} #{event.type} #{event.tif} #{event.price} x#{event.qty} by=#{event.actor}"
      when Rested
        "RE seq=#{event.seq} o=#{event.order_id} #{event.price} x#{event.qty} by=#{event.actor}"
      when Fill
        "FI seq=#{event.seq} t=#{event.trade_seq} #{event.price} x#{event.qty} maker=#{event.maker_order_id} taker=#{event.taker_order_id} agg=#{event.aggressor}"
      when Cancelled
        "CA seq=#{event.seq} o=#{event.order_id} x#{event.qty} why=#{event.reason} by=#{event.actor}"
      when Amended
        "AM seq=#{event.seq} o=#{event.order_id} #{event.price} x#{event.qty} prio=#{event.kept_priority} by=#{event.actor}"
      when Done
        "DO seq=#{event.seq} o=#{event.order_id} by=#{event.actor}"
      when Rejected
        "RJ c=#{event.command_id} why=#{event.reason} by=#{event.actor}"
      else
        raise ArgumentError, "not an event: #{event.inspect}"
      end
    end

    # Wire form for Action Cable. Keys are strings, because they go straight out as JSON.
    def to_h(event)
      case event
      when Accepted
        { "type" => "accepted", "seq" => event.seq, "orderId" => event.order_id, "side" => event.side.to_s,
          "orderType" => event.type.to_s, "tif" => event.tif.to_s, "price" => event.price,
          "qty" => event.qty, "actor" => event.actor }
      when Rested
        { "type" => "rested", "seq" => event.seq, "orderId" => event.order_id,
          "price" => event.price, "qty" => event.qty, "actor" => event.actor }
      when Fill
        { "type" => "fill", "seq" => event.seq, "tradeSeq" => event.trade_seq, "price" => event.price,
          "qty" => event.qty, "makerOrderId" => event.maker_order_id, "makerActor" => event.maker_actor,
          "takerOrderId" => event.taker_order_id, "takerActor" => event.taker_actor,
          "aggressor" => event.aggressor.to_s }
      when Cancelled
        { "type" => "cancelled", "seq" => event.seq, "orderId" => event.order_id,
          "qty" => event.qty, "reason" => event.reason.to_s, "actor" => event.actor }
      when Amended
        { "type" => "amended", "seq" => event.seq, "orderId" => event.order_id, "price" => event.price,
          "qty" => event.qty, "keptPriority" => event.kept_priority, "actor" => event.actor }
      when Done
        { "type" => "done", "seq" => event.seq, "orderId" => event.order_id, "actor" => event.actor }
      when Rejected
        { "type" => "rejected", "commandId" => event.command_id, "reason" => event.reason.to_s, "actor" => event.actor }
      else
        raise ArgumentError, "not an event: #{event.inspect}"
      end
    end
  end
end
