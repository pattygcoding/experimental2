# frozen_string_literal: true

# What a command did, plus the state the caller should be shown.
class OrderEntry
  Result = Data.define(:position, :events, :snapshot, :duplicate)
  class InvalidCommand < StandardError; end

  # `actor` is the trader: a per-browser identity from the session, or a bot. It is never
  # taken from the request body — the server owns who you are, exactly as HEXARENA resolves
  # an agent from the session id rather than the payload.
  #
  # `feed` is normally looked up here; the synthetic flow passes the feed it belongs to, so that
  # starting a market never re-enters the registry while it is being created.
  def initialize(instrument, actor:, feed: nil)
    @instrument = instrument
    @actor = actor.to_s
    @feed = feed || EngineRegistry.feed_for(instrument)
  end

  attr_reader :actor

  # params is untrusted input: shape is validated here, and market rules (tick, lot,
  # liquidity, priority) are validated by the engine. Two layers, one of which is pure.
  def submit(params)
    side = symbol_param(params, :side, PIT::Commands::SIDES)
    type = symbol_param(params, :type, PIT::Commands::TYPES, default: :limit)
    tif = symbol_param(params, :tif, PIT::Commands::TIFF, default: :gtc)
    qty = integer_param(params, :qty)
    price = type == :market ? nil : integer_param(params, :price)

    apply(PIT::Commands.submit(id: command_id(params), side: side, qty: qty, price: price,
                               type: type, tif: tif, actor: @actor))
  end

  def cancel(order_id)
    apply(PIT::Commands.cancel(id: command_id({}),
                               order_id: integer_param({ "order_id" => order_id }, :order_id),
                               actor: @actor))
  end

  def amend(order_id, params)
    apply(PIT::Commands.amend(id: command_id(params),
                              order_id: integer_param({ "order_id" => order_id }, :order_id),
                              price: integer_param(params, :price),
                              qty: integer_param(params, :qty),
                              actor: @actor))
  end

  # Admit an already-formed engine command (the synthetic flow builds these from PIT::Fuzz). The
  # id is rewritten with a boot-scoped prefix, so a restarted process cannot produce a command id
  # that already exists in the log — which the unique index would otherwise reject as a duplicate.
  def admit(command, id: nil)
    apply(
      case command
      when PIT::Commands::Submit
        PIT::Commands.submit(id: id || command.id, side: command.side, qty: command.qty,
                             price: command.price, type: command.type, tif: command.tif, actor: @actor)
      when PIT::Commands::Cancel
        PIT::Commands.cancel(id: id || command.id, order_id: command.order_id, actor: @actor)
      when PIT::Commands::Amend
        PIT::Commands.amend(id: id || command.id, order_id: command.order_id, price: command.price,
                            qty: command.qty, actor: @actor)
      else
        raise InvalidCommand, "cannot admit #{command.class}"
      end
    )
  end

  # The command id makes a double-submitted form idempotent: the second one is refused by the
  # unique index on (instrument_id, command_id) and reported as `duplicate` rather than
  # matching twice.
  def command_id(params)
    candidate = (params[:command_id] || params["command_id"]).to_s
    candidate.empty? ? "cmd-#{SecureRandom.hex(8)}" : candidate
  end

  private

  def apply(command)
    @feed.apply(command)
  end

  def symbol_param(params, key, allowed, default: nil)
    raw = params[key] || params[key.to_s] || default
    raise InvalidCommand, "#{key} is required" if raw.nil?

    symbol = raw.to_s.downcase.to_sym
    raise InvalidCommand, "#{key} must be one of #{allowed.join(', ')}" unless allowed.include?(symbol)

    symbol
  end

  # Every numeric parameter is required wherever it is accepted: a limit order without a price is a
  # shape error, and "10,000" is not a price. Market orders never reach this for a price (see
  # #submit), so there is no optional case to model.
  def integer_param(params, key)
    raw = params[key] || params[key.to_s]
    raw = nil if raw.nil? || raw.to_s.strip.empty?
    raise InvalidCommand, "#{key} is required" if raw.nil?

    Integer(raw.to_s.strip)
  rescue ArgumentError
    raise InvalidCommand, "#{key} must be a whole number"
  end
end
