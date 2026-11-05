# frozen_string_literal: true

# A print. Written by PersistMarketEventsJob, off the matching path: the feed hands events to a
# job and never waits for the database.
class Fill < ApplicationRecord
  belongs_to :instrument

  validates :trade_seq, presence: true, uniqueness: { scope: :instrument_id }
  validates :qty, numericality: { greater_than: 0 }
  validates :aggressor, inclusion: { in: Order::SIDES }

  scope :recent, ->(limit = 50) { order(trade_seq: :desc).limit(limit) }
  scope :tape, -> { order(:trade_seq) }

  def buy? = aggressor == "buy"
  def sell? = aggressor == "sell"
end
