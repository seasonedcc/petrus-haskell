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

Every operation opens its own connection on both sides and sets the
reference's pragmas: `busy_timeout=5000`, `foreign_keys=ON`,
`synchronous=FULL` and `journal_mode=WAL`. Every write is one
`BEGIN IMMEDIATE` transaction. So these rows mostly time SQLite file IO
(open, lock, WAL append, fsync), not the adapter code.

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

    cabal bench petrus-motus

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python ../../packages/petrus-motus/bench/python_bench.py

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median of
10–20 runs after one warm-up.

Both sides ran back to back on 2026-10-10 on an Apple M4 with 24 GB of memory:
- GHC 9.10.3 (`-O2`, `-A32m`) with direct-sqlite 2.3.29, which bundles SQLite
  3.45.0;
- CPython 3.14.6 with SQLite 3.53.4;
- the reference pinned at `upstream/petrus` 3f85fc2.

The machine was shared and heavily loaded (load average 12–14 during the
recorded run), and fsync-bound rows are noisy under load. Repeated runs moved
individual rows by up to ±30 %, but never changed which side was faster in
the equal-IO comparisons.

## Results

The table below is from one back-to-back run. Each row has a closing
variant: the reference runs with its read-only connections closed at the end
of their `with` block, as the Haskell port closes them (see the first note).
The closing variants are the equal-IO comparisons, and so the parity
evidence. The plain rows are shown as the reference behaves out of the box.

| workload | size | Python | Python, closing | Haskell | Haskell vs Python, closing |
| --- | ---: | ---: | ---: | ---: | ---: |
| open-fresh | 0 | 1.55 ms | 1.61 ms | 1.28 ms | 1.3× faster |
| roundtrip-1 | 1 | 8.93 ms | 10.1 ms | 6.41 ms | 1.6× faster |
| roundtrip-50-db-clock | 50 | 157 ms | 217 ms | 134 ms | 1.6× faster |
| roundtrip-50-provider-clock | 50 | 123 ms | 309 ms | 161 ms | 1.9× faster |
| roundtrip-50-held-open | 50 | 82.5 ms | (already equal IO) | 60.1 ms | 1.4× faster |

Against the plain reference rows the Haskell adapter is faster in four of
five. The exception is `roundtrip-50-provider-clock`, at 0.8×: there the
reference's lingering connection spares it the WAL's last-close checkpoint
on most of the 150 operations.

An earlier run on a less loaded machine (load average 4–7) gave the same
picture, with Haskell / Python times as follows:
- open-fresh: 1.00 / 1.07 ms;
- roundtrip-50-held-open: 44.2 / 49.2 ms;
- Haskell roundtrip-50-db-clock: 122 ms, against 199 ms for the closing
  reference.

## Notes

- **The reference keeps connections open until garbage collection.** Its
  read-only `with _connect(path) as connection:` blocks only commit on exit;
  a Python `sqlite3` context manager does not close the connection. Schema
  initialization is one of these blocks.

  The connection therefore stays open until the cyclic garbage collector
  reaches it. A probe of 20 dispatches after opening found 2 live
  connections, and 0 after `gc.collect()`.

  While such a connection lives, it holds the WAL open. Closing each
  per-operation connection is then never the *last* close, so SQLite skips
  the last-close checkpoint and WAL deletion, which cost several fsyncs.

  The Haskell port closes every connection when its operation ends. That
  makes plain round trips pay the checkpoint whenever no other connection is
  open. The probe made the effect explicit: 20 claim + complete pairs took
  11.8 ms with the reference's lingering connections and 37.4 ms once they
  closed deterministically.

  The `held-open` and `closing` rows remove the difference. They show the
  Haskell adapter 1.3–1.9× faster at equal IO.

  The difference is in resource lifetime only. Rows, statements and
  transactions are identical, and the interop suite checks this
  (`test/Petrus/Motus/Dispatch/LocalInteropSpec.hs`). See also
  `DIVERGENCES.md`.
- **The two sides link different SQLite builds.** direct-sqlite bundles SQLite
  3.45.0, while the reference's CPython links 3.53.4. Both builds default to
  `synchronous=2` and `wal_synchronous=2`, and both set `synchronous=FULL`
  explicitly. Neither enables `fullfsync`.

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
  holds the file open. This is the equal-IO comparison; see the notes above.
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

The runs took place on 2026-10-10 on the same machine and toolchains as
above. Haskell and Python ran interleaved (H, P, H, P). Other work shared the
machine, and the load average rose from 2.2 to 5.2 during the runs. Each
cell gives the two rounds.

| workload | size | Haskell | Python | Python / Haskell |
| --- | ---: | --- | --- | ---: |
| worker/local-50 | 50 | 69.2, 81.0 ms | 58.0, 60.4 ms | 0.72–0.84× |
| worker/local-50-held-open | 50 | 34.5, 33.8 ms | 37.2, 41.1 ms | 1.1–1.2× |
| worker/memory-1000 | 1000 | 1.49, 1.52 ms | 13.9, 15.9 ms | 9.3–10× |
| async-worker/memory-1000-c1 | 1000 | 3.17, 3.57 ms | 214, 280 ms | 67–78× |
| async-worker/memory-1000-c8 | 1000 | 3.20, 3.46 ms | 121, 111 ms | 32–38× |
| async-worker/memory-1000-c64 | 1000 | 3.11, 3.55 ms | 126, 120 ms | 34–41× |
| async-worker/sleep-1ms-200-c1 | 200 | 263, 256 ms | 341, 301 ms | 1.2–1.3× |
| async-worker/sleep-1ms-200-c8 | 200 | 34.5, 33.1 ms | 46.8, 36.3 ms | 1.1–1.4× |
| async-worker/sleep-1ms-200-c64 | 200 | 8.23, 5.87 ms | 53.5, 31.4 ms | 5.4–6.5× |

The Local Dispatch rows from the same rounds give the same picture as the
table at the top (Haskell, then Python):
- `roundtrip-50-held-open`: 31.7 and 34.8 ms, against 39.9 and 39.0 ms;
- `roundtrip-50-db-clock`: 71.0 and 86.0 ms, against 53.4 and 54.8 ms. The
  reference's closing variant of that row took 87.4 and 90.6 ms.

## Worker notes

- **`worker/local-50` measures the Local Dispatch's connection lifetime,
  not the Worker.** The Worker adds only one extra claim, which finds the
  queue empty, to the Local round trip. Without a co-resident connection,
  the Haskell adapter pays SQLite's last-close checkpoint on every
  operation, and the reference's lingering connections avoid it. This is the
  first note above and DIVERGENCES.md (15).

  At equal IO (`local-50-held-open`) the Haskell Worker is 1.1–1.2× faster.
- **The runtime's own cost is an order of magnitude lower.** The memory rows
  take SQLite out of the picture. The synchronous Worker spends about 1.5 µs
  per Attempt, against 14–16 µs in Python.

  The AsyncWorker's sync bridge hands every custody call to the slot's lane
  thread. In Haskell that hop is a few microseconds between GHC threads. In
  Python, the thread-to-event-loop round trips cost 110–280 µs per Attempt.
- **Sleep-driven concurrency.** 200 Activities of 1 ms each cannot finish in
  less than 200 ms at concurrency 1, or 25 ms at concurrency 8.

  At concurrency 1 the Haskell AsyncWorker spends about 1.3 ms per Activity
  end to end, against 1.5–1.7 ms in Python.

  At concurrency 64 the floor is about 3.1 ms. Haskell takes 6–8 ms, while
  Python takes 31–54 ms to schedule 64 lanes through its event loop.
