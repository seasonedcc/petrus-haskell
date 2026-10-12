# Local Dispatch benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources aa2fb3b82c43c6d6 at da947286fe9c -->

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

## Current figures

Measured on 2026-10-12, 09:43–09:48 local (UTC-3), at commit `da94728`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.95–2.39:
five interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-motus 5

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory, except `local.open-fresh` and the `async-worker/sleep-*` rows
(below); Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The `*-closing` rows are the
Python-only variants described under the Local Dispatch results below. The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

`local.open-fresh` is now timed with the twin's protocol
(`Petrus.TestSupport.BenchTwin`): one warm-up call, then the median of 20
single calls, as `python_bench.py` times it, so both sides are measured
the same way. This corrects the measurement; it is not a speed-up. Schema
initialization is fsync-bound: strace counts the same eight syncs per open
on both sides, and tasty-bench's mean took in every slow file-system period
that the twin's median of 20 leaves out. Timed alike, the row is level, as
it was before: 1.01× in this run (0.98× in the closest repetition), each
side's figure swinging by up to 10% between repetitions. The connection
pool cannot help this row (see the notes), and there is no adapter work
left in it to take out. The sleep-bound `async-worker/sleep-*` rows are
medians of 10 runs after a warm-up on both sides, and now run after the
tasty rows, as the twin runs them after its Local rows.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `async-worker/sleep-1ms-200-c1` | 239 ms | 332 ms | 1.39× | 1.34× | 238 ms, 231 ms, 239 ms, 239 ms, 240 ms | 324 ms, 332 ms, 356 ms, 319 ms, 348 ms |
| `async-worker/sleep-1ms-200-c8` | 31.9 ms | 35.4 ms | 1.11× | 1.11× | 31.5 ms, 31.9 ms, 31.9 ms, 31.8 ms, 32 ms | 35.4 ms, 35.4 ms, 35.3 ms, 35.3 ms, 35.4 ms |
| `async-worker/sleep-1ms-200-c64` | 8.45 ms | 28.9 ms | 3.42× | 3.36× | 8.45 ms, 8.54 ms, 8.41 ms, 8.54 ms, 8.2 ms | 29.4 ms, 28.7 ms, 28.9 ms, 28.7 ms, 29.1 ms |
| `local.open-fresh` | 635 µs | 644 µs | 1.01× | 0.98× | 639 µs, 633 µs, 628 µs, 635 µs, 636 µs | 664 µs, 644 µs, 616 µs, 623 µs, 682 µs |
| `local.roundtrip-1` | 1.45 ms | 2.31 ms | 1.59× | 1.54× | 1.44 ms, 1.46 ms, 1.41 ms, 1.48 ms, 1.45 ms | 2.33 ms, 2.25 ms, 2.26 ms, 2.31 ms, 2.32 ms |
| `local.roundtrip-50-db-clock` | 14.5 ms | 49 ms | 3.38× | 3.26× | 15 ms, 14.6 ms, 14.5 ms, 14.1 ms, 14 ms | 49 ms, 50.5 ms, 48.6 ms, 48.7 ms, 49.7 ms |
| `local.roundtrip-50-provider-clock` | 14.3 ms | 48.3 ms | 3.37× | 3.22× | 14.3 ms, 14.7 ms, 14.3 ms, 13.7 ms, 14.4 ms | 50.7 ms, 47.1 ms, 48.3 ms, 46.5 ms, 49.6 ms |
| `local.roundtrip-50-held-open` | 14.6 ms | 32.6 ms | 2.24× | 2.18× | 14.8 ms, 14.6 ms, 15 ms, 14.6 ms, 14 ms | 33.3 ms, 32.8 ms, 32.6 ms, 32.6 ms, 32.4 ms |
| `worker.local-50` | 14.5 ms | 49.4 ms | 3.41× | 3.28× | 14.6 ms, 14.5 ms, 14.5 ms, 14.5 ms, 14.3 ms | 50.2 ms, 49.4 ms, 48.6 ms, 47.4 ms, 51.1 ms |
| `worker.local-50-held-open` | 14.6 ms | 33.8 ms | 2.32× | 2.24× | 14.9 ms, 14.4 ms, 14.6 ms, 14.6 ms, 14.5 ms | 34.8 ms, 33.8 ms, 33.4 ms, 32.8 ms, 36 ms |
| `worker.memory-1000` | 1.38 ms | 13.8 ms | 10.01× | 9.85× | 1.38 ms, 1.37 ms, 1.38 ms, 1.4 ms, 1.4 ms | 13.9 ms, 13.7 ms, 14 ms, 13.8 ms, 13.8 ms |
| `async-worker.memory-1000-c1` | 2.65 ms | 206 ms | 77.59× | 76.60× | 2.65 ms, 2.64 ms, 2.66 ms, 2.65 ms, 2.69 ms | 206 ms, 207 ms, 205 ms, 203 ms, 206 ms |
| `async-worker.memory-1000-c8` | 2.51 ms | 105 ms | 41.82× | 41.07× | 2.51 ms, 2.47 ms, 2.5 ms, 2.51 ms, 2.51 ms | 105 ms, 105 ms, 104 ms, 103 ms, 106 ms |
| `async-worker.memory-1000-c64` | 2.57 ms | 111 ms | 43.06× | 42.21× | 2.59 ms, 2.53 ms, 2.56 ms, 2.59 ms, 2.57 ms | 120 ms, 112 ms, 110 ms, 109 ms, 111 ms |
| `local/open-fresh-closing` | — | 644 µs | — | — |  | 656 µs, 635 µs, 644 µs, 613 µs, 649 µs |
| `local/roundtrip-1-closing` | — | 3.57 ms | — | — |  | 3.61 ms, 3.58 ms, 3.57 ms, 3.52 ms, 3.53 ms |
| `local/roundtrip-50-db-clock-closing` | — | 78.7 ms | — | — |  | 79.2 ms, 75.4 ms, 80.5 ms, 76.2 ms, 78.7 ms |
| `local/roundtrip-50-provider-clock-closing` | — | 76 ms | — | — |  | 77 ms, 76 ms, 73.8 ms, 72 ms, 79 ms |

## How to rerun

From the repository root (`scripts/bench petrus-motus` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-motus --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-motus/bench/python_bench.py)
```

Haskell numbers are tasty-bench means in wall-clock time (`localOption
WallTime` in `bench/Main.hs`), `--stdev 5`, `+RTS -M2G`. Python numbers are the
median of 10–20 runs after one warm-up (`time.perf_counter`).

The runs took place on 2026-10-10, 21:33–21:39 local (UTC-3), at commit
`74e6b1e` with the switch to wall-clock time, on an Apple M4 with 24 GB of
memory shared with other agents (load average 3.6–5.8):
- GHC 9.10.3 (`-O2`, `-A32m`) with direct-sqlite 2.3.29, which bundles SQLite
  3.45.0;
- CPython 3.14.6 with SQLite 3.53.4;
- the reference pinned at `upstream/petrus` 3f85fc2.

Two repetitions ran interleaved (Haskell, Python, then Python, Haskell). Each
figure below is the median of the two.

## Results

<!-- bench: superseded -->

| workload | size | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: | ---: |
| open-fresh | 0 | 0.885 ms | 0.899 ms | 1.02× |
| roundtrip-1 | 1 | 2.34 ms | 3.92 ms | 1.68× |
| roundtrip-50-db-clock | 50 | 22.0 ms | 65.9 ms | 3.0× |
| roundtrip-50-provider-clock | 50 | 23.9 ms | 62.5 ms | 2.6× |
| roundtrip-50-held-open | 50 | 21.5 ms | 40.3 ms | 1.87× |

The repetitions (Haskell, then Python):
- open-fresh: 0.835, 0.935 ms against 0.924, 0.873 ms;
- roundtrip-1: 2.25, 2.42 ms against 3.40, 4.44 ms;
- roundtrip-50-db-clock: 20.9, 23.1 ms against 65.9, 65.9 ms;
- roundtrip-50-provider-clock: 24.6, 23.2 ms against 63.5, 61.5 ms;
- roundtrip-50-held-open: 21.6, 21.4 ms against 41.1, 39.4 ms.

`open-fresh` is level with Python: 1.02× on the medians, with Haskell ahead
in the first repetition and behind in the second (0.93×). It is the one row
the connection pool cannot help (see the notes).

The Python bench also prints `*-closing` variants, in which the
reference's read-only connections close at the end of their `with` block.
They are the reference with every connection closed deterministically, and
so the worst case for WAL checkpoints. They took 0.94 / 0.93 ms
(open-fresh), 5.50 / 4.45 ms (roundtrip-1), 113 / 102 ms (db-clock) and
114 / 102 ms (provider-clock).

### Wall-clock time, and the earlier figures

The figures committed before these timed Haskell in tasty-bench's default CPU
time, against Python's wall-clock time. These rows are mostly SQLite file IO,
and CPU time leaves out the time blocked in fsync, so the Haskell rows read
0.62 ms (open-fresh) and 15–16 ms (the 50-round-trip rows) then, against
0.89 ms and 21–24 ms in wall-clock time now. Against Python, open-fresh went
from 1.29× to 1.02×, and the round trips from 2.5–3.6× to 1.7–3.0×.

Before the connection pool (commit `f80e0c3`), still in CPU time, the Haskell
round trips took 71 ms for 50 (0.78× of Python), because every operation
paid SQLite's last-close checkpoint; the notes below explain the change.

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
the three `sleep` rows itself, with the monotonic clock, and prints them
before the tasty-bench groups start. Each of those rows is the median of 10
runs after one warm-up, in the Python bench's format. Every other Haskell row
is a tasty-bench mean in wall-clock time. Python rows are medians of 10–20
runs after one warm-up.

## Results

These rows come from the same two interleaved repetitions as the Local
Dispatch rows above, on the same machine and toolchains. Each figure is the
median of the two.

<!-- bench: superseded -->

| workload | size | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: | ---: |
| worker/local-50 | 50 | 24.7 ms | 64.1 ms | 2.6× |
| worker/local-50-held-open | 50 | 23.3 ms | 39.8 ms | 1.71× |
| worker/memory-1000 | 1000 | 1.36 ms | 14.3 ms | 10.5× |
| async-worker/memory-1000-c1 | 1000 | 2.80 ms | 218 ms | 78× |
| async-worker/memory-1000-c8 | 1000 | 3.07 ms | 115 ms | 38× |
| async-worker/memory-1000-c64 | 1000 | 3.18 ms | 121 ms | 38× |
| async-worker/sleep-1ms-200-c1 | 200 | 254 ms | 307 ms | 1.21× |
| async-worker/sleep-1ms-200-c8 | 200 | 32.3 ms | 42.9 ms | 1.33× |
| async-worker/sleep-1ms-200-c64 | 200 | 5.57 ms | 44.7 ms | 8.0× |

The repetitions of the two Local rows (Haskell, then Python):
- worker/local-50: 21.5, 27.9 ms against 67.2, 60.9 ms;
- worker/local-50-held-open: 19.9, 26.6 ms against 42.9, 36.7 ms.

In the earlier CPU-time figures the two Local rows read 16.2 and 16.5 ms
(3.4× and 2.5×); the memory rows, which do no IO, are within noise of those
figures, and the sleep rows were always timed with the monotonic clock.

## Worker notes

- **`worker/local-50` follows the Local Dispatch.** The Worker adds only
  one extra claim, which finds the queue empty, to the Local round trip.
  Its `LocalWorkerDispatch` shares the session's connection pool, so it no
  longer pays SQLite's last-close checkpoint on every operation (the first
  note above, and DIVERGENCES.md (15)). The row went from 0.77× to 3.4× in
  CPU time, and is 2.6× in wall-clock time.
- **The runtime's own cost is an order of magnitude lower.** The memory rows
  take SQLite out of the picture. The synchronous Worker spends about 1.4 µs
  per Attempt, against about 14.5 µs in Python.

  The AsyncWorker's sync bridge hands every custody call to the slot's lane
  thread. In Haskell that hop is a few microseconds between GHC threads. In
  Python, the thread-to-event-loop round trips cost 115–220 µs per Attempt.
- **Sleep-driven concurrency.** 200 Activities of 1 ms each cannot finish in
  less than 200 ms at concurrency 1, or 25 ms at concurrency 8.

  At concurrency 1 the Haskell AsyncWorker spends about 1.27 ms per Activity
  end to end, against about 1.56 ms in Python.

  At concurrency 64 the floor is about 3.1 ms. Haskell takes about 5.6 ms,
  while Python takes 32–37 ms to schedule 64 lanes through its event loop.
