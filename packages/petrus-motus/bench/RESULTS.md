# Local Dispatch benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 64d365b663f3ec22 at 4d6410bf7ef4 -->

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

Measured on 2026-10-12, 19:09–19:15 local (UTC-3), at commit `a62b03a`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.33–3.20:
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
it was before: 1.04× in this run (Haskell ahead in 4 of 5, 0.98× in the
closest repetition; 1.01× at `da94728`), each side's figure swinging by up
to 10% between repetitions. The connection
pool cannot help this row (see the notes), and there is no adapter work
left in it to take out. The sleep-bound `async-worker/sleep-*` rows are
medians of 10 runs after a warm-up on both sides, and now run after the
tasty rows, as the twin runs them after its Local rows.
`async-worker/sleep-1ms-200-c8` is the other close row: 1.02× here, Haskell
ahead in all five repetitions (1.11× at `da94728`); both sides spend most of
it waiting on 1 ms sleeps, eight at a time.

Since `da94728` the bench runs with the RTS defaults (a 4 MB allocation
area) instead of `-A32m`, as the executables that run this code do
([docs/reproducing.md](../../../docs/reproducing.md), "The benchmarks'
runtime options"). `worker.memory-1000` and the `async-worker.memory-*`
rows got faster (1.38 ms to 1.06 ms, 2.65 ms to 2.06 ms); the SQLite round
trips read 10–15% slower on the Haskell side than then (14.5 ms to
16.5 ms for 50), and the Python side 5–8% slower, at a similar load.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `async-worker/sleep-1ms-200-c1` | 266 ms | 359 ms | 1.35× | 1.21× | 5 of 5 | 260 ms, 271 ms, 266 ms, 270 ms, 265 ms | 383 ms, 329 ms, 371 ms, 357 ms, 359 ms |
| `async-worker/sleep-1ms-200-c8` | 35.9 ms | 36.5 ms | 1.02× | 1.01× | 5 of 5 | 34.1 ms, 36 ms, 33.9 ms, 36 ms, 35.9 ms | 36.6 ms, 36.5 ms, 36.6 ms, 36.5 ms, 36.4 ms |
| `async-worker/sleep-1ms-200-c64` | 8.62 ms | 29.6 ms | 3.43× | 3.11× | 5 of 5 | 7.97 ms, 9.53 ms, 8.13 ms, 8.62 ms, 8.87 ms | 29.2 ms, 29.6 ms, 29.6 ms, 29.3 ms, 30.2 ms |
| `local.open-fresh` | 633 µs | 656 µs | 1.04× | 0.98× | 4 of 5 | 655 µs, 633 µs, 647 µs, 619 µs, 632 µs | 640 µs, 647 µs, 660 µs, 657 µs, 656 µs |
| `local.roundtrip-1` | 1.6 ms | 2.28 ms | 1.43× | 1.40× | 5 of 5 | 1.63 ms, 1.6 ms, 1.59 ms, 1.55 ms, 1.6 ms | 2.28 ms, 2.27 ms, 2.24 ms, 2.33 ms, 2.31 ms |
| `local.roundtrip-50-db-clock` | 16.5 ms | 52.7 ms | 3.19× | 2.90× | 5 of 5 | 17.1 ms, 16.1 ms, 17.1 ms, 16.5 ms, 16 ms | 53.6 ms, 51.4 ms, 49.5 ms, 54.8 ms, 52.7 ms |
| `local.roundtrip-50-provider-clock` | 16.2 ms | 52.9 ms | 3.26× | 3.12× | 5 of 5 | 16.7 ms, 16 ms, 16.4 ms, 15.9 ms, 16.2 ms | 52.8 ms, 54.9 ms, 51.3 ms, 56.4 ms, 52.9 ms |
| `local.roundtrip-50-held-open` | 16.9 ms | 35.9 ms | 2.12× | 2.00× | 5 of 5 | 17 ms, 15.9 ms, 17.3 ms, 16.8 ms, 16.9 ms | 34 ms, 41 ms, 35.9 ms, 38.2 ms, 34.9 ms |
| `worker.local-50` | 16.8 ms | 55.6 ms | 3.30× | 3.21× | 5 of 5 | 17.6 ms, 16.9 ms, 16.7 ms, 16.8 ms, 16.4 ms | 59.1 ms, 55.6 ms, 53.8 ms, 53.9 ms, 60.6 ms |
| `worker.local-50-held-open` | 17 ms | 36.3 ms | 2.13× | 2.08× | 5 of 5 | 16.5 ms, 17.2 ms, 17 ms, 17.5 ms, 15.8 ms | 34.4 ms, 39.2 ms, 38.6 ms, 36.3 ms, 34.9 ms |
| `worker.memory-1000` | 1.06 ms | 13.9 ms | 13.15× | 13.05× | 5 of 5 | 1.05 ms, 1.06 ms, 1.04 ms, 1.06 ms, 1.06 ms | 13.9 ms, 13.9 ms, 13.9 ms, 14 ms, 13.8 ms |
| `async-worker.memory-1000-c1` | 2.06 ms | 211 ms | 102.38× | 98.99× | 5 of 5 | 2.11 ms, 2.05 ms, 2.04 ms, 2.06 ms, 2.08 ms | 209 ms, 213 ms, 212 ms, 211 ms, 211 ms |
| `async-worker.memory-1000-c8` | 2 ms | 108 ms | 54.03× | 52.31× | 5 of 5 | 2.02 ms, 2 ms, 1.99 ms, 2 ms, 2.03 ms | 108 ms, 108 ms, 107 ms, 108 ms, 106 ms |
| `async-worker.memory-1000-c64` | 2.11 ms | 113 ms | 53.67× | 52.38× | 5 of 5 | 2.14 ms, 2.08 ms, 2.11 ms, 2.11 ms, 2.14 ms | 114 ms, 113 ms, 113 ms, 114 ms, 112 ms |
| `local/open-fresh-closing` | — | 640 µs | — | — | — |  | 738 µs, 640 µs, 882 µs, 638 µs, 631 µs |
| `local/roundtrip-1-closing` | — | 3.89 ms | — | — | — |  | 3.89 ms, 3.7 ms, 3.67 ms, 3.89 ms, 3.97 ms |
| `local/roundtrip-50-db-clock-closing` | — | 86.5 ms | — | — | — |  | 87.2 ms, 86.1 ms, 86.5 ms, 82 ms, 88.3 ms |
| `local/roundtrip-50-provider-clock-closing` | — | 85.1 ms | — | — | — |  | 86.5 ms, 89.3 ms, 84.5 ms, 85.1 ms, 84.8 ms |

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
