# frozen_string_literal: true

module PIT
  # Immutable match tuning. The engine reads nothing else from the outside world.
  #
  #   tick_size           prices must be a positive multiple of this (in minor units)
  #   lot_size            quantities must be a positive multiple of this
  #   self_trade          what to do when taker and maker are the same actor:
  #                         :cancel_resting  cancel the resting order, keep matching
  #                         :skip            stop matching; the taker's remainder is killed
  #                         :off             allow the self-trade
  Config = Data.define(:tick_size, :lot_size, :self_trade) do
    def self.default(tick_size: 1, lot_size: 1, self_trade: :cancel_resting)
      new(tick_size: tick_size, lot_size: lot_size, self_trade: self_trade)
    end

    def self.from_hash(hash)
      hash = hash.transform_keys(&:to_sym)
      new(
        tick_size: Integer(hash.fetch(:tick_size, 1)),
        lot_size: Integer(hash.fetch(:lot_size, 1)),
        self_trade: hash.fetch(:self_trade, :cancel_resting).to_sym
      )
    end

    def initialize(tick_size: 1, lot_size: 1, self_trade: :cancel_resting)
      tick_size = Integer(tick_size)
      lot_size = Integer(lot_size)
      raise ArgumentError, "tick_size must be positive" unless tick_size.positive?
      raise ArgumentError, "lot_size must be positive" unless lot_size.positive?
      raise ArgumentError, "unknown self_trade policy #{self_trade.inspect}" unless
        %i[off cancel_resting skip].include?(self_trade)

      super(tick_size: tick_size, lot_size: lot_size, self_trade: self_trade)
    end

    # Contributes to Engine#fingerprint: a config change must change the fingerprint.
    def signature
      "#{tick_size}/#{lot_size}/#{self_trade}"
    end

    def to_h
      { tick_size: tick_size, lot_size: lot_size, self_trade: self_trade.to_s }
    end
  end
end
