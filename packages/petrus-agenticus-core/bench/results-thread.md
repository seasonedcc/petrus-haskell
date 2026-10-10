# Thread lifecycle benchmark results

Workload: 1000 Episodes × 4 Turns on one Thread (each Turn accepts one
append and settles completed; each Episode settles completed with a fresh
Continuation). Both sides run the same five measurements.

Environment: Apple M4, macOS 26.3, GHC 9.10.3 (`-O2 -threaded`,
`-with-rtsopts=-A32m`, run with `+RTS -M2G -RTS`), tasty-bench; Python 3.14.6
(upstream `.venv`), `time.perf_counter` best-of-N.

| Benchmark | Haskell | Python | Ratio (Py/Hs) |
| --- | --- | --- | --- |
| build-1000x4 | 18.3 ms ± 1.8 | 51 694 ms | ~2 800× |
| episode-after-1000 | 29.8 µs ± 3.0 | 94.1 ms | ~3 100× |
| to-json-1000x4 (to-data + dumps) | 28.5 ms ± 0.4 | 18.7 ms | 0.66× |
| dumps-only-1000x4 | 24.2 ms ± 2.0 | 10.2 ms | 0.42× |
| from-data-1000x4 | 22.3 ms ± 1.7 | 103.4 ms | ~4.6× |

Earlier quiet Haskell run (same binary): build 30.8 ms, episode 43.8 µs,
to-json 37.2 ms, dumps-only 34.4 ms, from-data 30.4 ms. A second Python run
under machine load measured build 56 200 ms, episode 184.3 ms, to-json
59.9 ms, from-data 206.3 ms. The machine was shared with other builds, so
treat single-digit-percent differences as noise.

## Findings

- Python's build is quadratic: every `Thread` transition revalidates every
  prior Episode (`dataclasses.replace` re-runs `__post_init__`). The Haskell
  port validates only the Episode being changed plus the Thread invariants
  that span Episodes, which keeps building linear without changing any
  accepted or refused outcome (checked by the differential corpus).
- Haskell is slower at pure JSON encoding. `dumps-only` is entirely
  `Petrus.Json.dumpsText defaultDumps` (shared `petrus-json` Builder encoder)
  against CPython's C-accelerated `json.dumps`. It is GC-sensitive: 18.6 ms
  with `-A128m`, and a large-chunk Builder strategy reached 22.7 ms.
  `petrus-json` is a shared package with concurrent edits, so it is left
  unchanged here. Follow-up: an escaping fast path for ASCII-only strings
  and pre-sized strict output in `petrus-json`.
- `to-json` (Thread → `Json` → text) is the same story: the to-data half is
  ~4 ms; the rest is the encoder.

## Rerun

```sh
cabal -j2 bench petrus-agenticus-core --benchmark-options='-p thread +RTS -M2G -RTS'
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_thread.py
```
