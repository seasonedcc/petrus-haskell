# Thread lifecycle benchmark results

<!-- scripts/bench: measured sources 58b8b899b48a81e2 at 13f7a84d2779 -->

Workload: 1000 Episodes × 4 Turns on one Thread (each Turn accepts one
append and settles completed; each Episode settles completed with a fresh
Continuation). Both sides run the same five measurements.

## Current figures

Measured on 2026-10-12, 22:18–22:26 local (UTC-3), at commit `424aa4e`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.80–2.65:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-core 3 --python python_catalog.py --python python_effect.py --python python_hands.py --python python_thread.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same three repetitions measured the other results files' rows (see [RESULTS.md](RESULTS.md)). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `thread.build-1000x4` | 13.8 ms | 21.6 s | 1566.40× | 1558.00× | 3 of 3 | 13.7 ms, 13.8 ms, 13.8 ms | 21.6 s, 22.2 s, 21.5 s |
| `thread.episode-after-1000` | 21.2 µs | 42.9 ms | 2022.56× | 2016.81× | 3 of 3 | 21.2 µs, 21.4 µs, 21.2 µs | 42.8 ms, 43.6 ms, 42.9 ms |
| `thread.to-json-1000x4` | 4.76 ms | 10.1 ms | 2.12× | 2.10× | 3 of 3 | 4.75 ms, 4.76 ms, 4.79 ms | 10.1 ms, 10.1 ms, 10.1 ms |
| `thread.dumps-only-1000x4` | 3.08 ms | 6.02 ms | 1.95× | 1.93× | 3 of 3 | 3.1 ms, 3.03 ms, 3.08 ms | 5.97 ms, 6.06 ms, 6.02 ms |
| `thread.from-data-1000x4` | 13.2 ms | 56.4 ms | 4.25× | 4.16× | 3 of 3 | 13.2 ms, 13.2 ms, 13.4 ms | 56.4 ms, 56.5 ms, 56 ms |

## Earlier figures

Environment: Apple M4, macOS 26.3, 2026-10-10. GHC 9.10.3 (`-O2 -threaded`,
`-with-rtsopts=-A32m`, run with `+RTS -A32m -M2G -RTS`), tasty-bench means
(`--stdev 3`). Python 3.14.6 (upstream `.venv`), the script's median of
batches.

Method: five interleaved rounds (Haskell bench, then Python script, each
round), run as `python_thread.py --skip-build`. The table gives the median
of the five rounds. The Python build row comes from one extra full run of
`python_thread.py` right after them: each of its iterations takes about 20 s.
The machine was shared with other work (load average 3.7 to 5.8).

<!-- bench: superseded -->

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
