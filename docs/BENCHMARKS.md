# Benchmarks

Every number here was produced on the machine this repository was built on, by the two commands named
next to each table. Nothing is estimated, extrapolated or rounded up.

```bash
bin/bench            # Rails-free: engine, hashing, snapshot, durable append
bin/rails pit:bench  # the same write path through Active Record, for comparison
```

## Machine

| | |
|---|---|
| CPU | 24 cores |
| OS | Windows (x64-mingw-ucrt) |
| Ruby | 3.4.7, **built without YJIT** (`RubyVM::YJIT` is not defined) |
| Rails | 8.1.4 |
| SQLite | via the `sqlite3` gem 2.10, `journal_mode=wal`, `synchronous=NORMAL` |

The missing YJIT matters: a YJIT build would move the arithmetic-bound numbers (hashing, matching) and
leave the I/O-bound ones (the commit) where they are. These are MRI-without-YJIT numbers, and they are
the honest floor for this machine.

## The engine — `bin/bench`

20,000 commands from the seeded fuzzer (`PIT::Fuzz`, seed 20261104), which mixes submits, cancels and
amends between several actors:

| measurement | value | rate |
|---|---|---|
| 20k mixed commands | 0.0273 ms | 36,641 commands/s |
| rest a limit order behind a deep book | 0.0186 ms | binary-search insert + FIFO append |
| submit an order that crosses one level | 0.0227 ms | price-time match, one fill |
| cancel a resting order | 0.0096 ms | level lookup + removal |
| amend at the same price (keeps priority) | 0.0100 ms | in-place quantity change |
| snapshot one frame (10 levels) | 0.0077 ms | the payload the tick broadcasts at 10 Hz |
| fingerprint the whole book (12,897 orders) | 23.2 ms | full state fingerprint |
| replay 20k commands from scratch | 0.0400 ms | 24,989 commands/s |
| replay fingerprint == live fingerprint | true | |

After the run the book held **12,897 resting orders**, 3,767 fills and 9,818 lots traded, with every
invariant intact.

## The durable append

The engine never sees a command until its write-ahead log row is committed, so this is the cost of the
design's central claim. Measured two ways, because two different things are being measured.

`bin/bench` (raw SQLite, no Rails — the storage floor):

| measurement | value |
|---|---|
| INSERT + commit | **0.10 ms** |
| INSERT, 1,000 rows in one transaction | 0.04 ms |

`bin/rails pit:bench` (the same table, through Active Record, one transaction so the comparison is about
Ruby and AR rather than fsync):

| path | ms/row | what the time is |
|---|---|---|
| `Command.create!` | 6.17 – 8.16 | an AR object: instantiation, validations, callbacks, type coercion |
| `Command.insert_all` | 1.15 | **unusable here**: SQLite compiles it to `INSERT OR IGNORE`, so a duplicate command id is silently dropped instead of raising |
| raw `INSERT` via the AR connection | 0.99 – 1.37 | AR's statement instrumentation, plus every query being logged in development |
| raw `INSERT`, AR logger off | **0.36** | the same insert with quiet logging — closest to production |
| raw SQLite, no Rails at all | **0.10** | the commit itself |

So the app writes its log the way that table suggests: an explicit `INSERT` through
`Command.connection`, costing ~0.36 ms per accepted command in a quiet production-ish process and
~1.4 ms in development where every statement is logged. `Command.create!`'s extra ~6-8 ms — 95% of its
cost — buys nothing on an append-only log.

## The tick budget

`MarketFeed` publishes one snapshot frame per tick at 10 Hz. Two measurements, before and after a fix
this benchmark forced:

| | snapshot frame | what it contained |
|---|---|---|
| initially | **90.5 ms** | the snapshot included the full state fingerprint, computed inside the feed lock |
| after moving the fingerprint off the tick path | **0.0077 ms** | depth, tape, counters, and the O(1) rolling event hash |

The tick no longer touches anything O(book). The full fingerprint is still computed — at checkpoint
capture, in the REST read model, and for a replay's verdict — but never ten times a second, and never
merely to draw a number in a browser.

Live tick timings from a 25-second run of the default configuration (synthetic flow at 6 commands/s,
188 commands, 200 frames), measured by the feed itself:

| | p50 | p95 | p99 |
|---|---|---|---|
| tick publish | 0.573 ms | 3.163 ms | 8.043 ms |

The p95/p99 tail is lock contention, not hashing: an accepted order holds the feed lock for the duration
of one durable append, and when two writers meet on SQLite the later one waits. At 40 commands/s (ten
times the default) the same p95 rises to ~40 ms. Correctness first, one writer at a time — the same
trade-off HEXARENA documents for its per-match lock.

## Hashing cost, and why the hasher is 32-bit

`Engine#fingerprint` walks every resting order, so its cost is O(book). Three versions were measured on
the same 12,897-order book, which is why the current one looks the way it does:

| implementation | fingerprint cost |
|---|---|
| FNV-1a 64-bit, per-byte fold, string interpolation per order | 137 ms |
| FNV-1a 32-bit, per-byte fold | 84 ms |
| FNV-1a 32-bit, integers folded as words (+ precomputed actor hash) | **23 ms** |

The 64-bit version was slower because Ruby's fixnum/bignum boundary is at 2^62: a 64-bit FNV multiply
lands in bignum arithmetic, roughly halving throughput. A 32-bit accumulator keeps every operation in
fixnum range. A collision would mean a silently faithful replay — about 1 in 4 billion per comparison —
which is a fine price for a divergence detector on this path.

## What is not benchmarked

- **Multi-process.** The registry is in-process by design (see AGENTS.md); a second Puma worker owns a
  second book. Cross-instance ownership is the roadmap item, and it would need its own numbers.
- **Sustained load.** These are short runs on a developer machine with a background synthetic flow, not a
  soak test with a load generator.
- **Action Cable fan-out.** The socket path is exercised (the UI updates in the browser), but no
  measurement is claimed for many subscribers on the `async` adapter versus `solid_cable`.
