# frozen_string_literal: true

# The order ticket page: the live market is rendered by app/javascript/controllers/market_controller.js
# from the Action Cable stream, and this controller only provides the first paint.
class BooksController < ApplicationController
  def show
    redirect_to book_path(default_symbol) and return if params[:symbol].blank?

    @instrument = market_instrument
    @feed = EngineRegistry.feed_for(@instrument)
    @snapshot = @feed.snapshot(levels: 12)
    @my_orders = @feed.actor_orders(current_trader)
    @tape = @feed.tape(20)
    @recent_fills = @instrument.fills.recent(10)
    @checkpoint = @instrument.latest_checkpoint
    @stats = @feed.stats
  end

  private

  def default_symbol
    Instrument.default&.symbol ||
      raise(ActiveRecord::RecordNotFound, "no instruments exist — run bin/rails db:seed")
  end

  def market_instrument
    Instrument.find_by_symbol!(params[:symbol])
  end
end
