# frozen_string_literal: true

module PIT
  class ReplayMismatch < StandardError; end

  # Rebuilds engine state from a durable command log.
  #
  # This is the payoff of determinism: the database stores the *commands*, never the book.
  # Any past state is one fold away, and `verify!` proves the rebuild reproduced history by
  # comparing against fingerprints captured while the market was live.
  module Replayer
    Result = Data.define(:engine, :commands, :events, :fingerprint)

    module_function

    # Replay `commands` (in order) into an engine, optionally stopping after `upto`.
    #
    # With a block, the block is called after every applied command as
    # `|engine, applied|` — which lets the Rails layer compare `book_checkpoints`
    # in a single pass instead of replaying twice.
    def replay(config:, commands:, upto: nil, &observer)
      engine = Engine.new(config: config)
      events = 0
      applied = 0

      commands.each do |command|
        break if upto && applied >= upto

        events += engine.apply(command).size
        applied += 1
        observer&.call(engine, applied)
      end

      Result.new(engine: engine, commands: applied, events: events, fingerprint: engine.fingerprint)
    end

    # `checkpoints` is an array of hashes: { "at" => n, "fingerprint" => "..." } meaning
    # "after n commands the engine's fingerprint was ...".
    #
    # Returns one row per checkpoint with the comparison result. Raises ReplayMismatch when
    # anything disagrees, unless raise_on_mismatch is false (the REST API reports instead).
    def verify!(config:, commands:, checkpoints:, raise_on_mismatch: true)
      engine = Engine.new(config: config)
      applied = 0
      results = []
      ordered = checkpoints.map { |checkpoint| [ Integer(fetch(checkpoint, "at")), checkpoint ] }.sort_by(&:first)

      ordered.each do |at, checkpoint|
        while applied < at && applied < commands.size
          engine.apply(commands[applied])
          applied += 1
        end

        expected = fetch(checkpoint, "fingerprint")
        actual = engine.fingerprint
        results << { at: at, expected: expected, actual: actual, match: expected == actual }
      end

      mismatch = results.find { |row| !row[:match] }
      if mismatch && raise_on_mismatch
        raise ReplayMismatch, "replay diverged at command #{mismatch[:at]}: " \
                              "recorded #{mismatch[:expected]}, replayed #{mismatch[:actual]}"
      end

      results
    end

    def fetch(hash, key)
      hash.is_a?(Hash) ? (hash[key] || hash[key.to_sym]) : raise(ArgumentError, "checkpoints must be hashes")
    end
  end
end
