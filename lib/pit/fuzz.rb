# frozen_string_literal: true

module PIT
  # A deterministic command generator.
  #
  # Same seed ⇒ same command stream, on any machine, forever. That makes it usable for
  # three different jobs with one implementation:
  #
  #   * the invariant fuzz test  (apply a seeded stream, assert after every command)
  #   * the replay test          (log the stream, replay it, match the fingerprints)
  #   * the benchmark and the    (drive a believable market without a human)
  #     synthetic market feed
  #
  # Because cancellations and amends need *real* order ids, the generator reads the live
  # engine: it is a function of (seed, engine state), which is still perfectly
  # reproducible.
  class Fuzz
    DEFAULT_ACTORS = %w[mm-alpha mm-beta momentum-1 momentum-2 taker-1].freeze

    def initialize(seed:, actors: DEFAULT_ACTORS, reference_price: 10_000, tick: 1, lot: 1)
      @prng = Prng.new(seed)
      @actors = actors
      @reference_price = reference_price
      @tick = tick
      @lot = lot
      @counter = 0
    end

    attr_reader :prng

    # Yields `count` commands, each built from the engine's *current* state.
    def each(engine, count)
      return enum_for(:each, engine, count) unless block_given?

      count.times { yield command(engine) }
    end

    def stream(engine, count)
      each(engine, count).to_a
    end

    def command(engine)
      open = engine.open_orders
      roll = @prng.int(100)

      # Cancel and amend address an existing order, so they belong to whatever actor owns it — the
      # engine refuses to let one actor touch another's order.
      if roll < 18 && !open.empty?
        order = @prng.pick(open)
        Commands.cancel(id: next_id, order_id: order.id, actor: order.actor)
      elsif roll < 28 && !open.empty?
        amend(@prng.pick(open))
      else
        submit(engine)
      end
    end

    private

    def amend(order)
      delta = @prng.between(-3, 3)
      price = order.price + (delta * @tick)
      price = @tick if price < @tick
      Commands.amend(id: next_id, order_id: order.id, price: price,
                     qty: order.remaining + (@prng.between(0, 3) * @lot), actor: order.actor)
    end

    def submit(engine)
      side = @prng.chance(50) ? :buy : :sell
      qty = @prng.between(1, 8) * @lot
      reference = engine.book.mid || engine.book.last_trade_price || @reference_price
      offset = @prng.between(0, 14) * @tick
      price = side == :buy ? reference - offset : reference + offset
      price = @tick if price < @tick
      actor = pick_actor

      if @prng.chance(10)
        Commands.market(id: next_id, side: side, qty: qty, actor: actor)
      else
        tif = @prng.chance(12) ? (@prng.chance(55) ? :ioc : :fok) : :gtc
        Commands.submit(id: next_id, side: side, price: price, qty: qty, tif: tif, actor: actor)
      end
    end

    def pick_actor = @prng.chance(88) ? @prng.pick(@actors) : "retail-#{@prng.int(40)}"

    def next_id
      @counter += 1
      format("c%05d", @counter)
    end
  end
end
