# frozen_string_literal: true

module Api
  # Time travel. Rebuilds the book from the log — the only thing the database stores — and reports
  # whether the rebuild reproduced the fingerprints recorded while the market was live.
  #
  #   GET /api/books/PIT-USD/replay          ⇒ the book after the whole log
  #   GET /api/books/PIT-USD/replay?at=2500  ⇒ the book after command 2,500
  #
  # Replaying the *whole* log is the interesting case: the rebuild is compared against the live book,
  # so "matchesLive" is the claim this whole project is built to make.
  class ReplaysController < ApplicationController
    def show
      payload = MarketReplay.payload(instrument, upto: upto, levels: levels)

      if upto.nil?
        live = EngineRegistry.feed_for(instrument).fingerprint
        payload = payload.merge("liveFingerprint" => live, "matchesLive" => (live == payload["fingerprint"]))
      end

      render json: payload
    end

    private

    def instrument = @instrument ||= Instrument.find_by_symbol!(params[:symbol])
    def upto = params[:at].presence&.to_i
    def levels = params.fetch(:levels, 10).to_i.clamp(1, 50)
  end
end
