# AGENTS.md

Guidance for AI agents (and humans) working in this repository. Read this before changing code.

---

## 1. What this project is

PIT is a **deterministic, replayable limit-order-book matching engine**, served by Rails 8 with a single
SQLite file. The engine lives in `lib/pit/` as plain Ruby; Rails owns durability, transport and projection.

The point of the project is the architecture, not the trading:

- a **pure engine** whose output is a pure function of the commands it is given;
- a **write-ahead log** that is the source of truth, written *before* the engine acts;
- a **replay that verifies itself** against fingerprints captured while the market was live;
- a **publish-only tick** at 10 Hz that never matches and never waits for the database.

**The demo works with zero external infrastructure.** SQLite, no Redis, no broker, no build step.

---

## 2. The invariants to preserve

These are the properties everything else is built on. Breaking one is a design change, not a bug fix.

### The three ordering rules (`MarketFeed#apply`)

1. The command row is written **before** the engine sees the command.
2. Both happen **inside the market's lock**, so the log's order is the engine's order.
3. **Nothing else may mutate the engine.** One `MarketFeed` per instrument, one `Mutex` per feed.

### The engine's rules (`lib/pit/engine.rb`)

Price–time priority; limit orders rest; market orders never rest; `gtc` rests, `ioc` kills the remainder,
`fok` is all-or-nothing and checked before anything trades; fills print at the **maker's** price; an amend
at the same price keeps queue priority and a price change loses it; a cancel removes exactly the remainder;
self-trade prevention per config; **only an order's own actor may cancel or amend it**, and a foreign order
is answered exactly like an unknown one.

### The 14 checks (`lib/pit/invariants.rb`)

Asserted after **every command** in the fuzz suite. If you add state to the engine, add the check that
would catch that state going wrong.

### The determinism contracts (`test/lib/pit/replay_test.rb`)

- same seed + same commands ⇒ same fingerprint;
- a replay of the log reproduces the live fingerprint, from a truncated log too;
- a reordered log produces a **different** book;
- a tampered log fails its own checkpoints.

---

## 3. Stack and the parts that are unusual

| Concern | Choice | Note |
|---|---|---|
| Framework | Rails **8.1.4**, Ruby **3.4** | generated with `--skip-action-mailbox --skip-action-text --skip-jbuilder --skip-active-storage` |
| Engine | plain Ruby in `lib/pit` | **not autoloaded, not reloadable** — required once in `config/initializers/pit_engine.rb`. A matching engine must not be hot-swapped under a live book |
| Database | SQLite, WAL, `synchronous=NORMAL` | Rails' defaults; the store of the log, the projections and the checkpoints |
| Transport | Action Cable, `async` in dev and `solid_cable` in production | state down only; commands go up over HTTP |
| Background | Active Job + Solid Queue in production (`:async` in dev) | persistence happens off the tick thread |
| Front-end | importmap + Stimulus + Propshaft | no Node, no build step; the client only renders |
| Metrics | hand-rolled Prometheus text at `/metrics` | no gem, no exporter |
| Tests | Minitest | engine tests boot **no Rails** |

---

## 4. Package map

```
lib/pit/                ★ PURE ENGINE — no Rails, no clock, no I/O, no Kernel#rand
  prng.rb               xorshift64*, folding the high bits (see gotchas below)
  hasher.rb             FNV-1a 32-bit; fold/2 folds strings, fold_int folds words
  config.rb             tick_size, lot_size, self_trade — the signature is part of a fingerprint
  commands.rb           Submit/Cancel/Amend (intent) + to_h/from_h for the log
  events.rb             Accepted/Rested/Fill/Cancelled/Amended/Done/Rejected (facts) + signature/to_h
  order.rb              hot-loop object; actor_hash precomputed once
  price_level.rb        FIFO queue at one price
  order_book.rb         sorted ladders, binary-search insert, depth
  engine.rb             apply(command) → [events]; matching; validation; ownership; fingerprint
  invariants.rb         the 14 checks
  replayer.rb           fold a log; verify checkpoints in the same pass (via a block)
  fuzz.rb               seeded command generator (tests, bench, synthetic flow)

app/services/           market_feed.rb (lock + log + tick + broadcast), engine_registry.rb,
                        order_entry.rb, synthetic_flow.rb, market_replay.rb, market_metrics.rb
app/channels/           order_book_channel.rb (downstream only), application_cable/connection.rb
app/controllers/        books, orders, metrics, api/{books,replays,fills,markets}
app/jobs/               persist_market_events_job.rb
app/javascript/controllers/market_controller.js
app/views/books/show.html.erb, app/assets/stylesheets/application.css
test/lib/**             engine tests, no Rails            (bin/rails test:engine)
test/{services,models,channels,integration}/            Rails layers (bin/rails test)
bin/bench, bin/rails test:engine, bin/rails pit:bench, docs/BENCHMARKS.md
```

---

## 5. Commands

```bash
bin/rails test           # everything, no Docker
bin/rails test:engine    # engine only — the fastest feedback loop, boots no Rails
bin/bench                # engine + durable append numbers (Rails-free)
bin/rails pit:bench      # the same write path through Active Record
bin/rails db:prepare     # create + migrate + seed
bin/rails server
bin/rubocop && bin/brakeman -q
```

`bin/rails test` must always pass **without Docker** and without Redis. Anything that needs a service
belongs behind an explicit opt-in, not in the default path.

---

## 6. Recipes

### Change a matching rule

1. Edit `lib/pit/engine.rb`. Keep the rule table in the class comment, in `README.md` and in section 2 of
   this file in sync — they are the contract.
2. If the rule can produce new *state*, extend `Invariants.assert_consistent!` so the fuzz suite can catch
   it, and extend `Events.signature` if it changes what the engine emits.
3. Add a focused test in `test/lib/pit/` (`engine_test`, `tif_test`, `amend_test`, `self_trade_test`,
   `ownership_test`, `order_book_test`). Assert the rule, not just the outcome.
4. Run `bin/rails test:engine`, then `bin/rails test`, then `bin/bench` if the change touches the hot loop.
   **Fingerprints will change** — that is expected; reset the development database (delete
   `storage/development.sqlite3`, then `bin/rails db:prepare`) so old checkpoints cannot disagree with new
   code.

### Add a wire message

1. Add `Data.define` to `lib/pit/events.rb` with a `signature` and a `to_h` (the tick broadcasts `to_h`).
2. Emit it from `lib/pit/engine.rb`, and make sure `MarketFeed` projects anything it changes.
3. Render it in `app/javascript/controllers/market_controller.js`.
4. Test it in `test/channels/order_book_channel_test.rb` (use `capture_broadcasts`, not `broadcasts`).

### Add a REST endpoint

1. Controller under `app/controllers/api/`, action, and a route in `config/routes.rb` with an explicit `as:`.
2. Keep it a **read model**: it may call `feed.snapshot(with_fingerprint: true)`, `feed.stats`,
   `MarketReplay` or the projections. It must never mutate the engine.
3. Test it in `test/integration/api_integration_test.rb`.

### Add a metric

1. Extend `MarketMetrics.append_feed`, with `pit_` as the prefix.
2. Add the field to `MarketFeed#stats` if it is missing — metrics read state, they do not take the lock again.
3. Assert the series name in the metrics integration test.

### Add an instrument

Add it in `db/seeds.rb` with its own tick, lot, self-trade policy and seed, then visit `/books/<SYMBOL>`.
There is no runtime creation API yet (roadmap phase 7).

---

## 7. Testing philosophy

- `test/lib/**` is the highest-value suite and boots **no Rails**: `lib/pit` is pure Ruby, so it is tested as
  pure Ruby. `bin/rails test:engine` loads it with `-Ilib` and plain Minitest (`def setup`, not `setup do`).
- `replay_test.rb` is the one that earns its keep: seeded fuzz streams, all 14 invariants after every
  command, and replay verification from a full log, a truncated log and a shuffled log.
- Rails tests build `MarketFeed.new(instrument, ticker: false)` so nothing publishes in the background and
  each test drives `#tick` itself. The registry is reset around every test (`test/test_helper.rb`) because
  engines outlive database transactions.
- If a test needs a job to have run, say so explicitly: `perform_enqueued_jobs`.

---

## 8. Gotchas discovered the hard way

Each of these cost real debugging time. They are written down so they cost it once.

1. **The Active Record query cache is a hazard on every path that reads the log.** It produced three
   distinct bugs here: a replay that verified a stale log, a warm-up that could rebuild the wrong book, and
   an idempotency check that missed a row written moments earlier by the same thread. `warm_up!`,
   `already_logged?` and `MarketReplay.at` therefore wrap their reads in `uncached`. If you add a read that
   must observe your own writes, do the same.
2. **`insert_all` is not an append on SQLite.** It compiles to `INSERT OR IGNORE`, so a duplicate row is
   *silently dropped* — the command would then be applied without being logged, and a replay would diverge.
   The log uses an explicit `INSERT` through `Command.connection` so the unique index actually raises.
3. **Resume from `max(position)`, never from a row count.** Positions can have gaps (a command id that loses
   an insert race still advances the counter). Resuming from a count reuses a position, collides with the
   unique index, and wedges the market: every later command is answered as a duplicate.
4. **Never rewind the position counter on a duplicate.** Check idempotency *before* assigning a position.
   Rewinding puts the next command on the same colliding position — the same wedge, forever.
5. **A state fingerprint is O(book): keep it off the tick path.** The snapshot shipped the fingerprint at
   10 Hz and cost 90 ms a frame. It now ships `stateHash` (O(1), the rolling event hash) and computes the
   full fingerprint only where a receipt is wanted. See `docs/BENCHMARKS.md`.
6. **Ruby's bignum boundary is 2^62.** A 64-bit FNV lands in bignum arithmetic and roughly halves hashing
   throughput; the hasher is 32-bit for that reason.
7. **Folding integers byte by byte is slow in MRI without YJIT** (~185 ns per operation). `fold_int` folds a
   whole word, and `Order#actor_hash` is precomputed once because an order's actor never changes.
8. **`setup do ... end` composes with a parent's `def setup` — and callbacks run first.** Putting
   `EngineRegistry.reset!` in a `def setup` in `test_helper.rb` ran *after* a subclass's `setup do` block and
   wiped the market it had just created. The helper uses `setup do ... end` for exactly that reason.
9. **Mutexes are not reentrant.** `EngineRegistry.feed_for` creates the feed under its lock but *starts* it
   outside, because starting a feed builds services that look the feed up again.
10. **Stop the feeds on exit.** A ticker thread holding the SQLite file makes `db:drop`/`db:reset` fail on
    Windows with a permission error. `config/initializers/pit_engine.rb` registers an `at_exit` hook.
11. **`bin/rails` needs `ruby` in front of it on Windows**, and PowerShell reports a Ruby stderr warning as
    exit code 1 — read the test tally rather than the shell's exit code.
12. **`broadcasts(stream)` returns raw JSON strings.** In channel tests use `capture_broadcasts(stream) { ... }`,
    which decodes them and scopes the capture to the block.

---

## 9. Status and roadmap

See the roadmap table in `README.md`. The next step is **cross-process markets**: the durable log already
lets a second process rebuild from `commands` and take over, so the work is ownership handover rather than
engine work.

---

## 10. Known deliberate trade-offs

- **In-process registry.** One book per process; two Puma workers means two books. Documented, not solved.
- **One lock per market, held across a durable write.** Correctness over throughput, with measured
  contention in `docs/BENCHMARKS.md`.
- **HTTP for commands.** The socket is downstream-only by design.
- **No authentication.** A signed cookie is an *identity for ownership*, not an account. Real auth would slot
  in at `ApplicationController#current_trader` and `ApplicationCable::Connection#connect`, with the engine's
  ownership rule already enforcing the consequence.
