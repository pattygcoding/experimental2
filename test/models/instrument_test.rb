# frozen_string_literal: true

require "test_helper"

# The instrument row is the engine's configuration source. Get this wrong and every fingerprint
# changes, which is exactly why the config is hashed into the fingerprint.
class InstrumentTest < ActiveSupport::TestCase
  test "the engine config is derived from the row" do
    config = instruments(:pit_eur).engine_config

    assert_equal 5, config.tick_size
    assert_equal 10, config.lot_size
    assert_equal :skip, config.self_trade
  end

  test "the config's signature is part of what makes two books different" do
    usd = instruments(:pit_usd).engine_config
    eur = instruments(:pit_eur).engine_config

    refute_equal usd.signature, eur.signature

    a = PIT::Engine.new(config: usd)
    b = PIT::Engine.new(config: eur)
    [ a, b ].each { |engine| engine.apply(PIT::Commands.submit(id: "c", side: :buy, price: 1_000, qty: 1)) }

    refute_equal a.fingerprint, b.fingerprint
  end

  test "only known self-trade policies are accepted" do
    instrument = instruments(:pit_usd)
    instrument.self_trade_policy = "let-them-trade"

    refute instrument.valid?
    assert_includes instrument.errors[:self_trade_policy], "is not included in the list"
  end

  test "the symbol is unique and case insensitive to look up" do
    assert_equal instruments(:pit_usd), Instrument.find_by_symbol!("pit-usd")

    duplicate = Instrument.new(symbol: "pit-usd", tick_size: 1, lot_size: 1)
    refute duplicate.valid?
  end

  test "a fuzz stream is reproducible from the instrument's seed" do
    instrument = instruments(:pit_usd)
    first = instrument.fuzz.stream(PIT::Engine.new(config: instrument.engine_config), 20)
    second = instrument.fuzz.stream(PIT::Engine.new(config: instrument.engine_config), 20)

    assert_equal first, second
  end

  test "the latest checkpoint is the highest position, not the most recently written row" do
    instrument = instruments(:pit_usd)
    BookCheckpoint.create!(instrument_id: instrument.id, position: 200, fingerprint: "bbbb",
                           resting_orders: 1, trade_seq: 1)
    BookCheckpoint.create!(instrument_id: instrument.id, position: 100, fingerprint: "aaaa",
                           resting_orders: 1, trade_seq: 1)

    assert_equal 200, instrument.latest_checkpoint.position
  end

  test "the default instrument is named explicitly, not taken from the alphabet" do
    assert_equal "PIT-USD", Instrument.default.symbol
  end
end
