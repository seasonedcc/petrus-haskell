# Observation benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 1b088c4dd1c26315 at 5a73d7a7f019 -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` build the same
workload. It is a two-place loop (`a → t1 → b → t2 → a`) holding M tokens
(`{"i": k, "label": "token-k"}`), stepped until its History holds at least N
records. Both sides stop at 1 002 or 10 002 records.

There are two kinds of rows:

- **Projection rows** time the work of one read door without an Engine.
  - Haskell: `capture` of the Instance and its History mirror, then the pure
    projection, forced to the last node.
  - Python: reading `instance.history.records`, then the
    `petrus.impetus.observation` function.
- **Engine rows** time the Engine's own read doors on an Engine loaded
  (`Engine.load`, an in-memory History and an `InMemoryDispatch`) over the
  same History. Each call also pays for the Engine's lock and its re-entry,
  poison and closed checks.
  - Haskell: `Petrus.Observation.Engine.snapshot`, `historyPage` and
    `netDocument`.
  - Python: `engine.snapshot()`, `engine.history_page(after, limit)` and
    `engine.net_document()`.

  The Engine's full scan is a client's paged read: it follows `next` until
  it reaches the page's `frontier`, one door call per page.

## Equivalence

Before timing, both programs print a SHA-256 of every measured output,
encoded as compact, key-sorted, ASCII JSON. All 21 digests are identical:

- projection rows: 4 snapshots, 2 `history_page(0, 1000)` pages, 2 full
  paged scans, 3 observed Net documents;
- Engine rows: 4 snapshots, 2 pages, 2 full scans, 2 Net documents.

Each Engine digest also equals the digest of the projection row with the
same workload.

## How to rerun

From the repository root (`scripts/bench petrus-observation` runs exactly
this; `scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-observation +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-observation/bench/python_bench.py)
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

Haskell numbers are tasty-bench means. Python numbers are the median of 20
runs (snapshot, page) or 5 runs (scan, document), after one warm-up.

Both were run on 2026-10-10 on an Apple M4 with 24 GB of memory, using GHC
9.10.3 (`-O2`, `-A32m`) and CPython 3.14.6. The reference was pinned at
`upstream/petrus` 3f85fc2. Other builds were running on the machine at the
same time, so treat the numbers as indicative to within about 10–20%.

## Current figures

Measured on 2026-10-12, 02:30–02:39 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.26–3.22:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-observation 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `snapshot.N=1000 M=10` | 10.5 µs | 131 µs | 12.44× | 12.35× | 11 µs, 10.5 µs, 10.5 µs | 334 µs, 130 µs, 131 µs |
| `snapshot.N=1000 M=1000` | 478 µs | 3.85 ms | 8.05× | 7.98× | 481 µs, 478 µs, 477 µs | 3.92 ms, 3.82 ms, 3.85 ms |
| `snapshot.N=10000 M=10` | 10.6 µs | 154 µs | 14.55× | 14.55× | 10.6 µs, 10.6 µs, 10.5 µs | 155 µs, 154 µs, 153 µs |
| `snapshot.N=10000 M=1000` | 481 µs | 4.29 ms | 8.91× | 8.60× | 481 µs, 481 µs, 498 µs | 4.29 ms, 4.29 ms, 4.28 ms |
| `engine snapshot.N=1000 M=10` | 10.7 µs | 137 µs | 12.79× | 12.51× | 10.7 µs, 10.7 µs, 10.7 µs | 137 µs, 134 µs, 137 µs |
| `engine snapshot.N=1000 M=1000` | 476 µs | 3.87 ms | 8.13× | 8.07× | 476 µs, 476 µs, 479 µs | 3.87 ms, 3.84 ms, 3.87 ms |
| `engine snapshot.N=10000 M=10` | 10.7 µs | 153 µs | 14.24× | 14.22× | 10.6 µs, 10.7 µs, 10.8 µs | 156 µs, 153 µs, 153 µs |
| `engine snapshot.N=10000 M=1000` | 487 µs | 4.19 ms | 8.61× | 8.37× | 484 µs, 496 µs, 487 µs | 4.21 ms, 4.16 ms, 4.19 ms |
| `history_page(0,1000).N=1000 M=10` | 214 µs | 2.9 ms | 13.56× | 13.56× | 214 µs, 215 µs, 213 µs | 2.9 ms, 2.99 ms, 2.9 ms |
| `history_page(0,1000).N=10000 M=10` | 215 µs | 2.94 ms | 13.71× | 13.51× | 216 µs, 215 µs, 212 µs | 2.96 ms, 2.9 ms, 2.94 ms |
| `engine history_page(0,1000).N=1000 M=10` | 207 µs | 2.9 ms | 14.02× | 13.44× | 213 µs, 207 µs, 204 µs | 2.87 ms, 2.9 ms, 2.92 ms |
| `engine history_page(0,1000).N=10000 M=10` | 207 µs | 2.95 ms | 14.26× | 14.13× | 209 µs, 207 µs, 207 µs | 2.95 ms, 2.95 ms, 2.97 ms |
| `full-scan.N=1000 M=10` | 216 µs | 2.92 ms | 13.53× | 13.30× | 218 µs, 216 µs, 214 µs | 2.92 ms, 2.87 ms, 2.93 ms |
| `full-scan.N=10000 M=10` | 2.12 ms | 30.1 ms | 14.23× | 13.88× | 2.12 ms, 2.09 ms, 2.18 ms | 29.9 ms, 30.1 ms, 30.3 ms |
| `engine full-scan.N=1000 M=10` | 209 µs | 2.93 ms | 14.01× | 13.87× | 211 µs, 209 µs, 207 µs | 2.93 ms, 2.93 ms, 2.97 ms |
| `engine full-scan.N=10000 M=10` | 2.93 ms | 30.8 ms | 10.52× | 10.45× | 2.95 ms, 2.92 ms, 2.93 ms | 30.8 ms, 30.7 ms, 31.5 ms |
| `net_document.N=1000 M=10` | 30 ms | 127 ms | 4.23× | 4.23× | 30 ms, 29.9 ms, 30.1 ms | 129 ms, 127 ms, 127 ms |
| `net_document.N=10000 M=10` | 361 ms | 1.63 s | 4.52× | 4.50× | 361 ms, 358 ms, 365 ms | 1.63 s, 1.63 s, 1.64 s |
| `net_document.N=1000 M=1000` | 2.75 s | 12.8 s | 4.66× | 4.63× | 2.75 s, 2.75 s, 2.73 s | 12.9 s, 12.7 s, 12.8 s |
| `engine net_document.N=1000 M=10` | 30.1 ms | 126 ms | 4.19× | 4.18× | 30.1 ms, 30 ms, 30.3 ms | 126 ms, 126 ms, 127 ms |
| `engine net_document.N=10000 M=10` | 360 ms | 1.71 s | 4.76× | 4.75× | 361 ms, 360 ms, 359 ms | 1.72 s, 1.71 s, 1.71 s |

## Results: projections

<!-- bench: superseded -->

| door | N records | M tokens | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: | ---: |
| snapshot | 1 000 | 10 | 0.153 ms | 9.23 µs | 17× |
| snapshot | 1 000 | 1 000 | 4.81 ms | 0.475 ms | 10× |
| snapshot | 10 000 | 10 | 0.168 ms | 8.85 µs | 19× |
| snapshot | 10 000 | 1 000 | 5.68 ms | 0.416 ms | 14× |
| history_page(0, 1000) | 1 000 | 10 | 3.34 ms | 0.176 ms | 19× |
| history_page(0, 1000) | 10 000 | 10 | 3.44 ms | 0.175 ms | 20× |
| full paged scan (limit 1000) | 1 000 | 10 | 3.35 ms | 0.177 ms | 19× |
| full paged scan (limit 1000) | 10 000 | 10 | 38.9 ms | 1.72 ms | 23× |
| net_document | 1 000 | 10 | 169 ms | 27.3 ms | 6.2× |
| net_document | 10 000 | 10 | 2 042 ms | 448 ms | 4.6× |
| net_document | 1 000 | 1 000 | 13 834 ms | 4 422 ms | 3.1× |

## Results: the Engine's read doors

<!-- bench: superseded -->

| door | N records | M tokens | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: | ---: |
| `Engine.snapshot()` | 1 000 | 10 | 0.135 ms | 7.49 µs | 18× |
| `Engine.snapshot()` | 1 000 | 1 000 | 4.00 ms | 0.411 ms | 9.7× |
| `Engine.snapshot()` | 10 000 | 10 | 0.156 ms | 7.46 µs | 21× |
| `Engine.snapshot()` | 10 000 | 1 000 | 4.41 ms | 0.400 ms | 11× |
| `Engine.history_page(0, 1000)` | 1 000 | 10 | 2.97 ms | 0.170 ms | 17× |
| `Engine.history_page(0, 1000)` | 10 000 | 10 | 2.98 ms | 0.169 ms | 18× |
| full paged scan (limit 1000) | 1 000 | 10 | 2.96 ms | 0.169 ms | 18× |
| full paged scan (limit 1000) | 10 000 | 10 | 32.7 ms | 2.34 ms | 14× |
| `Engine.net_document()` | 1 000 | 10 | 141 ms | 31.0 ms | 4.5× |
| `Engine.net_document()` | 10 000 | 10 | 1 836 ms | 489 ms | 3.8× |

## Notes

- **The Engine adds no measurable cost.** Each Engine row is within noise of
  its projection row. The monitor (an `MVar` take and put, a thread-id
  compare) and the three checks cost well under a microsecond. Measured in
  isolation (only the snapshot and page groups, so both see the same heap),
  the Engine snapshot took 7.47 µs against 7.57 µs for `capture` plus
  `snapshot`, and the page 171 µs against 175 µs.
- **Group order matters.** Each Engine group runs right after its projection
  twin. Run after the `net_document` groups, which grow the heap, the same
  Engine doors measured 30–50% slower. That cost was garbage collection
  over the larger heap, not the Engine.
- **The Engine's full scan** calls the door once per page, and each call
  reads the History mirror again. The projection scan shares one captured
  `Seq`. That is the 1.72 ms vs 2.34 ms difference at N = 10 000. Python
  pays the same per-page cost.
- **An earlier run of this benchmark** measured the Python full scan of
  N = 10 000 at 150 ms, about 40× its single page. This run measured
  38.9 ms, about 11×. The earlier figure was probably garbage-collection
  noise.
- **`net_document` (N = 10 000, M = 1 000) is not measured.** It is 10⁷
  tokens of lineage markings, and Python would take minutes per run. The
  document's cost is O(N × M) on both sides: one complete marking per
  record. The Haskell time is dominated by building and validating those
  markings, then by the Net document's own serialization check.
- **The snapshot is independent of N.** Only the frontier (the History
  length) is read from the records.
