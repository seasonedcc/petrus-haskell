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
| Load | 3.5–3.7 load average during the runs (other agents were idle or building elsewhere); both sides ran back to back on 2026-10-11 |
| Haskell | GHC 9.10.3, benchmark `-O2 -with-rtsopts=-A32m`, libraries at their own `-O2`; tasty-bench `--stdev 5` |
| Python | CPython 3.14.6, the upstream `.venv` at pin `3f85fc2` |
| Timing (Python) | emits and lines: median of 50 runs; chains: median of 15 (instance) or 11 (engine) interleaved rounds after one warm-up round |

Numbers move by about ±10% between runs. Read the ratios, not the last
digit. An earlier run at a load average of 6.5–9 gave Haskell and Python
figures 1.1–3× higher than these, in the same order.

## (a) Per-emit cost

One 6-field payload (`transition`, `occurrence`, `instant`, `records`,
`impure`, `source`) is emitted through `get_logger("impetus")` bound to
`instance` and `net`. Each figure is per emit, averaged over 1 000 emits.

| Configuration | Haskell | Python | Notes |
|---|---:|---:|---|
| level `off` | 0.003 µs | 0.17 µs | one level read, then return |
| `facts`, no route / no handler (the default) | 0.057 µs | 2.6 µs | Haskell never formats an unrouted line; Python runs `json.dumps` and creates a `LogRecord` that the logger then drops |
| `facts`, null route / `NullHandler` | 2.5 µs | 4.5 µs | the line is formatted and stamped with `ts`, then dropped |
| `facts` under `capture()` (recorder) | 0.069 µs | 0.67 µs | the payload is kept as a value and never formatted |

The cost of formatting one line, on the full 9-field payload plus `ts`:

| Step | Haskell | Python |
|---|---:|---:|
| render the line (`telemetryLine` / `json.dumps`) | 0.78 µs | 1.8 µs |
| read the wall clock (`wallClockMs` / `time.time()`) | 0.23 µs | 0.05 µs |

A routed Haskell emit costs about 1.8× less than the reference's, and the
line itself about 2.3× less.

The rest of a routed Haskell emit is the payload merges in `emit`
(`dictUnion`, which is quadratic in key comparisons on these short lists)
and the wall-clock read. A distinct-keys fast path for `dictUnion` was
tried on an earlier, loaded run and did not move the result beyond
run-to-run noise, so it was not kept.

## (b) A 1 000-firing chain, telemetry `off`, `facts` and `profile`

50 tokens go through 20 passthrough transitions, 1 000 firings in all. The
chain is driven two ways:

- `run` on an Instance (`Instance.run()` in Python);
- one-action `Engine.advance` turns until the net is not ready. This
  produces 5 002 History records on both sides.

At `profile`, the Engine also emits its state gauges (`gauges`: History
length, occupied places, tokens, in-flight count, RSS) after
every applied action. An Instance emits nothing more at `profile` than at
`facts`, so the instance rows measure the same work twice.

| Workload | Configuration | Haskell | Python |
|---|---|---:|---:|
| instance-run | off | 20.9 ms | 199 ms |
| | facts, no route / no handler | 22.1 ms (+5.7%, noise) | 204 ms (+2.6%) |
| | facts, null route / `NullHandler` | 25.4 ms (**+22%**) | 217 ms (**+8.9%**) |
| | profile, no route / no handler | 20.1 ms (−3.8%, noise) | 207 ms (+4.0%) |
| | profile, null route / `NullHandler` | 25.7 ms (**+23%**) | 218 ms (**+9.2%**) |
| engine-advance | off | 49.9 ms | 409 ms |
| | facts, no route / no handler | 51.4 ms (+3.0%) | 428 ms (+4.5%) |
| | facts, null route / `NullHandler` | 63.3 ms (**+27%**) | 449 ms (**+9.7%**) |
| | profile, no route / no handler | 54.5 ms (+9.2%) | 434 ms (+5.9%) |
| | profile, null route / `NullHandler` | 74.7 ms (**+50%**) | 462 ms (**+12.7%**) |

The routed overhead is a larger *percentage* in Haskell, because the work
it is measured against is 8–10× cheaper. In absolute terms, routed
telemetry costs:

| Workload | Configuration | Haskell | Python | Haskell is |
|---|---|---:|---:|---|
| instance-run | facts | ~4.5 µs per firing | ~18 µs per firing | ~4× cheaper |
| engine-advance | facts | ~13 µs per firing | ~40 µs per firing | ~3× cheaper |
| engine-advance | profile | ~25 µs per firing | ~52 µs per firing | ~2× cheaper |
| engine-advance | profile, unrouted | ~4.6 µs per firing | ~24 µs per firing | ~5× cheaper |

With the default configuration (no route), Haskell `facts` telemetry is
within noise of `off`, because unrouted lines are never formatted.
Unrouted `profile` still computes the Engine's gauges after each action,
so it costs about 9% on the Engine chain (Python: about 6%, at five times
the absolute cost).

## Rerun

From the repository root (`scripts/bench petrus-telemetry-instrumentation`
runs exactly this; `scripts/upstream-python` provisions the pinned
reference):

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-telemetry-instrumentation --benchmark-options='--stdev 5 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-telemetry-instrumentation/bench/python_bench.py)
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).
