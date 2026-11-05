# frozen_string_literal: true

# Order entry. Intent over HTTP, so the write-ahead log row is committed before the engine
# matches — and so a double-submitted form is idempotent rather than traded twice.
class OrdersController < ApplicationController
  def create
    result = entry.submit(order_params)
    redirect_to book_path(symbol), flash_kind(result) => outcome(result)
  rescue OrderEntry::InvalidCommand => e
    redirect_to book_path(symbol), alert: e.message
  end

  def update
    result = entry.amend(params[:order_id], order_params)
    redirect_to book_path(symbol), flash_kind(result) => outcome(result)
  rescue OrderEntry::InvalidCommand => e
    redirect_to book_path(symbol), alert: e.message
  end

  def destroy
    result = entry.cancel(params[:order_id])
    redirect_to book_path(symbol), flash_kind(result) => outcome(result)
  rescue OrderEntry::InvalidCommand => e
    redirect_to book_path(symbol), alert: e.message
  end

  private

  # A rejection or a duplicate is shown as an alert, not as a success notice: the engine refused, and
  # the browser should say so in red.
  def flash_kind(result)
    refused = result.duplicate || result.events.any? { |event| event.is_a?(PIT::Events::Rejected) }
    refused ? :alert : :notice
  end

  def instrument = @instrument ||= Instrument.find_by_symbol!(symbol)

  def symbol = params[:symbol].presence || Instrument.default&.symbol

  def entry = @entry ||= OrderEntry.new(instrument, actor: current_trader)

  def order_params
    params.permit(:side, :type, :tif, :price, :qty, :command_id).to_h.symbolize_keys
  end

  # The engine's verdict, in words. The acknowledgement already contains the fills because
  # matching happened on this thread — that is the design decision this method shows off.
  def outcome(result)
    return "Duplicate command ignored — the ticket was already submitted" if result.duplicate

    events = result.events
    rejection = events.grep(PIT::Events::Rejected).first
    return "Rejected: #{rejection.reason.to_s.tr('_', ' ')}" if rejection

    parts = []
    fills = events.grep(PIT::Events::Fill)
    if fills.any?
      prices = fills.map(&:price).uniq
      parts << "filled #{fills.sum(&:qty)} @ #{prices.join('/')}"
    end
    rested = events.grep(PIT::Events::Rested).sum(&:qty)
    parts << "resting #{rested}" if rested.positive?
    cancelled = events.grep(PIT::Events::Cancelled)
    parts << "cancelled #{cancelled.sum(&:qty)} (#{cancelled.first.reason.to_s.tr('_', ' ')})" if cancelled.any?

    parts.empty? ? "accepted" : parts.join(" · ")
  end
end
