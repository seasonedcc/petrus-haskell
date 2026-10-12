# Observation benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources ff91c130d1d26659 at b1b7c1ed40ea -->

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

Measured on 2026-10-12, 18:44–18:59 local (UTC-3), at commit `e8c1097`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.88–2.77:
five interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-observation 5

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `snapshot.N=1000 M=10` | 7.9 µs | 131 µs | 16.57× | 16.53× | 5 of 5 | 7.8 µs, 7.91 µs, 7.9 µs, 7.91 µs, 7.83 µs | 129 µs, 131 µs, 131 µs, 131 µs, 130 µs |
| `snapshot.N=1000 M=1000` | 416 µs | 3.84 ms | 9.25× | 9.19× | 5 of 5 | 409 µs, 416 µs, 416 µs, 419 µs, 415 µs | 3.85 ms, 3.84 ms, 3.83 ms, 3.85 ms, 3.84 ms |
| `snapshot.N=10000 M=10` | 7.82 µs | 153 µs | 19.57× | 19.08× | 5 of 5 | 7.82 µs, 7.93 µs, 7.91 µs, 7.8 µs, 7.82 µs | 153 µs, 153 µs, 151 µs, 155 µs, 155 µs |
| `snapshot.N=10000 M=1000` | 412 µs | 4.2 ms | 10.21× | 10.18× | 5 of 5 | 409 µs, 413 µs, 416 µs, 412 µs, 411 µs | 4.2 ms, 4.2 ms, 4.28 ms, 4.2 ms, 4.27 ms |
| `engine snapshot.N=1000 M=10` | 7.94 µs | 134 µs | 16.87× | 16.58× | 5 of 5 | 7.94 µs, 8.02 µs, 7.97 µs, 7.94 µs, 7.83 µs | 138 µs, 133 µs, 136 µs, 134 µs, 134 µs |
| `engine snapshot.N=1000 M=1000` | 413 µs | 3.83 ms | 9.25× | 9.12× | 5 of 5 | 412 µs, 417 µs, 424 µs, 413 µs, 413 µs | 3.89 ms, 3.82 ms, 3.87 ms, 3.83 ms, 3.79 ms |
| `engine snapshot.N=10000 M=10` | 7.9 µs | 152 µs | 19.25× | 19.07× | 5 of 5 | 7.83 µs, 8.02 µs, 7.9 µs, 7.92 µs, 7.83 µs | 152 µs, 153 µs, 155 µs, 151 µs, 152 µs |
| `engine snapshot.N=10000 M=1000` | 415 µs | 4.16 ms | 10.03× | 9.99× | 5 of 5 | 415 µs, 416 µs, 417 µs, 414 µs, 415 µs | 4.16 ms, 4.16 ms, 4.23 ms, 4.15 ms, 4.16 ms |
| `history_page(0,1000).N=1000 M=10` | 187 µs | 2.93 ms | 15.71× | 15.47× | 5 of 5 | 187 µs, 187 µs, 187 µs, 187 µs, 185 µs | 3 ms, 2.89 ms, 2.93 ms, 2.92 ms, 2.94 ms |
| `history_page(0,1000).N=10000 M=10` | 187 µs | 2.98 ms | 15.92× | 15.61× | 5 of 5 | 186 µs, 187 µs, 188 µs, 187 µs, 186 µs | 3.06 ms, 2.92 ms, 2.98 ms, 2.96 ms, 2.99 ms |
| `engine history_page(0,1000).N=1000 M=10` | 180 µs | 2.93 ms | 16.25× | 16.02× | 5 of 5 | 181 µs, 183 µs, 180 µs, 180 µs, 179 µs | 2.9 ms, 2.93 ms, 2.95 ms, 2.91 ms, 2.96 ms |
| `engine history_page(0,1000).N=10000 M=10` | 181 µs | 2.98 ms | 16.43× | 16.12× | 5 of 5 | 181 µs, 181 µs, 185 µs, 181 µs, 180 µs | 2.94 ms, 2.98 ms, 2.98 ms, 2.96 ms, 3 ms |
| `full-scan.N=1000 M=10` | 187 µs | 2.95 ms | 15.74× | 15.48× | 5 of 5 | 189 µs, 187 µs, 188 µs, 187 µs, 185 µs | 3.05 ms, 2.9 ms, 2.95 ms, 2.92 ms, 2.96 ms |
| `full-scan.N=10000 M=10` | 1.82 ms | 30.1 ms | 16.56× | 16.42× | 5 of 5 | 1.81 ms, 1.83 ms, 1.83 ms, 1.82 ms, 1.8 ms | 30.9 ms, 30 ms, 30.1 ms, 30.2 ms, 30 ms |
| `engine full-scan.N=1000 M=10` | 183 µs | 2.94 ms | 16.13× | 16.11× | 5 of 5 | 181 µs, 183 µs, 183 µs, 179 µs, 183 µs | 2.92 ms, 2.94 ms, 2.96 ms, 2.94 ms, 2.98 ms |
| `engine full-scan.N=10000 M=10` | 4.81 ms | 30.7 ms | 6.37× | 6.24× | 5 of 5 | 4.85 ms, 4.81 ms, 4.93 ms, 4.8 ms, 4.8 ms | 30.6 ms, 30.5 ms, 30.8 ms, 30.7 ms, 30.8 ms |
| `net_document.N=1000 M=10` | 27.3 ms | 127 ms | 4.65× | 4.62× | 5 of 5 | 27.3 ms, 27.4 ms, 27.4 ms, 27.2 ms, 27 ms | 127 ms, 126 ms, 126 ms, 128 ms, 127 ms |
| `net_document.N=10000 M=10` | 298 ms | 1.62 s | 5.45× | 5.39× | 5 of 5 | 298 ms, 299 ms, 298 ms, 299 ms, 296 ms | 1.64 s, 1.64 s, 1.62 s, 1.61 s, 1.62 s |
| `net_document.N=1000 M=1000` | 2.18 s | 12.9 s | 5.92× | 5.78× | 5 of 5 | 2.2 s, 2.13 s, 2.21 s, 2.16 s, 2.18 s | 13 s, 12.9 s, 12.8 s, 12.8 s, 12.9 s |
| `engine net_document.N=1000 M=10` | 27.3 ms | 126 ms | 4.62× | 4.56× | 5 of 5 | 27.3 ms, 27.5 ms, 27.4 ms, 27.3 ms, 27.1 ms | 126 ms, 126 ms, 125 ms, 126 ms, 126 ms |
| `engine net_document.N=10000 M=10` | 299 ms | 1.7 s | 5.68× | 5.64× | 5 of 5 | 301 ms, 297 ms, 299 ms, 300 ms, 296 ms | 1.7 s, 1.7 s, 1.7 s, 1.7 s, 1.71 s |

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
