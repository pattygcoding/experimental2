# frozen_string_literal: true

# Two markets, because the engine's *configuration* is part of its fingerprint: PIT-USD trades in
# pennies on a 1/1 grid, PIT-EUR in 5-tick, 10-lot chunks with a different self-trade policy.
#
# Idempotent on purpose: re-running it updates the instruments rather than recreating them, so the
# command log — and therefore the book — survives a re-seed.
def seed_instrument(symbol, tick_size:, lot_size:, self_trade_policy:, seed:, rate:, synthetic: true)
  instrument = Instrument.find_or_initialize_by(symbol: symbol)
  instrument.assign_attributes(
    tick_size: tick_size,
    lot_size: lot_size,
    self_trade_policy: self_trade_policy,
    seed: seed,
    synthetic_flow: synthetic,
    synthetic_rate: rate
  )
  instrument.save!

  puts format(
    "  %-8s tick %-3d lot %-3d self-trade %-14s seed %-9d flow %-3s @ %d/s (%d commands logged)",
    instrument.symbol, instrument.tick_size, instrument.lot_size, instrument.self_trade_policy,
    instrument.seed, instrument.synthetic_flow? ? "on" : "off", instrument.synthetic_rate,
    instrument.command_count
  )
  instrument
end

puts "Seeding PIT markets…"

seed_instrument(
  ENV.fetch("PIT_SYMBOL", "PIT-USD"),
  tick_size: 1, lot_size: 1, self_trade_policy: "cancel_resting",
  seed: ENV.fetch("PIT_SEED", 20_261_104).to_i, rate: ENV.fetch("PIT_RATE", 6).to_i
)

seed_instrument(
  "PIT-EUR",
  tick_size: 5, lot_size: 10, self_trade_policy: "skip",
  seed: ENV.fetch("PIT_EUR_SEED", 4_242).to_i, rate: ENV.fetch("PIT_EUR_RATE", 3).to_i
)

puts "Done — bin/rails server, then open http://localhost:3000"
