# Telemetry overhead: Haskell vs the pinned reference

<!-- scripts/bench: measured sources cabad18f45d52321 at d85b420a6b7b -->
<!-- scripts/bench: carried to 6118533e80fc655d at c33829edc562: only petrus-json/posix library changes upstream of it (json.loads refusal path, new helpers, docs, uuid hex digit); the admit paths it measures are unchanged -->

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
| Load | 4.3–8.5 load average (1-minute) during the runs, on 2026-10-12, 23:25–23:31 local (UTC-3), at commit `e506718`: three interleaved repetitions of `scripts/bench-compare petrus-telemetry-instrumentation 3`, alternating which side goes first; each figure is the median of the three |
| Haskell | GHC 9.10.3, benchmark `-O2 -with-rtsopts=-A32m`, libraries at their own `-O2`; tasty-bench `--stdev 5`, run with `+RTS -M2G` |
| Python | CPython 3.14.6, the upstream `.venv` at pin `3f85fc2` |
| Timing (Python) | emits and lines: median of 50 runs; chains: median of 15 (instance) or 11 (engine) interleaved rounds after one warm-up round |

Numbers move by about ±10% between runs. Read the ratios, not the last
digit. This run's load was higher than the previous one's (2.1–2.8 at
`81bbdc5`), yet both sides' figures are within about 10% of that run's, and
Haskell's mostly lower. An earlier run at a load average of 6.5–9 gave
Haskell and Python figures 1.1–3× higher, in the same order.

## (a) Per-emit cost

One 6-field payload (`transition`, `occurrence`, `instant`, `records`,
`impure`, `source`) is emitted through `get_logger("impetus")` bound to
`instance` and `net`. Each figure is per emit, averaged over 1 000 emits.

| Configuration | Haskell | Python | Notes |
|---|---:|---:|---|
| level `off` | 0.003 µs | 0.17 µs | one level read, then return |
| `facts`, no route / no handler (the default) | 0.058 µs | 2.5 µs | Haskell never formats an unrouted line; Python runs `json.dumps` and creates a `LogRecord` that the logger then drops |
| `facts`, null route / `NullHandler` | 2.1 µs | 4.5 µs | the line is formatted and stamped with `ts`, then dropped |
| `facts` under `capture()` (recorder) | 0.065 µs | 0.69 µs | the payload is kept as a value and never formatted |

The cost of formatting one line, on the full 9-field payload plus `ts`:

| Step | Haskell | Python |
|---|---:|---:|
| render the line (`telemetryLine` / `json.dumps`) | 0.58 µs | 1.8 µs |
| read the wall clock (`wallClockMs` / `time.time()`) | 0.22 µs | 0.05 µs |

A routed Haskell emit costs about 2.2× less than the reference's, and the
line itself about 3.1× less.

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
| instance-run | off | 17.6 ms | 196 ms |
| | facts, no route / no handler | 17.6 ms (+0%, noise) | 205 ms (+4.6%) |
| | facts, null route / `NullHandler` | 22.0 ms (**+25%**) | 217 ms (**+11%**) |
| | profile, no route / no handler | 17.5 ms (−0.6%, noise) | 204 ms (+4.1%) |
| | profile, null route / `NullHandler` | 21.6 ms (**+23%**) | 215 ms (**+9.7%**) |
| engine-advance | off | 40.8 ms | 409 ms |
| | facts, no route / no handler | 41.9 ms (+2.7%) | 426 ms (+4.2%) |
| | facts, null route / `NullHandler` | 51.2 ms (**+25%**) | 446 ms (**+9.0%**) |
| | profile, no route / no handler | 43.7 ms (+7.1%) | 436 ms (+6.6%) |
| | profile, null route / `NullHandler` | 61.2 ms (**+50%**) | 459 ms (**+12.2%**) |

The routed overhead is a larger *percentage* in Haskell, because the work
it is measured against is 10–11× cheaper. In absolute terms, routed
telemetry costs:

| Workload | Configuration | Haskell | Python | Haskell is |
|---|---|---:|---:|---|
| instance-run | facts | ~4.4 µs per firing | ~21 µs per firing | ~4.8× cheaper |
| engine-advance | facts | ~10 µs per firing | ~37 µs per firing | ~3.6× cheaper |
| engine-advance | profile | ~20 µs per firing | ~50 µs per firing | ~2.5× cheaper |
| engine-advance | profile, unrouted | ~2.9 µs per firing | ~27 µs per firing | ~9× cheaper |

With the default configuration (no route), Haskell `facts` telemetry is
within noise of `off`, because unrouted lines are never formatted.
Unrouted `profile` still computes the Engine's gauges after each action,
so it costs about 7% on the Engine chain (Python: about 7%, at nine times
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
