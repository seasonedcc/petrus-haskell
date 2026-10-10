# Telemetry overhead: Haskell vs the pinned reference

Two twin programs measure the same workloads:

- [`Main.hs`](Main.hs), a tasty-bench benchmark;
- [`python_bench.py`](python_bench.py), a timing script run against the
  pinned upstream checkout.

## Same bytes on both sides

Both programs print the routed line for the emit payload with `ts` pinned to
`1700000000123`. The two lines are byte-identical:

```
{"event": "impetus_firing_completed", "instance": "i-1", "net": "n", "transition": "t", "occurrence": 1, "instant": 7, "records": 3, "impure": false, "source": "s", "ts": 1700000000123}
```

This payload is also the first `pinned` entry of
[`../differential/telemetry_scenarios.json`](../differential/telemetry_scenarios.json).
`DifferentialSpec` checks there that the Haskell `jsonLoggerWith` writes the
same bytes as the reference's `JsonLogger`.

## Machine and settings

| | |
|---|---|
| Machine | Apple M4, 24 GB, macOS (Darwin 25.3) |
| Load | ~6.5–9 load average during the runs; other builds and agents were running |
| Haskell | GHC 9.10.3, benchmark `-O2 -with-rtsopts=-A32m`, libraries at their own `-O2`; tasty-bench `--stdev 5` |
| Python | CPython 3.14.6, the upstream `.venv` at pin `3f85fc2` |
| Timing (Python) | emits and lines: median of 50 runs; chains: median of 15 (instance) or 11 (engine) interleaved rounds after one warm-up round |

The machine was loaded, so numbers moved by about ±10% between runs. Read
the ratios, not the last digit.

## (a) Per-emit cost

One 6-field payload (`transition`, `occurrence`, `instant`, `records`,
`impure`, `source`) is emitted through `get_logger("impetus")` bound to
`instance` and `net`. Each figure is per emit, averaged over 1 000 emits.

| Configuration | Haskell | Python | Notes |
|---|---:|---:|---|
| level `off` | 0.004 µs | 0.47 µs | one level read, then return |
| `facts`, no route / no handler (the default) | 0.063 µs | 7.5 µs | Haskell never formats an unrouted line; Python runs `json.dumps` and creates a `LogRecord` that the logger then drops |
| `facts`, null route / `NullHandler` | 4.6 µs | 14.4 µs | the line is formatted and stamped with `ts`, then dropped |
| `facts` under `capture()` (recorder) | 0.079 µs | 1.6 µs | the payload is kept as a value and never formatted |

The cost of formatting one line, on the full 9-field payload plus `ts`:

| Step | Haskell | Python |
|---|---:|---:|
| render the line (`telemetryLine` / `json.dumps`) | 2.4 µs | 4.3 µs |
| read the wall clock (`wallClockMs` / `time.time()`) | 0.24 µs | 0.07 µs |

A routed Haskell emit costs about 3× less than the reference's.

Most of the Haskell cost is in `petrus-json`'s CPython-exact encoder. Each
string (key or value) costs about 0.1–0.15 µs. The rest is the payload
merges in `emit` (`dictUnion`, which is quadratic in key comparisons on
these short lists).

Two changes were tried:

- a small first buffer for the builder;
- a distinct-keys fast path for `dictUnion`.

On this loaded machine neither moved the result beyond run-to-run noise
(2.4 → 2.4–2.8 ms per 1 000 lines), so neither was kept. The shared
packages are unchanged.

## (b) A 1 000-firing chain, telemetry `off` vs `facts`

50 tokens go through 20 passthrough transitions, 1 000 firings in all. The
chain is driven two ways:

- `run` on an Instance (`Instance.run()` in Python);
- one-action `Engine.advance` turns until the net is not ready. This
  produces 5 002 History records on both sides.

| Workload | Configuration | Haskell | Python |
|---|---|---:|---:|
| instance-run | off | 22.5 ms | 371 ms |
| | facts, no route / no handler | 22.6 ms (+0.4%) | 402 ms (+8.3%) |
| | facts, null route / `NullHandler` | 30.0 ms (**+33%**) | 430 ms (**+16%**) |
| engine-advance | off | 52.5 ms | 606 ms |
| | facts, no route / no handler | 54.0 ms (+2.9%) | 590 ms (−2.6%, noise) |
| | facts, null route / `NullHandler` | 74.0 ms (**+41%**) | 660 ms (**+8.9%**) |

The routed overhead is a larger *percentage* in Haskell, because the work
it is measured against is 12–16× cheaper. In absolute terms, routed
telemetry costs:

| Workload | Haskell | Python | Haskell is |
|---|---:|---:|---|
| instance-run | ~7.5 µs per firing | ~59 µs per firing | ~8× cheaper |
| engine-advance | ~21 µs per firing | ~54 µs per firing | ~2.5× cheaper |

With the default configuration (no route), Haskell telemetry is within
noise of `off`, because unrouted lines are never formatted. Python pays
+8% on the instance chain even with no handler configured.

## Rerun

```sh
export PATH=$HOME/.ghcup/bin:$PATH
cabal bench petrus-telemetry-instrumentation-bench --benchmark-options='--stdev 5'

cd upstream/petrus
.venv/bin/python ../../packages/petrus-telemetry-instrumentation/bench/python_bench.py
```
