# frozen_string_literal: true

# A tradeable symbol, plus the tuning the in-memory engine is built from.
class Instrument < ApplicationRecord
  SELF_TRADE_POLICIES = %w[cancel_resting skip off].freeze

  has_many :commands, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :fills, dependent: :destroy
  has_many :book_checkpoints, dependent: :destroy

  validates :symbol, presence: true, uniqueness: { case_sensitive: false }
  validates :tick_size, :lot_size, presence: true, numericality: { greater_than: 0 }
  validates :self_trade_policy, inclusion: { in: SELF_TRADE_POLICIES }

  scope :enabled, -> { order(:symbol) }

  # The instrument the root path opens. Explicit rather than "first by symbol", because ordering by
  # symbol would silently make PIT-EUR the front page the moment a new market is seeded.
  def self.default
    find_by(symbol: ENV.fetch("PIT_SYMBOL", "PIT-USD")) || order(:symbol).first
  end

  def self.find_by_symbol!(symbol)
    find_by!("symbol = ?", symbol.to_s.upcase)
  end

  # The engine's config is derived from the row, never the other way round: change this and
  # the fingerprint changes, which is why the config is part of it.
  def engine_config
    PIT::Config.default(tick_size: tick_size, lot_size: lot_size, self_trade: self_trade_policy.to_sym)
  end

  def fuzz(seed = self.seed)
    PIT::Fuzz.new(seed: seed, tick: tick_size, lot: lot_size)
  end

  def latest_checkpoint = book_checkpoints.order(position: :desc).first

  def command_count = commands.count
end
