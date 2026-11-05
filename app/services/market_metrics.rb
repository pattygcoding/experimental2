# frozen_string_literal: true

# Prometheus text exposition, hand-rolled: no gem, no exporter process, no dependency that could
# drift from what the code actually measures.
#
#   pit_commands_total          every command the acceptor took (logged and applied)
#   pit_fills_total             prints executed
#   pit_filled_quantity_total   lots that changed hands
#   pit_rejected_total          commands the engine refused
#   pit_self_trade_cancels_total self-trade prevention firing
#   pit_resting_orders          orders in the book right now
#   pit_resting_quantity        lots in the book right now
#   pit_best_bid / pit_best_ask the touch
#   pit_tick_duration_ms        p50/p95/p99 of one publish tick
#   pit_snapshot_frames_total   frames broadcast
#   pit_subscribers             connected browsers
#   pit_market_info             fingerprint + warm-up size as labels (1)
module MarketMetrics
  module_function

  def prometheus
    lines = []
    EngineRegistry.feeds.each { |feed| append_feed(lines, feed.stats) }
    lines << ""
    lines.join("\n")
  end

  def append_feed(lines, stats)
    labels = %(symbol="#{stats[:symbol]}")
    counters = stats[:counters]

    lines << "# HELP pit_commands_total Commands accepted by the feed (logged and applied)."
    lines << "# TYPE pit_commands_total counter"
    lines << %(pit_commands_total{#{labels}} #{stats[:commands]})

    lines << "# HELP pit_fills_total Prints executed by the engine."
    lines << "# TYPE pit_fills_total counter"
    lines << %(pit_fills_total{#{labels}} #{stats[:fills]})

    lines << "# HELP pit_filled_quantity_total Lots that changed hands."
    lines << "# TYPE pit_filled_quantity_total counter"
    lines << %(pit_filled_quantity_total{#{labels}} #{counters[:filled_qty] || 0})

    lines << "# HELP pit_rejected_total Commands the engine refused."
    lines << "# TYPE pit_rejected_total counter"
    lines << %(pit_rejected_total{#{labels}} #{counters[:rejected] || 0})

    lines << "# HELP pit_self_trade_cancels_total Self-trade prevention firing."
    lines << "# TYPE pit_self_trade_cancels_total counter"
    lines << %(pit_self_trade_cancels_total{#{labels}} #{counters[:self_trade_events] || 0})

    lines << "# HELP pit_resting_orders Orders resting in the book."
    lines << "# TYPE pit_resting_orders gauge"
    lines << %(pit_resting_orders{#{labels}} #{stats[:resting]})

    lines << "# HELP pit_resting_quantity Lots resting in the book."
    lines << "# TYPE pit_resting_quantity gauge"
    lines << %(pit_resting_quantity{#{labels}} #{stats[:resting_quantity]})

    lines << "# HELP pit_best_bid Best bid, when there is one."
    lines << "# TYPE pit_best_bid gauge"
    lines << %(pit_best_bid{#{labels}} #{stats[:best_bid]}) if stats[:best_bid]

    lines << "# HELP pit_best_ask Best ask, when there is one."
    lines << "# TYPE pit_best_ask gauge"
    lines << %(pit_best_ask{#{labels}} #{stats[:best_ask]}) if stats[:best_ask]

    lines << "# HELP pit_last_trade_price Last traded price."
    lines << "# TYPE pit_last_trade_price gauge"
    lines << %(pit_last_trade_price{#{labels}} #{stats[:last_trade]}) if stats[:last_trade]

    lines << "# HELP pit_tick_duration_ms Time to build and publish one frame."
    lines << "# TYPE pit_tick_duration_ms summary"
    lines << %(pit_tick_duration_ms{#{labels},quantile="0.5"} #{stats[:tick_p50_ms]})
    lines << %(pit_tick_duration_ms{#{labels},quantile="0.95"} #{stats[:tick_p95_ms]})
    lines << %(pit_tick_duration_ms{#{labels},quantile="0.99"} #{stats[:tick_p99_ms]})
    lines << %(pit_tick_duration_ms_count{#{labels}} #{stats[:tick_samples]})

    lines << "# HELP pit_snapshot_frames_total Snapshot frames broadcast."
    lines << "# TYPE pit_snapshot_frames_total counter"
    lines << %(pit_snapshot_frames_total{#{labels}} #{stats[:frames]})

    lines << "# HELP pit_subscribers Connected browsers on the market stream."
    lines << "# TYPE pit_subscribers gauge"
    lines << %(pit_subscribers{#{labels}} #{stats[:subscribers]})

    lines << "# HELP pit_market_info Identity of the running book: the fingerprint proves which"
    lines << "# state this process is holding, and warm_up_commands how much log it replayed."
    lines << "# TYPE pit_market_info gauge"
    lines << %(pit_market_info{#{labels},fingerprint="#{stats[:fingerprint]}",warm_up_commands="#{stats[:warm_up_commands]}",tick_rate="#{MarketFeed::SNAPSHOT_HZ}"} 1)
  end
end
