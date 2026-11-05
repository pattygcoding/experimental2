# frozen_string_literal: true

module Api
  # The read model for one market: the live book, straight out of the engine.
  class BooksController < ApplicationController
    def show
      feed = EngineRegistry.feed_for(instrument)
      stats = feed.stats

      # The read model asks for the full fingerprint: one O(book) pass per HTTP request is a fair
      # price for a receipt, and it is never on the tick path.
      render json: feed.snapshot(levels: levels, with_fingerprint: true).merge(
        "commandCount" => stats[:commands],
        "warmUpCommands" => stats[:warm_up_commands],
        "counters" => stats[:counters].transform_keys(&:to_s),
        "tape" => feed.tape(tape_size),
        "tick" => {
          "rate" => MarketFeed::SNAPSHOT_HZ,
          "p50Ms" => stats[:tick_p50_ms], "p95Ms" => stats[:tick_p95_ms], "p99Ms" => stats[:tick_p99_ms]
        }
      )
    end

    private

    def instrument = @instrument ||= Instrument.find_by_symbol!(params[:symbol])
    def levels = params.fetch(:levels, 10).to_i.clamp(1, 50)
    def tape_size = params.fetch(:tape, 20).to_i.clamp(1, MarketFeed::TAPE_FRAME)
  end
end
