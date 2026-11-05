# frozen_string_literal: true

# The market stream.
#
#   pit:market:<symbol>   snapshots (@10 Hz) and the event log — everyone sees the same frames
#   pit:actor:<trader>    this trader's own open orders, only when they change
#
# Commands do NOT come over the socket: intent travels over HTTP so that it is durable *before*
# the engine sees it (see MarketFeed#apply for why that ordering matters). The socket here is
# purely downstream state.
class OrderBookChannel < ApplicationCable::Channel
  def subscribed
    instrument = Instrument.find_by(symbol: params[:symbol].to_s.upcase)
    reject && return unless instrument

    @symbol = instrument.symbol
    @feed = EngineRegistry.feed_for(instrument)
    @feed.subscribe(trader)

    stream_from @feed.market_stream_name
    stream_from "pit:actor:#{trader}"

    # First paint: the client should never have to wait a tick to see the book.
    transmit @feed.snapshot(levels: 12)
    transmit({ "type" => "yourOrders", "symbol" => @symbol, "orders" => @feed.actor_orders(trader) })
    transmit({ "type" => "hello", "symbol" => @symbol, "trader" => trader,
               "tickRate" => MarketFeed::SNAPSHOT_HZ })
  end

  def unsubscribed
    @feed&.unsubscribe(trader)
  end
end
