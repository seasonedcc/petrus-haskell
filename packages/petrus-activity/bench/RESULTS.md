# petrus-activity benchmarks: Haskell vs the pinned `petrus.motus.activity`

<!-- scripts/bench: measured sources 56fd31b74e97d5ce at 561723ecaadb -->
<!-- scripts/bench: carried to dd562a511befd5d2 at c33829edc562: only petrus-json/posix library changes upstream of it (json.loads refusal path, new helpers, docs, uuid hex digit); the admit paths it measures are unchanged -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` run the Activity
value doors on the same inputs. Every row runs one door over 100 distinct
inputs, so each figure is the time for 100 calls.

| row | the door | inputs |
| --- | --- | --- |
| `policy.construct` | `ExecutionPolicy(...)` / `executionPolicy` | 100 policies with a retry schedule and both deadlines |
| `policy.delay` | `RetryPolicy.delay(n)` / `retryDelay` | `RetryPolicy(0.5, 2, 60, 10, 0)`, failed attempts 1 to 100 (the float path below saturation, then the saturated one) |
| `invocation.construct` | `ActivityInvocation(...)` / `activityInvocation` | 100 invocations with an order payload, a resolved policy and a correlation |
| `failure.construct` | `ActivityFailure(...)` / `activityFailure` | 100 failures with a details object: the bounds, `retry_after`, and the details' `json.dumps` and 16 384-byte check |
| `heartbeat.snapshot` | `snapshot_heartbeat_details` / `snapshotHeartbeatDetails` | 100 progress objects with a 10-line log: the finiteness pass, `json.dumps` and the 65 536-byte check |
| `payload.convert` | `JsonPayloadConverter().decode` / `jsonPayloadConverter.decodePayload` | the 100 order payloads |
| `definition.call` | `ActivityDefinition.__call__` / `callActivity` | a three-parameter `charge` Activity (the `@activity` decorator in Python, `defineActivity` in Haskell) called with 100 invocations: name check, parameter set, decoding each parameter, running, encoding the result |

The doors do the same work on both sides. In Python a value door also
allocates the frozen dataclass; in Haskell the record exists before the door
validates it. The difference shows most on `invocation.construct`, where
the validation itself is two string checks.

## Current figures

Measured on 2026-10-12, 22:15–22:16 local (UTC-3), at commit `561723e`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.96–2.27:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-activity 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `policy.construct` | 7.73 µs | 153 µs | 19.75× | 19.60× | 3 of 3 | 7.6 µs, 7.73 µs, 7.74 µs | 153 µs, 151 µs, 153 µs |
| `policy.delay` | 6.91 µs | 16.7 µs | 2.42× | 2.41× | 3 of 3 | 6.84 µs, 6.93 µs, 6.91 µs | 16.7 µs, 16.8 µs, 16.6 µs |
| `invocation.construct` | 527 ns | 43.8 µs | 83.13× | 82.65× | 3 of 3 | 522 ns, 527 ns, 527 ns | 43.8 µs, 44 µs, 43.6 µs |
| `failure.construct` | 45.7 µs | 313 µs | 6.84× | 6.82× | 3 of 3 | 45.3 µs, 45.8 µs, 45.7 µs | 310 µs, 313 µs, 314 µs |
| `heartbeat.snapshot` | 56 µs | 492 µs | 8.78× | 8.78× | 3 of 3 | 55.7 µs, 56 µs, 56.1 µs | 489 µs, 492 µs, 495 µs |
| `payload.convert` | 86.4 µs | 379 µs | 4.38× | 4.37× | 3 of 3 | 85.6 µs, 86.4 µs, 86.6 µs | 374 µs, 379 µs, 382 µs |
| `definition.call` | 159 µs | 950 µs | 5.97× | 5.86× | 3 of 3 | 158 µs, 159 µs, 163 µs | 937 µs, 950 µs, 953 µs |

## How to rerun

From the repository root (`scripts/bench petrus-activity` runs exactly this
block; `scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-activity --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-activity/bench/python_bench.py)
```

`scripts/bench-compare petrus-activity 3` interleaves the two, which is how
the table below was taken.

## Numbers

Apple M4 (10 cores, 24 GiB), macOS 26.3.1, GHC 9.10.3 (`-O2`), CPython 3.14.6;
2026-10-11. Three interleaved repetitions (`scripts/bench-compare
petrus-activity 3`), with the one-minute load average between 4.1 and 7.6
(other builds were running on the machine). Haskell figures are tasty-bench
means in wall-clock time (`localOption WallTime`, `--stdev 5`, `+RTS -M2G`);
Python figures are `scripts/bench_timing.py` medians
(`time.perf_counter_ns`). Each cell is the median over the repetitions;
ratios read Python ÷ Haskell (how many times faster Haskell is).

<!-- bench: superseded -->

| row (100 calls) | Haskell | Python | Python ÷ Haskell | lowest repetition |
|---|---:|---:|---:|---:|
| `policy.construct` | 9.04 µs | 167 µs | 18.5× | 17.4× |
| `policy.delay` | 6.98 µs | 18.6 µs | 2.67× | 2.31× |
| `invocation.construct` | 603 ns | 57.1 µs | 94.7× | 76.6× |
| `failure.construct` | 65.9 µs | 449 µs | 6.81× | 5.50× |
| `heartbeat.snapshot` | 83.4 µs | 781 µs | 9.36× | 8.30× |
| `payload.convert` | 113 µs | 495 µs | 4.39× | 3.81× |
| `definition.call` | 208 µs | 1.03 ms | 4.94× | 3.57× |
