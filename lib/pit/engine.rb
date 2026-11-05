# frozen_string_literal: true

module PIT
  # The matching engine: a transition function over commands.
  #
  #   engine.apply(command) # => [event, ...]
  #
  # It is not thread-safe by design — the Rails layer owns the lock (see
  # app/services/market_feed.rb), exactly as HEXARENA's `Match` owns the lock for its
  # `GameWorld`. Everything the engine needs comes in through the command; everything it
  # produces comes out as events. Given the same config and the same commands, two engines
  # in two processes produce the same fingerprint, forever.
  #
  # Rules implemented (this list is the contract; AGENTS.md repeats it):
  #   * price-time priority — better price first, arrival order within a price
  #   * limit orders rest; market orders never rest (their remainder is killed)
  #   * tif: gtc rests, ioc kills the remainder, fok is all-or-nothing up front
  #   * fills print at the *maker's* price (the taker gets price improvement)
  #   * amending at the same price keeps queue position; changing price loses it
  #   * self-trade prevention: cancel the resting order, stop matching, or allow
  class Engine
    TAPE_LIMIT = 200

    attr_reader :config, :book, :orders, :counters, :seq, :trade_seq, :next_order_id

    def initialize(config: Config.default)
      @config = config.is_a?(Config) ? config : Config.from_hash(config)
      @book = OrderBook.new
      @orders = {}                 # id => Order, open *and* closed (the WAL is the archive)
      @counters = Hash.new(0)
      @seq = 0                     # monotonic: order ids and event ordering
      @trade_seq = 0               # monotonic: the tape
      @next_order_id = 0
      @tape = []                   # most recent fills, oldest first
      @rolling_hash = Hasher::OFFSET_BASIS
    end

    def tick_size = @config.tick_size
    def lot_size = @config.lot_size
    def self_trade_policy = @config.self_trade

    # ── the transition function ───────────────────────────────────────────────────────

    def apply(command)
      events =
        case command
        when Commands::Submit then submit(command)
        when Commands::Cancel then cancel(command)
        when Commands::Amend then amend(command)
        else raise ArgumentError, "unknown command: #{command.inspect}"
        end

      @counters[:commands] += 1
      events.each { |event| fold(event) }
      events
    end

    def apply_all(commands)
      commands.flat_map { |command| apply(command) }
    end

    # ── reads ─────────────────────────────────────────────────────────────────────────

    def order(id) = @orders[id.to_i]

    def open_orders = @orders.each_value.select(&:open?)

    def tape(limit = 20) = @tape.last(limit)

    def depth(side, levels = 10) = @book.depth(side, levels)

    def last_trade_price = @book.last_trade_price

    # Fingerprints the live book *and* every event ever emitted, so a replay that reproduces the book
    # but drops a rejected order still fails verification.
    #
    # O(resting orders) by nature: it is a hash of the state, not of the history. It is therefore
    # computed where a receipt is wanted — at checkpoint capture, for a replay's verdict, in the REST
    # read model — and deliberately NOT on the tick path. The tick ships `snapshot["stateHash"]`, which
    # is the rolling hash of the event history and costs nothing.
    def fingerprint
      hash = Hasher.fold(@rolling_hash, @config.signature)
      hash = Hasher.fold_int(hash, @seq)
      hash = Hasher.fold_int(hash, @trade_seq)
      hash = Hasher.fold_int(hash, @next_order_id)

      @book.each_resting do |order|
        hash = Hasher.fold_int(hash, order.side == :buy ? 1 : 2)
        hash = Hasher.fold_int(hash, order.price)
        hash = Hasher.fold_int(hash, order.remaining)
        hash = Hasher.fold_int(hash, order.seq)
        hash = Hasher.fold_int(hash, order.actor_hash)
      end

      Hasher.hex_of(hash)
    end

    def snapshot(levels: 10, with_fingerprint: false)
      frame = {
        "seq" => @seq,
        "tradeSeq" => @trade_seq,
        "stateHash" => Hasher.hex_of(@rolling_hash),
        "lastTradePrice" => last_trade_price,
        "bestBid" => @book.best_bid,
        "bestAsk" => @book.best_ask,
        "spread" => @book.spread,
        "mid" => @book.mid,
        "restingOrders" => @book.resting_count,
        "bids" => depth(:buy, levels),
        "asks" => depth(:sell, levels)
      }
      frame["fingerprint"] = fingerprint if with_fingerprint
      frame
    end
    # ── commands ──────────────────────────────────────────────────────────────────────

    def submit(command)
      reason = invalid_submission(command)
      return [ reject(command, reason) ] if reason

      if command.tif == :fok && fillable_qty(command.side, command.price, command.actor) < command.qty
        return [ reject(command, :insufficient_liquidity) ]
      end

      order = Order.new(id: bump_order_id, actor: command.actor, side: command.side,
                        type: command.type, price: command.price, qty: command.qty,
                        tif: command.tif, seq: next_seq, command_id: command.id)
      @orders[order.id] = order
      @counters[:submitted] += 1

      events = [ Events::Accepted.new(seq: order.seq, order_id: order.id, side: order.side,
                                     type: order.type, tif: order.tif, price: order.price,
                                     qty: order.qty, actor: order.actor) ]
      events.concat(match(order))
      events
    end

    def cancel(command)
      order = owned_order(command)
      return [ reject(command, :unknown_order) ] if order.nil?
      return [ reject(command, :not_open) ] unless order.open?

      level = @book.find_level(order.side, order.price)
      level&.remove(order)
      @book.drop_level(order.side, level) if level
      order.status = :cancelled
      @counters[:cancelled] += 1

      [ Events::Cancelled.new(seq: next_seq, order_id: order.id, qty: order.remaining,
                             reason: :requested, actor: order.actor) ]
    end

    def amend(command)
      order = owned_order(command)
      return [ reject(command, :unknown_order) ] if order.nil?
      return [ reject(command, :not_open) ] unless order.open?
      return [ reject(command, :invalid_quantity) ] unless valid_quantity?(command.qty)
      return [ reject(command, :invalid_price) ] unless valid_price?(command.price)
      return [ reject(command, :below_filled) ] if command.qty < order.filled

      @counters[:amended] += 1
      remaining = command.qty - order.filled

      if command.price == order.price
        # Same price: the order keeps its place in the queue. This is the rule everyone gets
        # wrong, and test/lib/pit/amend_test.rb exists to keep us honest about it.
        level = @book.find_level(order.side, order.price)
        level.qty += (remaining - order.remaining)
        order.remaining = remaining
        order.qty = command.qty
        [ Events::Amended.new(seq: next_seq, order_id: order.id, price: order.price, qty: remaining,
                             kept_priority: true, actor: order.actor) ]
      else
        # New price: priority is lost. Leave the book, take a fresh sequence number and
        # re-enter — which means an amend can trade.
        level = @book.find_level(order.side, order.price)
        level&.remove(order)
        @book.drop_level(order.side, level) if level
        order.price = command.price
        order.qty = command.qty
        order.remaining = remaining
        order.seq = next_seq

        events = [ Events::Amended.new(seq: order.seq, order_id: order.id, price: order.price,
                                      qty: remaining, kept_priority: false, actor: order.actor) ]
        events.concat(match(order))
        events
      end
    end
    # ── matching ──────────────────────────────────────────────────────────────────────

    # Walks the opposite ladder while the order is marketable, printing fills at the maker's
    # price. Leaves the order resting, cancelled or filled.
    def match(order)
      events = []

      loop do
        break unless order.liquid?

        level = @book.ladder(opposite(order.side)).first
        break if level.nil?
        break unless crosses?(order, level.price)

        maker = level.head

        if maker.actor == order.actor && @config.self_trade != :off
          @counters[:self_trade_events] += 1
          if @config.self_trade == :cancel_resting
            level.remove(maker)
            maker.status = :cancelled
            events << Events::Cancelled.new(seq: next_seq, order_id: maker.id, qty: maker.remaining,
                                            reason: :self_trade, actor: maker.actor)
            @book.drop_level(maker.side, level)
            next
          else
            # :skip — stop matching. The remainder must NOT rest: it would rest inside the
            # price of our own order, which would cross the book. It is cancelled instead.
            order.stp_blocked = true
            break
          end
        end

        traded = [ order.remaining, maker.remaining ].min
        order.remaining -= traded
        maker.remaining -= traded
        level.qty -= traded
        @trade_seq += 1
        @counters[:fills] += 1
        @counters[:filled_qty] += traded
        @book.last_trade_price = level.price

        fill = Events::Fill.new(seq: next_seq, trade_seq: @trade_seq, price: level.price, qty: traded,
                                maker_order_id: maker.id, maker_actor: maker.actor,
                                taker_order_id: order.id, taker_actor: order.actor,
                                aggressor: order.side)
        events << fill
        push_tape(fill)

        next unless maker.remaining.zero?

        maker.status = :filled
        level.remove(maker)
        @counters[:completed] += 1
        events << Events::Done.new(seq: next_seq, order_id: maker.id, actor: maker.actor)
        @book.drop_level(maker.side, level)
      end

      events.concat(finish(order))
      events
    end

    # How much could trade right now against the given price ceiling/floor. Used for the FOK
    # liquidity check; self-trade prevention subtracts resting own orders.
    def fillable_qty(side, price, actor)
      total = 0
      @book.ladder(opposite(side)).each do |level|
        break unless price.nil? || (side == :buy ? level.price <= price : level.price >= price)

        level.each do |order|
          next if order.actor == actor && @config.self_trade == :cancel_resting

          total += order.remaining
        end
      end
      total
    end
    private

    def finish(order)
      if order.remaining.zero?
        order.status = :filled
        @counters[:completed] += 1
        [ Events::Done.new(seq: next_seq, order_id: order.id, actor: order.actor) ]
      elsif order.stp_blocked
        # Self-trade prevention stopped the match; the remainder is cancelled, never rested.
        order.status = :cancelled
        @counters[:killed] += 1
        [ Events::Cancelled.new(seq: next_seq, order_id: order.id, qty: order.remaining,
                               reason: :self_trade, actor: order.actor) ]
      elsif order.market? || order.tif == :ioc || order.tif == :fok
        reason = order.market? ? :no_liquidity : order.tif
        order.status = :cancelled
        @counters[:killed] += 1
        [ Events::Cancelled.new(seq: next_seq, order_id: order.id, qty: order.remaining,
                               reason: reason, actor: order.actor) ]
      else
        @book.rest(order)
        [ Events::Rested.new(seq: next_seq, order_id: order.id, price: order.price,
                            qty: order.remaining, actor: order.actor) ]
      end
    end

    def crosses?(order, contra_price)
      return true if order.market?

      order.buy? ? contra_price <= order.price : contra_price >= order.price
    end

    def invalid_submission(command)
      return :invalid_lot_size unless valid_quantity?(command.qty)
      return :invalid_price if command.market? && !command.price.nil?
      return :invalid_price unless command.market? || valid_price?(command.price)

      nil
    end

    # An order is only addressable by the actor that owns it, and a cancel or amend from anyone else
    # is answered exactly like an unknown order id: the engine must not confirm that another trader's
    # order exists. This was a real bug here — the synthetic flow amended and cancelled other traders'
    # orders, because the actor on the command was never checked against the order's actor.
    def owned_order(command)
      order = @orders[command.order_id]
      return nil if order.nil?
      return nil unless order.actor == command.actor

      order
    end

    def valid_quantity?(qty)
      qty.is_a?(Integer) && qty.positive? && (qty % @config.lot_size).zero?
    end

    def valid_price?(price)
      return false unless price.is_a?(Integer) && price.positive?

      (price % @config.tick_size).zero?
    end

    def reject(command, reason)
      @counters[:rejected] += 1
      Events::Rejected.new(command_id: command.id, reason: reason, actor: command.actor)
    end

    def fold(event)
      @rolling_hash = Hasher.fold(@rolling_hash, Events.signature(event))
    end

    def push_tape(fill)
      @tape << fill
      @tape.shift while @tape.size > TAPE_LIMIT
    end

    def next_seq
      @seq += 1
    end

    def bump_order_id
      @next_order_id += 1
    end

    def opposite(side) = side == :buy ? :sell : :buy
  end
end
