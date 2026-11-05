# frozen_string_literal: true

# PIT — a deterministic limit-order-book matching engine.
#
# Everything under lib/pit is PURE RUBY: no Rails, no ActiveRecord, no clock, no
# `Kernel#rand`, no I/O. The engine is a transition function over commands, which is
# what makes the whole system provable:
#
#   * the same seed + the same command stream always produce the same book
#     (Engine#fingerprint), and
#   * a replay of the durable command log reproduces history exactly — verified
#     against the fingerprints stored in `book_checkpoints`.
#
# Read AGENTS.md before changing anything in here.
require_relative "pit/prng"
require_relative "pit/hasher"
require_relative "pit/config"
require_relative "pit/commands"
require_relative "pit/events"
require_relative "pit/order"
require_relative "pit/price_level"
require_relative "pit/order_book"
require_relative "pit/engine"
require_relative "pit/invariants"
require_relative "pit/replayer"
require_relative "pit/fuzz"

module PIT
  VERSION = "0.1.0"
end
