# frozen_string_literal: true

module PIT
  # FNV-1a, folded incrementally — 32-bit on purpose.
  #
  # Two uses:
  #   1. Engine#fingerprint — a fingerprint of the live book, stored in `book_checkpoints` so a
  #      replay can be *proved* to have reproduced history.
  #   2. A rolling hash over every event the engine has ever emitted, so rejected and cancelled
  #      orders are covered too, not just the orders still resting.
  #
  # Why 32 bits rather than 64: Ruby's fixnum/bignum boundary sits at 2^62, and a 64-bit FNV needs a
  # 64-bit multiply per byte, which lands in bignum territory and cost roughly twice as much (137 ms
  # vs 84 ms for a 13k-order book, measured with bin/bench). A 32-bit hash keeps every operation in
  # fixnum range and answers the only question asked of it: "did these two sequences of state produce
  # the same bytes?" A collision would mean a silently faithful replay (~1 in 4 billion per
  # comparison); if you ever needed more than that, the answer is a different verification design, not
  # a bigger hash on this path.
  module Hasher
    OFFSET_BASIS = 0x811C9DC5
    PRIME = 0x01000193
    MASK = 0xFFFFFFFF

    module_function

    def fold(hash, string)
      state = hash
      string.to_s.each_byte { |byte| state = ((state ^ byte) * PRIME) & MASK }
      state
    end

    def hash_of(string)
      fold(OFFSET_BASIS, string)
    end

    def hex(string)
      format("%08x", hash_of(string))
    end

    def hex_of(folded)
      format("%08x", folded & MASK)
    end

    # Folds an integer as one *word*, not as four bytes.
    #
    # A per-byte loop costs ~740 ns per integer in MRI without YJIT (measured with tmp profiling; the
    # four-byte version made a 13k-order book fingerprint cost 66 ms). Folding the whole value in a
    # single xor/multiply is ~4x cheaper and this is a divergence detector, not a cryptographic hash.
    # Values are folded modulo 2^32: this application's prices, quantities and sequence numbers are
    # orders of magnitude below that.
    def fold_int(hash, value)
      ((hash ^ (value.to_i & MASK)) * PRIME) & MASK
    end
  end
end
