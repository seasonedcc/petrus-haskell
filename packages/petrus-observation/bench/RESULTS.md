# Observation benchmarks: Haskell vs the Python reference

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` build the same
workload. It is a two-place loop (`a → t1 → b → t2 → a`) holding M tokens
(`{"i": k, "label": "token-k"}`), stepped until its History holds at least N
records. Both sides stop at 1 002 or 10 002 records.

Each row times one Engine read door's work:

- **Haskell**: `capture` of the Instance and its History mirror, then the
  pure projection, forced to the last node.
- **Python**: reading `instance.history.records`, then the
  `petrus.impetus.observation` function.

## Equivalence

Before timing, both programs print a SHA-256 of every measured output,
encoded as compact, key-sorted, ASCII JSON. All 11 digests are identical:

- 4 snapshots;
- 2 `history_page(0, 1000)` pages;
- 2 full paged scans;
- 3 observed Net documents.

## How to rerun

From the repository root:

    cabal bench petrus-observation

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python ../../packages/petrus-observation/bench/python_bench.py

Haskell numbers are tasty-bench means. Python numbers are the median of 20
runs (snapshot, page) or 5 runs (scan, document), after one warm-up.

Both were run on 2026-10-10 on an Apple M4 with 24 GB of memory, using GHC
9.10.3 (`-O2`, `-A32m`) and CPython 3.14.6. The reference was pinned at
`upstream/petrus` 3f85fc2. Other builds were running on the machine at the
same time, so treat the numbers as indicative to within about 10%.

## Results

| door | N records | M tokens | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: | ---: |
| snapshot | 1 000 | 10 | 0.142 ms | 7.66 µs | 19× |
| snapshot | 1 000 | 1 000 | 7.52 ms | 0.488 ms | 15× |
| snapshot | 10 000 | 10 | 0.171 ms | 8.56 µs | 20× |
| snapshot | 10 000 | 1 000 | 5.48 ms | 0.473 ms | 12× |
| history_page(0, 1000) | 1 000 | 10 | 3.50 ms | 0.207 ms | 17× |
| history_page(0, 1000) | 10 000 | 10 | 3.85 ms | 0.179 ms | 22× |
| full paged scan (limit 1000) | 1 000 | 10 | 3.69 ms | 0.181 ms | 20× |
| full paged scan (limit 1000) | 10 000 | 10 | 150.5 ms | 1.94 ms | 78× |
| net_document | 1 000 | 10 | 275 ms | 32.3 ms | 8.5× |
| net_document | 10 000 | 10 | 1 914 ms | 431 ms | 4.4× |
| net_document | 1 000 | 1 000 | 15 351 ms | 3 656 ms | 4.2× |

## Notes

- **The full scan.** Both sides read the records once per scan; the Haskell
  scan shares one captured `Seq`. The Python scan of 11 pages costs about 40×
  its single page rather than 11×. I did not profile why; garbage collection
  over the larger live heap is a plausible cause. The Haskell scan grows
  linearly.
- **`net_document` (N = 10 000, M = 1 000) is not measured.** It is 10⁷
  tokens of lineage markings, and Python would take minutes per run. The
  document's cost is O(N × M) on both sides: one complete marking per
  record. The Haskell time is dominated by building and validating those
  markings, then by the Net document's own serialization check.
- **The snapshot is independent of N.** Only the frontier (the History
  length) is read from the records.
