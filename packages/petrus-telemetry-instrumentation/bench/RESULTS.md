# Telemetry overhead: Haskell vs the pinned reference

<!-- scripts/bench: measured sources 2b552b9fc9fa63d0 at a772fc9389d5 -->

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
| Load | 2.1–2.8 load average (1-minute) during the runs, on 2026-10-12, 02:52–02:55 local (UTC-3), at commit `81bbdc5`: three interleaved repetitions of `scripts/bench-compare petrus-telemetry-instrumentation 3`, alternating which side goes first; each figure is the median of the three |
| Haskell | GHC 9.10.3, benchmark `-O2 -with-rtsopts=-A32m`, libraries at their own `-O2`; tasty-bench `--stdev 5`, run with `+RTS -M2G` |
| Python | CPython 3.14.6, the upstream `.venv` at pin `3f85fc2` |
| Timing (Python) | emits and lines: median of 50 runs; chains: median of 15 (instance) or 11 (engine) interleaved rounds after one warm-up round |

Numbers move by about ±10% between runs. Read the ratios, not the last
digit. An earlier run at a load average of 6.5–9 gave Haskell and Python
figures 1.1–3× higher than these, in the same order; the run before this
one (2026-10-11, load 3.5–3.7) was within about 10% of these figures.

## (a) Per-emit cost

One 6-field payload (`transition`, `occurrence`, `instant`, `records`,
`impure`, `source`) is emitted through `get_logger("impetus")` bound to
`instance` and `net`. Each figure is per emit, averaged over 1 000 emits.

| Configuration | Haskell | Python | Notes |
|---|---:|---:|---|
| level `off` | 0.003 µs | 0.17 µs | one level read, then return |
| `facts`, no route / no handler (the default) | 0.056 µs | 2.5 µs | Haskell never formats an unrouted line; Python runs `json.dumps` and creates a `LogRecord` that the logger then drops |
| `facts`, null route / `NullHandler` | 2.5 µs | 4.5 µs | the line is formatted and stamped with `ts`, then dropped |
| `facts` under `capture()` (recorder) | 0.068 µs | 0.68 µs | the payload is kept as a value and never formatted |

The cost of formatting one line, on the full 9-field payload plus `ts`:

| Step | Haskell | Python |
|---|---:|---:|
| render the line (`telemetryLine` / `json.dumps`) | 0.77 µs | 1.8 µs |
| read the wall clock (`wallClockMs` / `time.time()`) | 0.22 µs | 0.05 µs |

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
| instance-run | off | 19.4 ms | 193 ms |
| | facts, no route / no handler | 19.5 ms (+0.5%, noise) | 202 ms (+4.7%) |
| | facts, null route / `NullHandler` | 23.7 ms (**+22%**) | 213 ms (**+10%**) |
| | profile, no route / no handler | 19.5 ms (+0.5%, noise) | 202 ms (+4.7%) |
| | profile, null route / `NullHandler` | 23.6 ms (**+22%**) | 213 ms (**+10%**) |
| engine-advance | off | 45.5 ms | 400 ms |
| | facts, no route / no handler | 46.3 ms (+1.8%) | 418 ms (+4.5%) |
| | facts, null route / `NullHandler` | 57.7 ms (**+27%**) | 438 ms (**+9.5%**) |
| | profile, no route / no handler | 49.4 ms (+8.6%) | 427 ms (+6.8%) |
| | profile, null route / `NullHandler` | 68.0 ms (**+49%**) | 450 ms (**+12.5%**) |

The routed overhead is a larger *percentage* in Haskell, because the work
it is measured against is 9–10× cheaper. In absolute terms, routed
telemetry costs:

| Workload | Configuration | Haskell | Python | Haskell is |
|---|---|---:|---:|---|
| instance-run | facts | ~4.3 µs per firing | ~20 µs per firing | ~4.5× cheaper |
| engine-advance | facts | ~12 µs per firing | ~38 µs per firing | ~3× cheaper |
| engine-advance | profile | ~23 µs per firing | ~50 µs per firing | ~2× cheaper |
| engine-advance | profile, unrouted | ~3.9 µs per firing | ~27 µs per firing | ~7× cheaper |

With the default configuration (no route), Haskell `facts` telemetry is
within noise of `off`, because unrouted lines are never formatted.
Unrouted `profile` still computes the Engine's gauges after each action,
so it costs about 9% on the Engine chain (Python: about 7%, at seven times
the absolute cost).

## Rerun

From the repository root (`scripts/bench petrus-telemetry-instrumentation`
runs exactly this; `scripts/upstream-python` provisions the pinned
reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-telemetry-instrumentation --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-telemetry-instrumentation/bench/python_bench.py)
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`; the tables above are in
wall-clock time. The run before them was taken in tasty-bench's default CPU
time; this workload is single-threaded and does no I/O inside the timed
region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).
