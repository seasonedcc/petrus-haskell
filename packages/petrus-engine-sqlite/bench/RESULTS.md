# SQLite Engine benchmarks: Haskell vs the Python reference

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` drive the same
workloads through the public SQLite Engine composition: the reference's
`petrus.engine.sqlite.create` / `load` against this package's
`createEngine` / `loadEngine`. Each opens the writer fence and the
`SqliteHistoryStore`, then the Engine. Each Python line prints a result size
(the History length). The Haskell bench prints the same sizes on start-up
(`sizes: orders-small-sqlite 66, orders-large-sqlite 4203`).

The workloads:

- **orders-small-sqlite / orders-large-sqlite.** petrus-engine's order
  scenario (`packages/petrus-engine/test/Petrus/Engine/Scenario.hs`, the twin
  of `test/interop/engine_interop.py`), with 3 and 200 orders. Each run
  creates the Engine over a fresh database, delivers the orders, advances
  until the Engine is at rest, reads `records`, and closes. Then the database
  is deleted with its `-wal` and `-shm` side files. Every commit point is one
  fsynced `BEGIN IMMEDIATE` transaction (`synchronous=FULL`, WAL), on both
  sides.
- **load-sqlite.** `load` of the finished 200-order database, which covers
  the fence, the store's open and decode, replay and reconcile. Then one
  `advance`, `records`, and `close`.
- **open-close.** `load` of an empty instance's database over
  `InMemoryDispatch` (fence + store open + Engine open), `records`, `close`.

## How to rerun

From the repository root:

    cabal bench petrus-engine-sqlite --benchmark-options='+RTS -M2G -RTS'

Python, from the pinned reference checkout with its virtual environment. Row
names given as arguments restrict the run to those rows:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python ../../packages/petrus-engine-sqlite/bench/python_bench.py

The two sides ran interleaved (Python, Haskell, Python, ...) for three rounds
on 2026-10-10 on an Apple M4 with 24 GB of memory:
- GHC 9.10.3 (`-O2`, `-A32m`) with direct-sqlite 2.3.29, which bundles SQLite
  3.45.0;
- CPython 3.14.6 with SQLite 3.53.4;
- the reference pinned at `upstream/petrus` 3f85fc2.

The load average was 2.4–3.6 throughout.

## Results

Each cell is the median of the three rounds. A round is a tasty-bench mean
for Haskell, and the median of 3–200 runs after a warm-up for Python.

| workload | size (records) | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: |
| orders-small-sqlite (3 orders) | 66 | 7.01 ms | 4.15 ms | 1.7× |
| orders-large-sqlite (200 orders) | 4 203 | 934 ms | 214 ms | 4.4× |
| load-sqlite (load + one advance) | 4 203 | 122 ms | 18.0 ms | 6.8× |
| open-close (empty instance) | 0 | 0.456 ms | 0.367 ms | 1.2× |

The individual rounds, Python / Haskell:

- orders-small-sqlite: 6.62 / 4.24, 7.21 / 4.03, 7.01 / 4.15 ms;
- orders-large-sqlite: 934 / 214, 929 / 199, 946 / 215 ms;
- load-sqlite: 122.0 / 19.0, 118.0 / 18.0, 122.0 / 17.9 ms;
- open-close: 0.466 / 0.371, 0.455 / 0.353, 0.456 / 0.367 ms.

## Notes

- **The orders rows are bound by fsync.** Each order produces several commit
  points, and each is a durable SQLite transaction. The rest of the gap is
  the Engine and kernel, which are 7–14× faster than the reference in memory
  (see `packages/petrus-engine/bench/RESULTS.md`).
- **open-close** is mostly SQLite's open, the four pragmas, the schema check
  under `BEGIN IMMEDIATE`, and the `flock` of the writer fence. Those are the
  same system calls on both sides.
- **The store's own rows** (append, load, resume, terminal acknowledgement)
  are in `packages/petrus-history-store/bench/RESULTS.md`.
