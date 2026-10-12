# Thread lifecycle benchmark results

<!-- scripts/bench: measured sources 6dfbc2563f96dee2 at 5a73d7a7f019 -->

Workload: 1000 Episodes × 4 Turns on one Thread (each Turn accepts one
append and settles completed; each Episode settles completed with a fresh
Continuation). Both sides run the same five measurements.

## Current figures

Measured on 2026-10-12, 03:07–03:16 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.18–2.54:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-core 3 --python python_catalog.py --python python_effect.py --python python_hands.py --python python_thread.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same three repetitions measured the other results files' rows (see [RESULTS.md](RESULTS.md)). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `thread.build-1000x4` | 15.3 ms | 21.5 s | 1402.87× | 1402.87× | 15.4 ms, 15.3 ms, 15.3 ms | 21.8 s, 21.4 s, 21.5 s |
| `thread.episode-after-1000` | 23.5 µs | 42.7 ms | 1820.01× | 1786.66× | 24.3 µs, 23.5 µs, 23.5 µs | 43.4 ms, 42.7 ms, 42.7 ms |
| `thread.to-json-1000x4` | 3.96 ms | 10.2 ms | 2.56× | 2.49× | 4 ms, 3.96 ms, 3.96 ms | 9.97 ms, 10.2 ms, 10.2 ms |
| `thread.dumps-only-1000x4` | 3.4 ms | 6.01 ms | 1.77× | 1.76× | 3.42 ms, 3.4 ms, 3.36 ms | 6.01 ms, 6.16 ms, 5.96 ms |
| `thread.from-data-1000x4` | 15.4 ms | 56.3 ms | 3.66× | 3.59× | 15.3 ms, 15.4 ms, 15.8 ms | 56 ms, 56.3 ms, 56.6 ms |

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
