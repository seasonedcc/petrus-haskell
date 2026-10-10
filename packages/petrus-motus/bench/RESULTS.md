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
