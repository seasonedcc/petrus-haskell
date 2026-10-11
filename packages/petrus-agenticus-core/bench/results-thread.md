# Thread lifecycle benchmark results

Workload: 1000 Episodes × 4 Turns on one Thread (each Turn accepts one
append and settles completed; each Episode settles completed with a fresh
Continuation). Both sides run the same five measurements.

Environment: Apple M4, macOS 26.3, 2026-10-10. GHC 9.10.3 (`-O2 -threaded`,
`-with-rtsopts=-A32m`, run with `+RTS -A32m -M2G -RTS`), tasty-bench means
(`--stdev 3`). Python 3.14.6 (upstream `.venv`), the script's median of
batches.

Method: five interleaved rounds (Haskell bench, then Python script, each
round), run as `python_thread.py --skip-build`. The table gives the median
of the five rounds. The Python build row comes from one extra full run of
`python_thread.py` right after them: each of its iterations takes about 20 s.
The machine was shared with other work (load average 3.7 to 5.8).

| Benchmark | Haskell | Python | Python / Haskell | Slowest round |
| --- | ---: | ---: | ---: | ---: |
| build-1000x4 | 16.6 ms | 22 431 ms | ~1 350× | (one run) |
| episode-after-1000 | 26.0 µs | 48.6 ms | ~1 870× | ~1 820× |
| to-json-1000x4 (to-data + dumps) | 4.17 ms | 10.6 ms | 2.5× | 2.5× |
| dumps-only-1000x4 | 3.43 ms | 6.26 ms | 1.8× | 1.8× |
| from-data-1000x4 | 17.1 ms | 60.8 ms | 3.6× | 3.3× |

Before petrus-json's encoder was rewritten, `to-json` was 0.66× (28.5 ms
against 18.7 ms) and `dumps-only` 0.42× (24.2 ms against 10.2 ms).

## Findings

- Python's build is quadratic: every `Thread` transition revalidates every
  prior Episode (`dataclasses.replace` re-runs `__post_init__`). The Haskell
  port validates only the Episode being changed plus the Thread invariants
  that span Episodes, which keeps building linear without changing any
  accepted or refused outcome (checked by the differential corpus).
- `dumps-only` is entirely `Petrus.Json.dumpsText defaultDumps` against
  CPython's C-accelerated `json.dumps`. petrus-json now writes in one pass
  into a growing buffer (no `Builder`, no lazy intermediate), scans each
  string once, and copies a string that needs no escaping with one
  `memcpy`. That took this row from 24.2 ms to 3.4 ms. The bytes are
  unchanged.
- `to-json` (Thread → `Json` → text) is the to-data half (about 0.7 ms) plus
  the encoder.

## Rerun

```sh
cabal -j2 bench petrus-agenticus-core --benchmark-options='-p thread +RTS -M2G -RTS'
cd upstream/petrus && .venv/bin/python -I -B ../../packages/petrus-agenticus-core/bench/python_thread.py  # --skip-build to leave out the slow row
```
