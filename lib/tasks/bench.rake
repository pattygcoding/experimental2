# frozen_string_literal: true

# What an ActiveRecord object costs on the write-ahead log path, measured against the same table the
# app uses. Run with `bin/rails pit:bench`.
#
# This is the *relative* number: an AR object versus a raw INSERT, both inside one transaction (so
# the comparison is about Ruby and Active Record, not about fsync). The absolute durable-append
# floor — one INSERT, committed — is measured Rails-free by `bin/bench`.
namespace :pit do
  desc "Measure ActiveRecord's cost on the write-ahead log path (vs a raw INSERT)"
  task bench: :environment do
    require "benchmark"

    instrument = Instrument.default
    abort "no instruments — run bin/rails db:seed" unless instrument

    payload = PIT::Commands.to_h(PIT::Commands.submit(id: "x", side: :buy, price: 1, qty: 1,
                                                      actor: "bench"))
    base = 900_000_000
    rounds = 500

    puts "WAL append cost — #{rounds} rows each, one transaction, table `commands`"

    report = lambda do |label, elapsed|
      puts format("  %-42s %9.4f ms/row", label, elapsed / rounds * 1000)
    end

    ActiveRecord::Base.transaction do
      report.call("Command.create!", Benchmark.measure do
        rounds.times do |i|
          Command.create!(instrument_id: instrument.id, position: base + i, kind: "submit",
                          actor: "bench", command_id: "ar-#{i}", payload: payload)
        end
      end.real)

      report.call("Command.insert_all (SQLite: INSERT OR IGNORE)", Benchmark.measure do
        rounds.times do |i|
          Command.insert_all([ { instrument_id: instrument.id, position: base + 100_000 + i,
                                 kind: "submit", actor: "bench", command_id: "ia-#{i}",
                                 payload: payload, created_at: Time.current } ])
        end
      end.real)

      report.call("raw INSERT via connection.quote", Benchmark.measure do
        connection = Command.connection
        rounds.times do |i|
          connection.exec_insert(<<~SQL.squish)
            INSERT INTO commands (instrument_id, position, kind, actor, command_id, payload, created_at)
            VALUES (#{connection.quote(instrument.id)}, #{connection.quote(base + 200_000 + i)},
                    'submit', 'bench', 'raw-#{i}', #{connection.quote(payload.to_json)},
                    #{connection.quote(Time.current)})
          SQL
        end
      end.real)

      raise ActiveRecord::Rollback
    end

    puts
    puts "Note: Command.insert_all compiles to INSERT OR IGNORE on SQLite, so it cannot be used for a"
    puts "write-ahead log — a duplicate command id would be silently dropped instead of raising."
  end
end
