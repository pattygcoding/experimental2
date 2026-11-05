# frozen_string_literal: true

require "set"

# One live market: the in-memory engine, the lock that serialises it, the write-ahead log, the
# broadcasters, and the checkpoint capture.
#
# This mirrors HEXARENA's tick loop with one deliberate difference. There, the tick *simulates*
# and clients send intent. Here, matching happens synchronously on the thread that accepts the
# order (a request, or the synthetic flow), so the acknowledgement the caller receives already
# contains its fills. The ticker's only job is to *publish*: coalesce state into one snapshot
# frame per tick and hand persistence to a job.
#
# The three ordering rules that make replay exact:
#
#   1. the WAL row is written before the engine sees the command;
#   2. both happen inside the lock, so the log's order is the engine's order;
#   3. nothing else may mutate the engine.
class MarketFeed
  SNAPSHOT_HZ = 10
  CHECKPOINT_EVERY = 100
  TICK_WINDOW = 200
  TAPE_FRAME = 12

  Result = Data.define(:position, :events, :snapshot, :duplicate)

  attr_reader :instrument, :symbol, :boot_token

  def initialize(instrument, ticker: true)
    @instrument = instrument
    @symbol = instrument.symbol
    @ticker = ticker
    @boot_token = SecureRandom.hex(3)
    @mutex = Mutex.new
    @pending_events = []
    @pending_checkpoints = []
    @subscribers = Set.new
    @command_seq = 0
    @persisted_trade_seq = 0
    @tick_ms = []
    @frames = 0
    @running = false
    @thread = nil
    @synthetic = nil
    @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    warm_up!
  end

  # Resume from the durable log. This is the payoff of the design: restart the process and the
  # market comes back *exactly* as it was, because the log — not a snapshot — is the truth.
  def warm_up!
    @engine = PIT::Engine.new(config: @instrument.engine_config)
    @command_seq = 0
    @warm_up_commands = 0

    return if @instrument.new_record?

    # Reading the log is wrapped in `uncached`: a warm-up that resumed from a cached view of the log
    # would rebuild the wrong book, and the whole point of warm-up is that it agrees with the rows.
    Command.uncached do
      Command.where(instrument_id: @instrument.id).ordered.each do |record|
        @engine.apply(record.to_engine_command)
        @warm_up_commands += 1
      end

      # Resume from max(position), never from the number of rows. Positions can have gaps — a
      # duplicate command id that loses a race still advances the counter (see #apply) — and reusing
      # a position would collide with the unique index and, because the counter would then be
      # decremented back onto the same number, wedge the market permanently.
      @command_seq = Command.where(instrument_id: @instrument.id).maximum(:position) || 0
      @persisted_trade_seq = Fill.where(instrument_id: @instrument.id).maximum(:trade_seq) || 0
    end
  end

  attr_reader :warm_up_commands

  # `ticker: false` is the test seam: the feed behaves identically but publishes nothing on its own,
  # so a test can drive #tick by hand and assert on exactly one frame. The registry always builds
  # ticking feeds.
  def start
    return self unless @ticker

    @mutex.synchronize do
      return self if @running

      @running = true
      @thread = Thread.new { run }
      @thread.name = "pit-feed-#{@symbol}"
      @thread.abort_on_exception = false
      start_synthetic_flow
    end
    self
  end

  def stop
    synthetic = nil
    thread = nil
    @mutex.synchronize do
      @running = false
      thread = @thread
      synthetic = @synthetic
      @thread = nil
      @synthetic = nil
    end
    synthetic&.stop
    thread&.wakeup
    thread&.join(2)
  end

  def running? = @running

  # Durable-before-apply, inside the lock. See the class comment for why.
  #
  # Idempotency: a command id that is already in the log is answered with `duplicate: true` and no
  # side effects, so a double-clicked ticket cannot trade twice. The check is a lookup on the unique
  # index rather than "insert and hope it raises", because the counter must not be rewound onto a
  # position that is already taken.
  def apply(command)
    start

    @mutex.synchronize do
      next duplicate_result if already_logged?(command.id)

      @command_seq += 1
      log(command, @command_seq)
      events = @engine.apply(command)
      @pending_events.concat(events)
      capture_checkpoint if (@command_seq % CHECKPOINT_EVERY).zero?

      Result.new(position: @command_seq, events: events, snapshot: snapshot_unlocked, duplicate: false)
    end
  rescue ActiveRecord::RecordNotUnique
    # Two threads submitted the same command id simultaneously and the other one won. The log is
    # intact and this command was never applied; the counter keeps its advance (gaps are fine — see
    # #warm_up!).
    @mutex.synchronize { duplicate_result }
  end

  # ── reads (all under the lock) ────────────────────────────────────────────────────────

  def snapshot(levels: 10, with_fingerprint: false)
    @mutex.synchronize { snapshot_unlocked(levels: levels, with_fingerprint: with_fingerprint) }
  end

  def actor_orders(actor) = @mutex.synchronize { actor_orders_unlocked(actor) }

  def fingerprint = @mutex.synchronize { @engine.fingerprint }

  # A read-only handle for services that need to look at the book before deciding what to send
  # (the synthetic flow asks where the market is before choosing a price). The read is locked;
  # the engine's verdict on whatever comes back is still made under the lock, so a stale read
  # can only produce a benign rejection, never a broken book.
  def engine_view = @mutex.synchronize { @engine }

  def command_count = @mutex.synchronize { @command_seq }

  # Public so the channel can subscribe without knowing the naming scheme.
  def market_stream_name = "pit:market:#{@symbol}"

  def actor_stream_name(actor) = "pit:actor:#{actor}"

  def tape(limit = 20) = @mutex.synchronize { @engine.tape(limit).map { |fill| PIT::Events.to_h(fill) } }

  def subscribe(actor)
    @mutex.synchronize { @subscribers << actor.to_s }
  end

  def unsubscribe(actor)
    @mutex.synchronize { @subscribers.delete(actor.to_s) }
  end

  def stats
    @mutex.synchronize do
      {
        symbol: @symbol,
        commands: @command_seq,
        warm_up_commands: @warm_up_commands,
        fills: @engine.trade_seq,
        resting: @engine.book.resting_count,
        resting_quantity: @engine.book.resting_qty(:buy) + @engine.book.resting_qty(:sell),
        best_bid: @engine.book.best_bid,
        best_ask: @engine.book.best_ask,
        last_trade: @engine.last_trade_price,
        fingerprint: @engine.fingerprint,
        counters: @engine.counters.dup,
        subscribers: @subscribers.size,
        running: @running,
        frames: @frames,
        synthetic: @synthetic&.stats,
        uptime_ms: elapsed_ms(@started_at)
      }.merge(tick_stats_unlocked)
    end
  end
  # ── the tick loop ─────────────────────────────────────────────────────────────────────

  def run
    interval = 1.0 / SNAPSHOT_HZ
    while running?
      sleep interval
      tick
    end
  rescue StandardError => e
    Rails.logger.error("[pit] feed #{@symbol} ticker died: #{e.class}: #{e.message}")
    @running = false
  end

  # One tick: take the lock only long enough to build the next frame, then publish and persist
  # outside it. The ticker never matches and never waits for the database.
  def tick
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    frame, events, fills, orders, checkpoints = @mutex.synchronize do
      drained = @pending_events
      @pending_events = []
      captured = @pending_checkpoints
      @pending_checkpoints = []
      touched = drained.filter_map { |event| order_id_of(event) }.uniq

      [ snapshot_unlocked, drained, drained.grep(PIT::Events::Fill),
       touched.filter_map { |id| @engine.order(id) }, captured ]
    end

    publish(frame)
    publish_events(events)
    persist(fills, orders, checkpoints)

    @tick_ms << (elapsed_ms(started))
    @tick_ms.shift while @tick_ms.size > TICK_WINDOW
    @frames += 1
    self
  end

  private

  def publish(frame)
    ActionCable.server.broadcast(market_stream, frame)
  end

  def publish_events(events)
    return if events.empty?

    ActionCable.server.broadcast(market_stream, {
      "type" => "events", "symbol" => @symbol,
      "events" => events.map { |event| PIT::Events.to_h(event) }
    })
    actors_touched_by(events).each do |actor|
      ActionCable.server.broadcast(actor_stream_name(actor), {
        "type" => "yourOrders", "symbol" => @symbol, "orders" => actor_orders(actor)
      })
    end
  end

  def persist(fills, orders, checkpoints)
    return if fills.empty? && orders.empty? && checkpoints.empty?

    PersistMarketEventsJob.perform_later(@instrument.id, {
      "fills" => fills.map { |fill| fill_row(fill) },
      "orders" => orders.map { |order| order_row(order) },
      "checkpoints" => checkpoints
    })
  end

  def actors_touched_by(events)
    actors = events.filter_map { |event| event.respond_to?(:actor) ? event.actor : nil }
    actors.concat(events.grep(PIT::Events::Fill).flat_map { |fill| [ fill.maker_actor, fill.taker_actor ] })
    actors.uniq
  end

  def order_id_of(event)
    case event
    when PIT::Events::Accepted, PIT::Events::Rested, PIT::Events::Cancelled, PIT::Events::Amended,
         PIT::Events::Done then event.order_id
    when PIT::Events::Fill then event.taker_order_id
    end
  end

  # ── write-ahead log + checkpoints ─────────────────────────────────────────────────────

  def log(command, position)
    # A raw, single-row INSERT rather than Command.create! or insert_all. Both alternatives were
    # measured, and both got something wrong (docs/BENCHMARKS.md):
    #
    #   Command.create!     ~8.5 ms — an ActiveRecord object, its validations, its callbacks and its
    #                                 type coercion, on a path that only needs to append a row.
    #   Command.insert_all  ~1.1 ms — but on SQLite it compiles to INSERT OR IGNORE, so a duplicate
    #                                 command id is *silently dropped* and the command would then be
    #                                 applied to the engine without being logged. That is a
    #                                 determinism bug, not a performance win.
    #
    # An explicit INSERT costs the same ~1.1 ms as insert_all and lets the unique index on
    # (instrument_id, command_id) raise, which is what makes a double-submitted form idempotent.
    connection = Command.connection

    connection.exec_insert(<<~SQL.squish)
      INSERT INTO commands (instrument_id, position, kind, actor, command_id, payload, created_at)
      VALUES (
        #{connection.quote(@instrument.id)},
        #{connection.quote(position)},
        #{connection.quote(kind_of(command))},
        #{connection.quote(command.actor)},
        #{connection.quote(command.id)},
        #{connection.quote(PIT::Commands.to_h(command).to_json)},
        #{connection.quote(Time.current)}
      )
    SQL
  end

  # The idempotency lookup: one index-only read, and the reason a double-submitted form is safe.
  #
  # `uncached` is load-bearing. This read must observe a row written moments ago by the *same*
  # thread; the query cache is per-connection and per-request, and without this the second submit of
  # an identical command id looked up a cached `false`, went on to insert, hit the unique index and
  # burned a position. Cheap read, expensive cache.
  def already_logged?(command_id)
    Command.uncached do
      Command.where(instrument_id: @instrument.id, command_id: command_id.to_s).exists?
    end
  end

  def duplicate_result
    Result.new(position: @command_seq, events: [], snapshot: snapshot_unlocked, duplicate: true)
  end

  def kind_of(command)
    case command
    when PIT::Commands::Submit then "submit"
    when PIT::Commands::Cancel then "cancel"
    when PIT::Commands::Amend then "amend"
    end
  end

  def capture_checkpoint
    @pending_checkpoints << {
      "position" => @command_seq,
      "fingerprint" => @engine.fingerprint,
      "resting_orders" => @engine.book.resting_count,
      "best_bid" => @engine.book.best_bid,
      "best_ask" => @engine.book.best_ask,
      "trade_seq" => @engine.trade_seq
    }
  end

  # ── projections ───────────────────────────────────────────────────────────────────────

  def order_row(order)
    {
      "instrument_id" => @instrument.id, "engine_order_id" => order.id, "actor" => order.actor,
      "side" => order.side.to_s, "order_type" => order.type.to_s, "tif" => order.tif.to_s,
      "price" => order.price, "qty" => order.qty, "filled" => order.filled,
      "status" => order.status.to_s, "seq" => order.seq
    }
  end

  def fill_row(fill)
    {
      "instrument_id" => @instrument.id, "trade_seq" => fill.trade_seq, "price" => fill.price,
      "qty" => fill.qty, "maker_order_id" => fill.maker_order_id, "taker_order_id" => fill.taker_order_id,
      "maker_actor" => fill.maker_actor, "taker_actor" => fill.taker_actor,
      "aggressor" => fill.aggressor.to_s
    }
  end

  # The tick's payload. Deliberately fingerprint-free: a state fingerprint is O(resting orders), and
  # this runs inside the feed lock ten times a second. `stateHash` — the rolling hash of the event
  # history — is O(1) and is what the browser displays; the full fingerprint is available on request
  # from the REST read model, and written into `book_checkpoints` every 100 commands.
  def snapshot_unlocked(levels: 10, with_fingerprint: false)
    @engine.snapshot(levels: levels, with_fingerprint: with_fingerprint).merge(
      "type" => "snapshot",
      "symbol" => @symbol,
      "tickRate" => SNAPSHOT_HZ,
      "commandCount" => @command_seq,
      "tape" => @engine.tape(TAPE_FRAME).map { |fill| PIT::Events.to_h(fill) }
    )
  end

  def actor_orders_unlocked(actor)
    @engine.open_orders.select { |order| order.actor == actor }.sort_by(&:seq).map do |order|
      { "orderId" => order.id, "side" => order.side.to_s, "orderType" => order.type.to_s,
        "tif" => order.tif.to_s, "price" => order.price, "qty" => order.qty,
        "filled" => order.filled, "remaining" => order.remaining, "seq" => order.seq }
    end
  end

  def market_stream = "pit:market:#{@symbol}"

  def start_synthetic_flow
    return unless @instrument.synthetic_flow?

    @synthetic = SyntheticFlow.new(self, @instrument).start
  end

  def tick_stats_unlocked
    samples = @tick_ms.sort
    {
      tick_p50_ms: percentile(samples, 0.50),
      tick_p95_ms: percentile(samples, 0.95),
      tick_p99_ms: percentile(samples, 0.99),
      tick_samples: samples.size
    }
  end

  def percentile(sorted, fraction)
    return 0.0 if sorted.empty?

    sorted[[ (sorted.size * fraction).floor, sorted.size - 1 ].min]
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3)
  end
end
