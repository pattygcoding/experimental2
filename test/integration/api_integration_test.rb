# frozen_string_literal: true

require "test_helper"

# The HTTP surface: the read model, the replay endpoint, the Prometheus exposition, the health check
# and the ticket. Nothing here asserts the engine's rules — those live in test/lib/pit — but every
# test asserts that the transport is thin.
class ApiIntegrationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @instrument = instruments(:pit_usd)
    @feed = EngineRegistry.feed_for(@instrument)
  end

  def place(attributes = {})
    post book_orders_path(@instrument.symbol),
         params: { side: "buy", type: "limit", tif: "gtc", price: 9_999, qty: 4,
                   command_id: "it-#{SecureRandom.hex(4)}" }.merge(attributes)
    follow_redirect!
  end

  test "the market screen renders the ladder from the server, before any javascript runs" do
    place(price: 9_995, qty: 3, command_id: "render-me")

    get book_path(@instrument.symbol)

    assert_response :success
    assert_select "h2", /PIT-USD/
    assert_select "tbody[data-market-target=bids] tr.ladder-row.bid td.price", "9995"
    assert_select "[data-controller=market][data-market-symbol-value=?]", @instrument.symbol
    assert_select "ol[data-market-target=eventLog]"
    assert_select "section.replay-panel"
  end

  test "the ticket posts, the engine answers, and the flash says what happened" do
    place(price: 9_991, qty: 7, command_id: "flash-me")

    assert_response :success
    assert_select "p.flash.notice", /resting 7/
    assert_equal 1, Command.where(instrument_id: @instrument.id).count
  end

  test "a market rule violation comes back as a flash, not a 500" do
    place(price: 9_999.5, command_id: "fractional")

    assert_select "p.flash.alert", /whole number/
    assert_equal 0, Command.where(instrument_id: @instrument.id).count
  end

  test "the live book is available as json" do
    place(price: 9_990, qty: 2, command_id: "json-me")
    @feed.tick

    get api_book_path(@instrument.symbol), as: :json

    assert_response :success
    body = response.parsed_body

    assert_equal @instrument.symbol, body["symbol"]
    assert_equal 9_990, body["bestBid"]
    assert_equal 2, body["bids"].first["qty"]
    assert_match(/\A[0-9a-f]{8}\z/, body["fingerprint"])
    assert_equal 1, body["commandCount"]
    assert_includes body.keys, "tick"
  end

  test "the replay endpoint rebuilds the book and reports its receipts" do
    place(price: 9_990, qty: 2, command_id: "replay-me")
    @feed.tick
    perform_enqueued_jobs

    get api_book_replay_path(@instrument.symbol), as: :json

    assert_response :success
    body = response.parsed_body

    assert_equal 1, body["replayedCommands"]
    assert body["faithful"]
    assert_equal [], body["mismatches"]
    assert_equal @feed.fingerprint, body["fingerprint"],
                 "the rebuild must agree with the book that is live right now"
    assert body["matchesLive"], "replaying the whole log reproduces the live book"
    assert_equal body["fingerprint"], body["liveFingerprint"]
    assert_operator body["replayMs"], :>=, 0
  end

  test "the replay endpoint can rebuild the book at an earlier command" do
    3.times { |i| place(price: 9_990 + i, qty: 1, command_id: "hist-#{i}") }

    get api_book_replay_path(@instrument.symbol, at: 2), as: :json

    body = response.parsed_body

    assert_equal 2, body["replayedCommands"]
    assert_equal 2, body["restingOrders"], "only the first two commands are in that book"
  end

  test "the fills endpoint reads the persistence path, not the engine" do
    place(side: "buy", price: 9_990, qty: 1, command_id: "fill-a")
    # A second browser, because a trader crossing themselves is refused by the self-trade policy.
    OrderEntry.new(@instrument, actor: "another-browser")
              .submit(side: "sell", type: "limit", tif: "gtc", price: 9_990, qty: 1, command_id: "fill-b")
    @feed.tick
    perform_enqueued_jobs

    get api_book_fills_path(@instrument.symbol), as: :json

    body = response.parsed_body

    assert_equal 1, body["count"]
    assert_equal 1, body["fills"].first["qty"]
    assert_equal 9_990, body["fills"].first["price"]
    assert_equal "another-browser", body["fills"].first["takerActor"],
                 "the API trader's resting bid was the maker; the second browser crossed it"
    assert_equal "sell", body["fills"].first["aggressor"]
  end

  test "crossing yourself through the api is refused, not filled" do
    place(side: "buy", price: 9_990, qty: 2, command_id: "self-a")
    place(side: "sell", price: 9_990, qty: 2, command_id: "self-b")
    @feed.tick
    perform_enqueued_jobs

    assert_equal 0, Fill.where(instrument_id: @instrument.id).count, "no print, because no trade"
    assert_nil @feed.snapshot["bestBid"], "cancel_resting cancelled our own resting bid"
    assert_equal 9_990, @feed.snapshot["bestAsk"], "and the aggressor's remainder rested instead"
  end

  test "the markets endpoint lists every feed this process is running" do
    get api_markets_path, as: :json

    body = response.parsed_body

    assert_equal 1, body["count"]
    assert_equal @instrument.symbol, body["markets"].first["symbol"]
  end

  test "metrics are exposed in prometheus text format" do
    place(price: 9_990, qty: 1, command_id: "metrics-me")
    @feed.tick

    get metrics_path

    assert_response :success
    assert_match(/pit_commands_total\{symbol="PIT-USD"\} 1/, response.body)
    assert_match(/pit_resting_orders\{symbol="PIT-USD"\} 1/, response.body)
    assert_match(/pit_tick_duration_ms\{symbol="PIT-USD",quantile="0\.95"\}/, response.body)
    assert_match(/pit_market_info\{symbol="PIT-USD",fingerprint="[0-9a-f]{8}"/, response.body)
  end

  test "the health endpoint is up" do
    get rails_health_check_path

    assert_response :success
  end

  test "the root redirects to the default instrument's book" do
    get root_path

    assert_redirected_to book_path(Instrument.default.symbol)
  end

  test "a trader cannot cancel another actor's order" do
    placed = OrderEntry.new(@instrument, actor: "another-browser", feed: @feed)
                       .submit(side: "buy", type: "limit", tif: "gtc", price: 9_880, qty: 2,
                               command_id: "victim")
    victim_id = placed.events.find { |event| event.is_a?(PIT::Events::Accepted) }.order_id

    delete "/books/#{@instrument.symbol}/orders/#{victim_id}"

    assert_redirected_to book_path(@instrument.symbol)
    assert_equal "Rejected: unknown order", flash[:alert],
                 "a foreign order is reported exactly like an unknown one"
    assert_equal 2, @feed.snapshot["bids"].first[:qty], "the order is still resting"
  end

  test "cancelling through the api reaches the same engine" do
    place(price: 9_990, qty: 3, command_id: "cancel-api")
    @feed.tick
    perform_enqueued_jobs
    actor = Order.where(instrument_id: @instrument.id).order(:id).last.actor
    order_id = @feed.actor_orders(actor).first["orderId"]

    delete "/books/#{@instrument.symbol}/orders/#{order_id}"

    assert_redirected_to book_path(@instrument.symbol)
    assert_equal 0, @feed.snapshot["restingOrders"]
    assert_equal 2, Command.where(instrument_id: @instrument.id).count, "the cancel is logged too"
  end
end
