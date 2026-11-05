# frozen_string_literal: true

# The engine tests deliberately boot WITHOUT Rails: lib/pit is pure Ruby, so it is tested as
# pure Ruby. Run them on their own with:
#
#   bin/rails test:engine
#
# They are also picked up by `bin/rails test`, which is convenient but slower.
require "minitest/autorun"
require_relative "../../lib/pit"

module EngineTestHelper
  def build_engine(**options)
    PIT::Engine.new(config: PIT::Config.default(**options))
  end

  def submit(engine, id:, side:, qty:, price: nil, type: :limit, tif: :gtc, actor: "trader")
    engine.apply(PIT::Commands.submit(id: id, side: side, qty: qty, price: price,
                                      type: type, tif: tif, actor: actor))
  end

  # Cancel and amend act as the order's owner by default, because most tests are about the book, not
  # about ownership. Pass `actor:` explicitly to test who may touch an order — see ownership_test.rb.
  def cancel(engine, id:, order_id:, actor: nil)
    engine.apply(PIT::Commands.cancel(id: id, order_id: order_id, actor: actor || owner_of(engine, order_id)))
  end

  def amend(engine, id:, order_id:, price:, qty:, actor: nil)
    engine.apply(PIT::Commands.amend(id: id, order_id: order_id, price: price, qty: qty,
                                     actor: actor || owner_of(engine, order_id)))
  end

  def owner_of(engine, order_id)
    engine.order(order_id)&.actor || "trader"
  end

  def events_named(events, name)
    events.select { |event| event.is_a?(PIT::Events.const_get(name)) }
  end

  def event_names(events)
    events.map { |event| event.class.name.split("::").last }
  end

  def assert_consistent!(engine)
    PIT::Invariants.assert_consistent!(engine)
  end

  # Generates a seeded command stream, applies it, and returns the commands.
  def seeded_commands(seed:, count:, engine: nil)
    engine ||= build_engine
    commands = PIT::Fuzz.new(seed: seed).stream(engine, count)
    commands.each { |command| engine.apply(command) }
    commands
  end
end
