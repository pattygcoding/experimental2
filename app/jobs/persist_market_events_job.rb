# frozen_string_literal: true

# Writes fills, order projections and checkpoints to the database.
#
# The feed hands this job a plain hash and returns to broadcasting: a slow database must never
# stretch a tick, exactly as HEXARENA hands match results to a virtual-thread executor. In
# development Active Job runs it in-process (:async); in production it is Solid Queue.
class PersistMarketEventsJob < ApplicationJob
  queue_as :pit

  # Plain-array arguments keep the job payload cheap and JSON-safe.
  def perform(instrument_id, batch)
    instrument_id = instrument_id.to_i
    write_fills(instrument_id, batch["fills"])
    write_orders(instrument_id, batch["orders"])
    write_checkpoints(instrument_id, batch["checkpoints"])
  end

  private

  def write_fills(instrument_id, rows)
    return if rows.blank?

    highest = Fill.where(instrument_id: instrument_id).maximum(:trade_seq) || 0
    fresh = rows.select { |row| row["trade_seq"] > highest }
    return if fresh.empty?

    now = Time.current
    Fill.insert_all(fresh.map { |row| row.merge("created_at" => now) },
                    unique_by: %i[instrument_id trade_seq])
  end

  def write_orders(instrument_id, rows)
    return if rows.blank?

    now = Time.current
    Order.upsert_all(rows.map { |row| row.merge("created_at" => now, "updated_at" => now) },
                     unique_by: %i[instrument_id engine_order_id])
  end

  def write_checkpoints(instrument_id, rows)
    return if rows.blank?

    now = Time.current
    BookCheckpoint.insert_all(rows.map { |row| row.merge("instrument_id" => instrument_id, "created_at" => now) },
                              unique_by: %i[instrument_id position])
  end
end
