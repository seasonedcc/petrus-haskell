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

From the repository root (`scripts/bench petrus-engine-sqlite` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-engine-sqlite --benchmark-options='--stdev 5 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-engine-sqlite/bench/python_bench.py)
```

Row names given to `python_bench.py` as arguments restrict the Python run to those rows.

## Results

The two sides ran interleaved (Haskell, Python, then Python, Haskell) on
2026-10-10, 21:29–21:32 local (UTC-3), at commit `74e6b1e` with the switch to
wall-clock time in `bench/Main.hs`, on an Apple M4 with 24 GB of memory shared
with other agents (1-minute load average 3.1–4.3):
- GHC 9.10.3 (`-O2`, `-A32m`) with direct-sqlite 2.3.29, which bundles SQLite
  3.45.0; tasty-bench means in wall-clock time, `--stdev 5`, `+RTS -M2G`;
- CPython 3.14.6 with SQLite 3.53.4; the median of 3–200 runs after a
  warm-up;
- the reference pinned at `upstream/petrus` 3f85fc2.

Each cell is the median of the two repetitions.

| workload | size (records) | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: |
| orders-small-sqlite (3 orders) | 66 | 7.61 ms | 5.51 ms | 1.38× |
| orders-large-sqlite (200 orders) | 4 203 | 946 ms | 248 ms | 3.81× |
| load-sqlite (load + one advance) | 4 203 | 121 ms | 16.7 ms | 7.27× |
| open-close (empty instance) | 0 | 0.566 ms | 0.507 ms | 1.12× |

The individual repetitions, Python / Haskell:

- orders-small-sqlite: 7.69 / 5.47, 7.53 / 5.54 ms;
- orders-large-sqlite: 956 / 232, 936 / 264 ms;
- load-sqlite: 122.4 / 16.6, 119.9 / 16.7 ms;
- open-close: 0.549 / 0.488, 0.583 / 0.526 ms.

### Wall-clock time, and the earlier figures

The figures committed before these timed Haskell in tasty-bench's default CPU
time, against Python's wall-clock time. CPU time leaves out the time spent
blocked in fsync, which every commit point here pays, so the orders rows read
4.15 ms and 214 ms then (1.7× and 4.4×), against 5.5 ms and 248 ms in
wall-clock time now (1.4× and 3.8×). `open-close` went from 0.367 ms to
0.507 ms (1.2× to 1.1×). `load-sqlite`, which reads, is unchanged.

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
