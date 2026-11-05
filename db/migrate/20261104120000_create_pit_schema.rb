# frozen_string_literal: true

# The whole storage model for one market:
#
#   commands          append-only write-ahead log — THE source of truth
#   orders            a projection, rebuilt from the log at any time
#   fills             the tape, written off the matching path by a background job
#   book_checkpoints  the fingerprint of the book after every N commands
#
# Nothing here stores the book itself. The book is derivable, and `book_checkpoints` is what
# lets us prove a replay reproduced it.
class CreatePitSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :instruments do |t|
      t.string  :symbol, null: false
      t.integer :tick_size, null: false, default: 1
      t.integer :lot_size, null: false, default: 1
      t.string  :self_trade_policy, null: false, default: "cancel_resting"
      t.integer :seed, null: false, default: 1
      t.boolean :synthetic_flow, null: false, default: false
      t.integer :synthetic_rate, null: false, default: 6
      t.timestamps
    end
    add_index :instruments, :symbol, unique: true

    create_table :commands do |t|
      t.references :instrument, null: false, foreign_key: true
      t.bigint :position, null: false, comment: "per-instrument ordinal: the log's total order"
      t.string :kind, null: false
      t.string :actor, null: false
      t.string :command_id, null: false, comment: "the caller's command id, for idempotency"
      t.json   :payload, null: false
      t.datetime :created_at, null: false
    end
    add_index :commands, %i[instrument_id position], unique: true
    add_index :commands, %i[instrument_id command_id], unique: true

    create_table :orders do |t|
      t.references :instrument, null: false, foreign_key: true
      t.bigint :engine_order_id, null: false
      t.string :actor, null: false
      t.string :side, null: false
      t.string :order_type, null: false
      t.string :tif, null: false
      t.integer :price
      t.integer :qty, null: false
      t.integer :filled, null: false, default: 0
      t.string :status, null: false, default: "open"
      t.bigint :seq, null: false
      t.timestamps
    end
    add_index :orders, %i[instrument_id engine_order_id], unique: true
    add_index :orders, %i[instrument_id status]

    create_table :fills do |t|
      t.references :instrument, null: false, foreign_key: true
      t.bigint  :trade_seq, null: false
      t.integer :price, null: false
      t.integer :qty, null: false
      t.bigint  :maker_order_id, null: false
      t.bigint  :taker_order_id, null: false
      t.string  :maker_actor, null: false
      t.string  :taker_actor, null: false
      t.string  :aggressor, null: false
      t.datetime :created_at, null: false
    end
    add_index :fills, %i[instrument_id trade_seq], unique: true

    create_table :book_checkpoints do |t|
      t.references :instrument, null: false, foreign_key: true
      t.bigint  :position, null: false
      t.string  :fingerprint, null: false
      t.integer :resting_orders, null: false
      t.integer :best_bid
      t.integer :best_ask
      t.bigint  :trade_seq, null: false
      t.datetime :created_at, null: false
    end
    add_index :book_checkpoints, %i[instrument_id position], unique: true
  end
end
