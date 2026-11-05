import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"

// The client is deliberately thin, exactly like HEXARENA's: it renders frames the server has
// already decided and sends nothing but "please cancel order #12". It never computes a price,
// never matches, never decides who traded with whom.
export default class extends Controller {
  static targets = [
    "bids", "asks", "tape", "eventLog", "myOrders", "myOrderCount",
    "bestBid", "bestAsk", "spread", "lastTrade", "tapeCount",
    "replayAt", "replayResult", "liveFingerprint", "liveCommands"
  ]

  static values = { symbol: String }

  connect() {
    this.logLines = []
    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "OrderBookChannel", symbol: this.symbolValue },
      { received: (frame) => this.receive(frame) }
    )
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
  }

  receive(frame) {
    switch (frame.type) {
      case "snapshot": this.renderSnapshot(frame); break
      case "events": this.appendEvents(frame.events); break
      case "yourOrders": this.renderMyOrders(frame.orders); break
      case "hello": this.toast(`connected to ${frame.symbol} as ${frame.trader} @ ${frame.tickRate} Hz`); break
    }
  }

  // ── rendering ──────────────────────────────────────────────────────────────────────

  renderSnapshot(snapshot) {
    // Asks are drawn worst-price-first so the touch sits in the middle of the ladder.
    this.renderLadder(this.asksTarget, [...snapshot.asks].reverse(), "ask")
    this.renderLadder(this.bidsTarget, snapshot.bids, "bid")

    this.bestBidTarget.textContent = snapshot.bestBid ?? "—"
    this.bestAskTarget.textContent = snapshot.bestAsk ?? "—"
    this.spreadTarget.textContent = snapshot.spread ?? "—"
    this.lastTradeTarget.textContent = snapshot.lastTradePrice ?? "—"
    this.renderTape(snapshot.tape)

    if (this.hasLiveFingerprintTarget) this.liveFingerprintTarget.textContent = snapshot.stateHash
    if (this.hasLiveCommandsTarget) this.liveCommandsTarget.textContent = snapshot.commandCount
    if (this.hasReplayAtTarget) this.replayAtTarget.max = snapshot.commandCount
  }

  renderLadder(tbody, levels, side) {
    const deepest = Math.max(1, ...levels.map((level) => level.qty))
    tbody.innerHTML = levels.map((level) => {
      const depth = Math.round((level.qty / deepest) * 100)
      return `<tr class="ladder-row ${side}" style="--depth:${depth}%">` +
             `<td class="price">${level.price}</td>` +
             `<td class="qty">${level.qty}</td>` +
             `<td class="cum">${level.cumulative}</td></tr>`
    }).join("")
  }

  renderTape(fills) {
    if (!this.hasTapeTarget) return
    const deepest = Math.max(1, ...fills.map((fill) => fill.qty))
    this.tapeTarget.innerHTML = [...fills].reverse().map((fill) => {
      const depth = Math.round((fill.qty / deepest) * 40)
      return `<tr class="${fill.aggressor}" style="--depth:${depth}%">` +
             `<td>#${fill.tradeSeq}</td><td>${fill.price}</td>` +
             `<td>${fill.qty}</td><td>${fill.aggressor}</td></tr>`
    }).join("")
    if (this.hasTapeCountTarget) this.tapeCountTarget.textContent = fills.length
  }

  renderMyOrders(orders) {
    if (!this.hasMyOrdersTarget) return
    this.myOrdersTarget.innerHTML = orders.map((order) => (
      `<tr data-order-id="${order.orderId}">` +
      `<td>#${order.orderId}</td>` +
      `<td class="${order.side}">${order.side}</td>` +
      `<td>${order.price ?? "mkt"}</td>` +
      `<td>${order.remaining}</td>` +
      `<td><button type="button" data-action="market#cancelOrder" data-order-id="${order.orderId}">cancel</button></td>` +
      `</tr>`
    )).join("")
    if (this.hasMyOrderCountTarget) this.myOrderCountTarget.textContent = orders.length
  }

  appendEvents(events) {
    events.forEach((event) => this.toast(this.describe(event)))
  }

  describe(event) {
    switch (event.type) {
      case "accepted":
        return `#${event.seq} accept #${event.orderId} ${event.side} ${event.qty}${event.price ? "@" + event.price : " mkt"} ${event.tif} · ${event.actor}`
      case "fill":
        return `#${event.seq} FILL ${event.qty}@${event.price} · print #${event.tradeSeq} maker #${event.makerOrderId} (${event.makerActor}) ← taker #${event.takerOrderId} (${event.takerActor})`
      case "rested":
        return `#${event.seq} rest #${event.orderId} ${event.qty}@${event.price}`
      case "cancelled":
        return `#${event.seq} cancel #${event.orderId} ${event.qty} (${event.reason})`
      case "amended":
        return `#${event.seq} amend #${event.orderId} ${event.qty}@${event.price} ${event.keptPriority ? "keeps priority" : "loses priority"}`
      case "done":
        return `#${event.seq} done #${event.orderId}`
      case "rejected":
        return `rejected ${event.commandId} (${event.reason})`
      default:
        return event.type
    }
  }

  toast(line) {
    this.logLines.unshift(line)
    this.logLines = this.logLines.slice(0, 30)
    if (this.hasEventLogTarget) {
      this.eventLogTarget.innerHTML = this.logLines.map((text) => `<li>${text}</li>`).join("")
    }
  }

  // ── actions ────────────────────────────────────────────────────────────────────────

  async cancelOrder(event) {
    const orderId = event.target.dataset.orderId
    const response = await fetch(`${window.location.pathname}/orders/${orderId}`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": this.csrfToken(), Accept: "text/html" }
    })
    this.toast(`${response.ok ? "cancel" : "cancel failed"} #${orderId} requested — the log gets it first`)
  }

  async replay() {
    if (!this.hasReplayResultTarget) return
    const at = this.hasReplayAtTarget ? this.replayAtTarget.value : ""
    const started = performance.now()
    const response = await fetch(`/api/books/${this.symbolValue}/replay?at=${encodeURIComponent(at)}`, {
      headers: { Accept: "application/json" }
    })
    const data = await response.json()
    const wall = Math.round(performance.now() - started)
    const checked = data.checkpointsVerified + data.mismatches.length
    const verdict = data.faithful
      ? `<span class="ok">${data.checkpointsVerified} checkpoints reproduced exactly</span>`
      : `<span class="bad">${data.mismatches.length} of ${checked} checkpoints disagreed</span>`
    const live = data.matchesLive === undefined
      ? ""
      : `<dt>rebuilt == live</dt><dd>${data.matchesLive
          ? '<span class="ok">yes — the log reproduces the running book exactly</span>'
          : '<span class="bad">no — the rebuild diverged from the live book</span>'}</dd>`

    this.replayResultTarget.innerHTML =
      `<dt>rebuilt from the log</dt>` +
      `<dd>${data.replayedCommands} commands ⇒ ${data.replayedEvents} events in ${data.replayMs} ms ` +
      `(server) / ${wall} ms (round trip)</dd>` +
      `<dt>fingerprint at command ${data.replayedCommands}</dt><dd><code>${data.fingerprint}</code></dd>` +
      `<dt>receipts</dt><dd>${verdict}</dd>` +
      live +
      `<dt>book at that instant</dt>` +
      `<dd>${data.restingOrders} resting · bid ${data.bestBid ?? "—"} · ask ${data.bestAsk ?? "—"}</dd>`
  }

  csrfToken() {
    return document.querySelector("meta[name=csrf-token]")?.content
  }
}
