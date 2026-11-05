# frozen_string_literal: true

# Time travel: rebuild the book from the write-ahead log.
#
# The database never stores the book, only the commands that produced it. Replaying them is
# therefore the *only* way to answer "what did the book look like at command 4,000?" — and
# because the engine is deterministic, the answer is exact. `book_checkpoints` are compared
# during the same pass, so this service can state not just what the book was, but whether the
# rebuild reproduced recorded history.
class MarketReplay
  Result = Data.define(:engine, :position, :commands, :events, :fingerprint, :verified, :mismatches,
                       :duration_ms, :snapshot) do
    def faithful? = mismatches.empty?
    def verified_checkpoints = verified.size
  end

  class << self
    # `upto` is a command position (nil ⇒ the whole log).
    #
    # Wrapped in `uncached` on purpose: this reads the *log*, and a replay served from the query
    # cache could verify last minute's history and call it faithful. The cache is cleared per request
    # and per job by the Rails executor, but a replay is cheap enough (~10 µs per command) that it
    # has no business trusting a cache at all.
    def at(instrument, upto: nil, levels: 10)
      ActiveRecord::Base.uncached { replay(instrument, upto: upto, levels: levels) }
    end

    private

    def replay(instrument, upto:, levels:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      records = instrument.commands.ordered.to_a
      records = records.select { |record| record.position <= Integer(upto) } if upto

      checkpoints = instrument.book_checkpoints.ordered.index_by(&:position)
      verified = []
      mismatches = []

      result = PIT::Replayer.replay(config: instrument.engine_config,
                                    commands: records.map(&:to_engine_command)) do |engine, applied|
        # The observer counts *applied commands*; checkpoints are keyed by command *position*. Those
        # are the same number only while the log has no gaps, and a gap is always possible: a
        # command id that loses an insert race still advances the position counter. Translate
        # instead of assuming.
        position = records[applied - 1]&.position
        checkpoint = checkpoints[position]
        next unless checkpoint

        row = { position: position, expected: checkpoint.fingerprint, actual: engine.fingerprint }
        row[:match] = (row[:expected] == row[:actual])
        row[:match] ? verified << row : mismatches << row
      end

      Result.new(
        engine: result.engine,
        position: result.commands,
        commands: result.commands,
        events: result.events,
        fingerprint: result.fingerprint,
        verified: verified,
        mismatches: mismatches,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3),
        snapshot: result.engine.snapshot(levels: levels, with_fingerprint: true)
      )
    end

    public

    # What the REST API exposes: the book at that moment, plus the receipts.
    def payload(instrument, upto: nil, levels: 10)
      result = at(instrument, upto: upto, levels: levels)

      result.snapshot.merge(
        "symbol" => instrument.symbol,
        "replayedCommands" => result.commands,
        "replayedEvents" => result.events,
        "fingerprint" => result.fingerprint,
        "faithful" => result.faithful?,
        "checkpointsVerified" => result.verified_checkpoints,
        "mismatches" => result.mismatches,
        "replayMs" => result.duration_ms
      )
    end
  end
end
