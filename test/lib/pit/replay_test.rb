# frozen_string_literal: true

require_relative "../engine_test_helper"

# The two claims the whole architecture rests on:
#
#   1. a seeded command stream keeps every invariant after *every* command, and
#   2. replaying the durable command log reproduces the book exactly — proved against
#      fingerprints captured while the market was live.
class ReplayTest < Minitest::Test
  include EngineTestHelper

  SEEDS = [ 1, 7, 42, 2_024, 99_991 ].freeze

  def test_fuzzed_command_streams_never_break_an_invariant
    SEEDS.each do |seed|
      engine = build_engine
      PIT::Fuzz.new(seed: seed).each(engine, 250) do |command|
        engine.apply(command)
        PIT::Invariants.assert_consistent!(engine)
      end

      assert_operator engine.counters[:fills], :>, 0, "seed #{seed} produced no trades at all"
    end
  end

  def test_a_replay_of_the_log_reproduces_the_book_exactly
    live = build_engine
    commands = []
    PIT::Fuzz.new(seed: 12_345).each(live, 300) do |command|
      commands << command
      live.apply(command)
    end

    replayed = PIT::Replayer.replay(config: PIT::Config.default, commands: commands)

    assert_equal 300, replayed.commands
    assert_equal live.fingerprint, replayed.fingerprint
    assert_equal live.book.resting_count, replayed.engine.book.resting_count
    assert_equal live.book.best_bid, replayed.engine.book.best_bid
  end

  def test_replay_from_a_truncated_log_reproduces_an_intermediate_book
    live = build_engine
    commands = []
    checkpoints = {}

    PIT::Fuzz.new(seed: 777).each(live, 200) do |command|
      commands << command
      live.apply(command)
      checkpoints[commands.size] = live.fingerprint if (commands.size % 50).zero?
    end

    checkpoints.each do |at, fingerprint|
      replay = PIT::Replayer.replay(config: PIT::Config.default, commands: commands, upto: at)
      assert_equal fingerprint, replay.fingerprint, "state after #{at} commands did not replay"
    end
  end

  def test_verify_accepts_a_faithful_log_and_rejects_a_tampered_one
    live = build_engine
    commands = []
    PIT::Fuzz.new(seed: 5150).each(live, 120) do |command|
      commands << command
      live.apply(command)
    end

    checkpoints = [ { "at" => 60, "fingerprint" => nil }, { "at" => 120, "fingerprint" => nil } ]
    engine = PIT::Engine.new(config: PIT::Config.default)
    commands.each { |command| engine.apply(command) }
    checkpoints[1]["fingerprint"] = engine.fingerprint

    results = PIT::Replayer.verify!(config: PIT::Config.default, commands: commands,
                                    checkpoints: checkpoints, raise_on_mismatch: false)
    assert_equal [ false, true ], results.map { |row| row[:match] }, "the nil fingerprint must not match"

    checkpoints[0]["fingerprint"] = "deadbeefdeadbeef"
    assert_raises(PIT::ReplayMismatch) do
      PIT::Replayer.verify!(config: PIT::Config.default, commands: commands, checkpoints: checkpoints)
    end
  end

  def test_a_reordered_log_produces_a_different_book
    live = build_engine
    commands = []
    PIT::Fuzz.new(seed: 4_242).each(live, 150) do |command|
      commands << command
      live.apply(command)
    end

    shuffled = commands.each_slice(2).to_a.reverse.flatten(1)
    replayed = PIT::Replayer.replay(config: PIT::Config.default, commands: shuffled)

    refute_equal live.fingerprint, replayed.fingerprint,
                 "order matters: a shuffled log is a different market"
  end

  def test_commands_survive_a_round_trip_through_the_wire_form
    commands = PIT::Fuzz.new(seed: 8).stream(build_engine, 40)
    restored = commands.map { |command| PIT::Commands.from_h(PIT::Commands.to_h(command)) }

    assert_equal commands, restored
  end
end
