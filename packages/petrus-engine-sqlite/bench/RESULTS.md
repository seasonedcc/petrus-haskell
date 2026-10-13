# SQLite Engine benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 6ba098dbc7d510c0 at df073f3106e5 -->
<!-- scripts/bench: carried to 26062d9d4eabf41e at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: petrus-history-store's floatEqualsInteger calls pyNumberEq, the same exact test, reached only for a REAL position or a float occurrence, which the store never writes; petrus-impetus's literalInt float branch and petrus-motus's local-dispatch sqlite3 int-against-float == call pyNumberEq, the same exact test they spelled out; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to 5a91e18920bec21f at 60f3c54dbf18: the fingerprint now also counts the test directories the benchmark stanza compiles (its test/, ../petrus-impetus/test and ../petrus-engine/test); none has changed since the measurement at df073f3 (git diff df073f3 of the three is empty), so no measured source changed -->
<!-- scripts/bench: carried to 4700b4eda69640ea at b4d1ccb669ad: since 60f3c54, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only -->

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

## Current figures

Measured on 2026-10-13, 03:32–03:34 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 3.02–3.76:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-engine-sqlite 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `engine-sqlite.orders-small-sqlite` | 4.13 ms | 6.9 ms | 1.67× | 1.50× | 3 of 3 | 4.3 ms, 4.08 ms, 4.13 ms | 6.9 ms, 6.12 ms, 7.35 ms |
| `engine-sqlite.orders-large-sqlite` | 195 ms | 942 ms | 4.83× | 4.54× | 3 of 3 | 209 ms, 195 ms, 179 ms | 951 ms, 942 ms, 901 ms |
| `engine-sqlite.load-sqlite` | 14.3 ms | 118 ms | 8.22× | 8.15× | 3 of 3 | 14.3 ms, 14.5 ms, 14.2 ms | 118 ms, 118 ms, 117 ms |
| `engine-sqlite.open-close` | 334 µs | 478 µs | 1.43× | 1.42× | 3 of 3 | 334 µs, 337 µs, 331 µs | 480 µs, 478 µs, 476 µs |

## How to rerun

From the repository root (`scripts/bench petrus-engine-sqlite` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-engine-sqlite --stdev 5 +RTS -M2G -RTS
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

<!-- bench: superseded -->

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
