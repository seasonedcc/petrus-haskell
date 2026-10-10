# Local Dispatch benchmarks: Haskell vs the Python reference

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` drive the same
custody round trips through the public Local Dispatch surface:
`LocalDispatch(path, instance=...)`, `dispatch`, a `LocalWorkerDispatch`'s
`claim` and `complete`, and `collect`. Every workload runs over a fresh SQLite
file, which is created and then deleted along with its `-wal` and `-shm` side
files.

Each Python line prints a result size (the number of collected outcomes). The
Haskell bench prints the same sizes on start-up: `sizes: roundtrip-db-clock
50, roundtrip-provider-clock 50, roundtrip-held-open 50`.

Both sides set the reference's pragmas on every connection they open:
`busy_timeout=5000`, `foreign_keys=ON`, `synchronous=FULL` and
`journal_mode=WAL`. Every write is one `BEGIN IMMEDIATE` transaction. So
these rows mostly time SQLite file IO (lock, WAL append, fsync), not the
adapter code.

The two sides differ in how long a connection lives (DIVERGENCES.md (15)):
- the reference opens a connection per operation and closes its writing
  connections at once, while its read-only `with _connect(path)` blocks
  leave theirs open until the garbage collector reaches them;
- the Haskell session keeps up to four idle connections in a pool
  (`Petrus.Sqlite.Pool`) and reuses them, with their prepared statements,
  until the session closes (`withLocalDispatch` / `closeLocalDispatch`).
  The bench closes the session at the end of every workload, so the WAL
  checkpoint and deletion happen once per workload inside the timing.

The workloads:

- **open-fresh.** Creating the schema in a new file: the DDL, the version
  row, and the shape validation.
- **roundtrip-1.** Open the dispatch, then one dispatch → claim → complete →
  collect.
- **roundtrip-50-db-clock.** Open the dispatch, then 50 `dispatch`es. One
  worker claims and completes all 50 (51 claims, the last one empty). One
  `collect` returns 50 outcomes. Time comes from the database clock.
- **roundtrip-50-provider-clock.** The same 50 round trips, with time from a
  provider clock that advances one millisecond per reading.
- **roundtrip-50-held-open.** The database-clock round trips, while a
  co-resident connection holds the file open. An application that keeps its
  own connection to the same file is in this position, for example with
  `SqliteHistoryStore` beside the dispatch.

## How to rerun

From the repository root:

    cabal bench petrus-motus --benchmark-options '+RTS -M2G -RTS'

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python -I -B ../../packages/petrus-motus/bench/python_bench.py

Haskell numbers are tasty-bench means. Python numbers are the median of
10–20 runs after one warm-up.

The runs took place on 2026-10-10 on an Apple M4 with 24 GB of memory:
- GHC 9.10.3 (`-O2`, `-A32m`) with direct-sqlite 2.3.29, which bundles SQLite
  3.45.0;
- CPython 3.14.6 with SQLite 3.53.4;
- the reference pinned at `upstream/petrus` 3f85fc2.

Three rounds ran interleaved: the Haskell bench before the connection pool
(commit f80e0c3), the Haskell bench with it, then the reference, three
times over. Other work shared the machine, with a load average of 3.2–5.8.
Each figure below is the median of the three rounds.

## Results

| workload | size | Haskell before | Haskell | Python | Python / Haskell before | Python / Haskell |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| open-fresh | 0 | 0.607 ms | 0.616 ms | 0.792 ms | 1.30× | 1.29× |
| roundtrip-1 | 1 | 3.19 ms | 1.57 ms | 2.64 ms | 0.83× | 1.68× |
| roundtrip-50-db-clock | 50 | 71.3 ms | 15.4 ms | 55.8 ms | 0.78× | 3.6× |
| roundtrip-50-provider-clock | 50 | 71.4 ms | 15.3 ms | 55.7 ms | 0.78× | 3.6× |
| roundtrip-50-held-open | 50 | 30.9 ms | 16.3 ms | 40.1 ms | 1.30× | 2.5× |

The rounds (Haskell, then Python):
- open-fresh: 0.610, 0.627, 0.616 ms against 0.684, 0.792, 0.853 ms;
- roundtrip-1: 1.57, 1.60, 1.49 ms against 2.64, 2.64, 2.81 ms;
- roundtrip-50-db-clock: 15.4, 16.0, 15.2 ms against 50.1, 55.8, 63.3 ms;
- roundtrip-50-provider-clock: 15.5, 15.3, 14.8 ms against 50.8, 55.7,
  65.6 ms;
- roundtrip-50-held-open: 15.6, 16.3, 16.9 ms against 37.2, 40.1, 45.6 ms.

The Python bench also prints `*-closing` variants, in which the
reference's read-only connections close at the end of their `with` block.
They are the reference with every connection closed deterministically, and
so the worst case for WAL checkpoints. They took 0.77 ms (open-fresh),
3.96 ms (roundtrip-1), 94.2 ms (db-clock) and 92.8 ms (provider-clock).
They are no longer the equal-IO comparison: the Haskell rows above now beat
the reference's plain rows.

## Notes

- **Sessions keep their connections open.** Before the pool, the Haskell
  port opened and closed a connection for every operation. With nothing
  else holding the file open, every close was the last one, so SQLite
  checkpointed the WAL and deleted it, at the cost of several fsyncs per
  operation. The reference mostly escapes this by accident: its read-only
  `with _connect(path)` blocks only commit on exit, and those connections
  linger until the cyclic garbage collector reaches them.

  The pool goes further than the reference's lingering connections. It also
  saves the open itself, the four pragmas, and the statement preparation,
  since `Petrus.Sqlite.Connection` caches prepared statements per
  connection. That is why the Haskell rows are now faster than the
  reference's `held-open` row too.

  Rows, statements and transactions are identical: every write is still one
  `BEGIN IMMEDIATE`, lease expiry still sweeps at claim time, and other
  processes (the reference among them) see the same file. The interop suite
  checks this (`test/Petrus/Motus/Dispatch/LocalInteropSpec.hs`). Only the
  moment of the WAL checkpoint differs. See DIVERGENCES.md (15).
- **open-fresh does not change.** Creating a schema needs one connection
  without WAL mode and one with it, and the bench then closes the session;
  the pool saves nothing there.
- **The two sides link different SQLite builds.** direct-sqlite bundles SQLite
  3.45.0, while the reference's CPython links 3.53.4. Both builds default to
  `synchronous=2` and `wal_synchronous=2`, and both set `synchronous=FULL`
  explicitly. Neither enables `fullfsync`. With per-open cost off the hot
  path, the port did not need a newer SQLite.

# Worker runtime benchmarks

The `worker` and `async-worker` rows of the same two benches time the
Worker runtime (`Petrus.Motus.Worker` / `petrus.motus.worker`). Event lines
are silenced on both sides. On the Haskell side the Workers' `output` writes
nowhere; on the Python side `_say` is patched to a no-op.

## Workloads

- **worker/local-50.** Dispatch 50 occurrences into a fresh Local file. A
  `Worker` over a `LocalWorkerDispatch` runs every available Attempt
  (`runAvailable` / `run_available`), and one `collect` returns the 50
  outcomes.
- **worker/local-50-held-open.** The same, while a co-resident connection
  holds the file open.
- **worker/memory-1000.** A `Worker` runs 1000 ready Attempts from
  in-memory custody. This is the runtime's own cost per Attempt: claim,
  resolve, execute, normalize the result, and complete.
- **async-worker/memory-1000-c{1,8,64}.** The `AsyncWorker` runs 1000
  in-memory Attempts at concurrency 1, 8 and 64. It uses the sync bridge, so
  each slot has one lane thread. It stops once custody is empty and the
  admitted Activities have drained.
- **async-worker/sleep-1ms-200-c{1,8,64}.** The same with 200 Attempts whose
  Activity sleeps 1 ms (`threadDelay` / `asyncio.sleep`). These rows show
  the concurrency actually achieved.

## How to rerun

These rows are part of the commands above.

tasty-bench cannot settle on sleep-driven work, so the Haskell bench times
the three `sleep` rows itself and prints them before the tasty-bench groups
start. Each of those rows is the median of 10 runs after one warm-up, in the
Python bench's format. Every other Haskell row is a tasty-bench mean
(± 2σ). Python rows are medians of 10–20 runs after one warm-up.

## Results

These rows come from the same three interleaved rounds as the Local
Dispatch rows above, on the same machine and toolchains, at a load average
of 3.2–5.8. Each figure is the median of the three rounds. "Haskell before"
is the bench before the connection pool (commit f80e0c3).

| workload | size | Haskell before | Haskell | Python | Python / Haskell before | Python / Haskell |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| worker/local-50 | 50 | 71.9 ms | 16.2 ms | 55.7 ms | 0.77× | 3.4× |
| worker/local-50-held-open | 50 | 31.6 ms | 16.5 ms | 41.8 ms | 1.32× | 2.5× |
| worker/memory-1000 | 1000 | 1.47 ms | 1.42 ms | 14.5 ms | 9.9× | 10× |
| async-worker/memory-1000-c1 | 1000 | 3.10 ms | 3.10 ms | 271 ms | 87× | 87× |
| async-worker/memory-1000-c8 | 1000 | 3.08 ms | 3.05 ms | 142 ms | 46× | 47× |
| async-worker/memory-1000-c64 | 1000 | 3.09 ms | 3.22 ms | 140 ms | 45× | 43× |
| async-worker/sleep-1ms-200-c1 | 200 | 255 ms | 254 ms | 312 ms | 1.22× | 1.23× |
| async-worker/sleep-1ms-200-c8 | 200 | 32.5 ms | 32.3 ms | 37.2 ms | 1.15× | 1.15× |
| async-worker/sleep-1ms-200-c64 | 200 | 5.61 ms | 5.58 ms | 34.9 ms | 6.2× | 6.3× |

The rounds of the two Local rows (Haskell, then Python):
- worker/local-50: 16.1, 16.7, 16.2 ms against 54.4, 63.1, 55.7 ms;
- worker/local-50-held-open: 16.4, 16.5, 17.2 ms against 37.4, 42.7,
  41.8 ms.

## Worker notes

- **`worker/local-50` follows the Local Dispatch.** The Worker adds only
  one extra claim, which finds the queue empty, to the Local round trip.
  Its `LocalWorkerDispatch` shares the session's connection pool, so it no
  longer pays SQLite's last-close checkpoint on every operation (the first
  note above, and DIVERGENCES.md (15)). The row went from 0.77× to 3.4×.
- **The runtime's own cost is an order of magnitude lower.** The memory rows
  take SQLite out of the picture. The synchronous Worker spends about 1.4 µs
  per Attempt, against about 14.5 µs in Python.

  The AsyncWorker's sync bridge hands every custody call to the slot's lane
  thread. In Haskell that hop is a few microseconds between GHC threads. In
  Python, the thread-to-event-loop round trips cost 140–270 µs per Attempt.
- **Sleep-driven concurrency.** 200 Activities of 1 ms each cannot finish in
  less than 200 ms at concurrency 1, or 25 ms at concurrency 8.

  At concurrency 1 the Haskell AsyncWorker spends about 1.27 ms per Activity
  end to end, against about 1.56 ms in Python.

  At concurrency 64 the floor is about 3.1 ms. Haskell takes about 5.6 ms,
  while Python takes 32–37 ms to schedule 64 lanes through its event loop.
