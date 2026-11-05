# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_04_120000) do
  create_table "book_checkpoints", force: :cascade do |t|
    t.integer "instrument_id", null: false
    t.bigint "position", null: false
    t.string "fingerprint", null: false
    t.integer "resting_orders", null: false
    t.integer "best_bid"
    t.integer "best_ask"
    t.bigint "trade_seq", null: false
    t.datetime "created_at", null: false
    t.index ["instrument_id", "position"], name: "index_book_checkpoints_on_instrument_id_and_position", unique: true
    t.index ["instrument_id"], name: "index_book_checkpoints_on_instrument_id"
  end

  create_table "commands", force: :cascade do |t|
    t.integer "instrument_id", null: false
    t.bigint "position", null: false
    t.string "kind", null: false
    t.string "actor", null: false
    t.string "command_id", null: false
    t.json "payload", null: false
    t.datetime "created_at", null: false
    t.index ["instrument_id", "command_id"], name: "index_commands_on_instrument_id_and_command_id", unique: true
    t.index ["instrument_id", "position"], name: "index_commands_on_instrument_id_and_position", unique: true
    t.index ["instrument_id"], name: "index_commands_on_instrument_id"
  end

  create_table "fills", force: :cascade do |t|
    t.integer "instrument_id", null: false
    t.bigint "trade_seq", null: false
    t.integer "price", null: false
    t.integer "qty", null: false
    t.bigint "maker_order_id", null: false
    t.bigint "taker_order_id", null: false
    t.string "maker_actor", null: false
    t.string "taker_actor", null: false
    t.string "aggressor", null: false
    t.datetime "created_at", null: false
    t.index ["instrument_id", "trade_seq"], name: "index_fills_on_instrument_id_and_trade_seq", unique: true
    t.index ["instrument_id"], name: "index_fills_on_instrument_id"
  end

  create_table "instruments", force: :cascade do |t|
    t.string "symbol", null: false
    t.integer "tick_size", default: 1, null: false
    t.integer "lot_size", default: 1, null: false
    t.string "self_trade_policy", default: "cancel_resting", null: false
    t.integer "seed", default: 1, null: false
    t.boolean "synthetic_flow", default: false, null: false
    t.integer "synthetic_rate", default: 6, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["symbol"], name: "index_instruments_on_symbol", unique: true
  end

  create_table "orders", force: :cascade do |t|
    t.integer "instrument_id", null: false
    t.bigint "engine_order_id", null: false
    t.string "actor", null: false
    t.string "side", null: false
    t.string "order_type", null: false
    t.string "tif", null: false
    t.integer "price"
    t.integer "qty", null: false
    t.integer "filled", default: 0, null: false
    t.string "status", default: "open", null: false
    t.bigint "seq", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id", "engine_order_id"], name: "index_orders_on_instrument_id_and_engine_order_id", unique: true
    t.index ["instrument_id", "status"], name: "index_orders_on_instrument_id_and_status"
    t.index ["instrument_id"], name: "index_orders_on_instrument_id"
  end

  add_foreign_key "book_checkpoints", "instruments"
  add_foreign_key "commands", "instruments"
  add_foreign_key "fills", "instruments"
  add_foreign_key "orders", "instruments"
end
