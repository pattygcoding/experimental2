# frozen_string_literal: true

module Api
  # The tape as persisted by the background job — i.e. the durability path, not the live engine.
  class FillsController < ApplicationController
    def index
      fills = instrument.fills.recent(limit).map do |fill|
        {
          "tradeSeq" => fill.trade_seq, "price" => fill.price, "qty" => fill.qty,
          "aggressor" => fill.aggressor, "makerActor" => fill.maker_actor, "takerActor" => fill.taker_actor
        }
      end

      render json: { "symbol" => instrument.symbol, "count" => fills.size, "fills" => fills }
    end

    private

    def instrument = @instrument ||= Instrument.find_by_symbol!(params[:symbol])
    def limit = params.fetch(:limit, 50).to_i.clamp(1, 500)
  end
end
