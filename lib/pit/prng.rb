# frozen_string_literal: true

module PIT
  # xorshift64* — a small PRNG whose output is stable across Ruby versions, platforms
  # and processes.
  #
  # `Kernel#rand` is deliberately NOT used anywhere in the engine: its algorithm is an
  # MRI implementation detail, so a "seeded" stream is not reproducible across Ruby
  # releases. Determinism is the property PIT sells, so the engine owns its randomness.
  class Prng
    MASK = 0xFFFFFFFFFFFFFFFF
    GOLDEN_GAMMA = 0x9E3779B97F4A7C15
    MULTIPLIER = 0x2545F4914F6CDD1D

    attr_reader :state

    def initialize(seed)
      @state = seed.to_i & MASK
      @state = GOLDEN_GAMMA if @state.zero? # xorshift64 must never sit on zero
    end

    def next_u64
      x = @state
      x ^= (x << 13) & MASK
      x ^= (x >> 7)
      x ^= (x << 17) & MASK
      @state = x & MASK
      (@state * MULTIPLIER) & MASK
    end

    # Uniform integer in 0...bound.
    #
    # The high bits are used deliberately: with xorshift64* the LOW bits are the least mixed,
    # so `next_u64 % bound` makes nearby seeds agree for thousands of draws (seeds 1 and 2
    # produced identical command streams before this was fixed — see
    # test/lib/pit/engine_test.rb#test_different_seeds_produce_different_books).
    def int(bound)
      raise ArgumentError, "bound must be positive, got #{bound}" unless bound.is_a?(Integer) && bound.positive?
      return 0 if bound == 1

      (next_u64 >> 11) % bound
    end

    # Inclusive range.
    def between(min, max)
      min + int(max - min + 1)
    end

    def pick(collection)
      collection[int(collection.size)]
    end

    def chance(percent)
      int(100) < percent
    end

    def sign
      int(2).zero? ? 1 : -1
    end
  end
end
