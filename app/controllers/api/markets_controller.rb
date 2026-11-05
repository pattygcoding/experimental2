# frozen_string_literal: true

module Api
  # Every market this process is simulating, with the numbers the console and the README quote.
  class MarketsController < ApplicationController
    def index
      markets = EngineRegistry.feeds.map do |feed|
        stats = feed.stats
        {
          "symbol" => stats[:symbol], "commands" => stats[:commands], "fills" => stats[:fills],
          "resting" => stats[:resting], "bestBid" => stats[:best_bid], "bestAsk" => stats[:best_ask],
          "lastTradePrice" => stats[:last_trade], "fingerprint" => stats[:fingerprint],
          "warmUpCommands" => stats[:warm_up_commands], "subscribers" => stats[:subscribers],
          "tickP50Ms" => stats[:tick_p50_ms], "tickP95Ms" => stats[:tick_p95_ms],
          "synthetic" => stats[:synthetic]
        }
      end

      render json: { "markets" => markets, "count" => markets.size }
    end
  end
end
