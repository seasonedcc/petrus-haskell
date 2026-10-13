# petrus-simulation benchmarks

<!-- scripts/bench: measured sources e555967bba1f7abe at e506718a0833 -->

This compares the Haskell runner and service with upstream
`petrus.simulation` and `petrus.simulation_http` at the pin in
[UPSTREAM.md](../../../UPSTREAM.md). Ratios above 1 mean Haskell is faster.
Haskell is faster on every row.

## Current figures

Measured on 2026-10-12, 23:17–23:24 local (UTC-3), at commit `ba2323d`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 3.64–4.40:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-simulation 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `simulate.fixture-32` | 160 µs | 2.78 ms | 17.35× | 17.22× | 3 of 3 | 160 µs, 160 µs, 162 µs | 2.78 ms, 2.82 ms, 2.78 ms |
| `simulate.loop-24x256` | 41.2 ms | 1.67 s | 40.65× | 39.75× | 3 of 3 | 41.9 ms, 40.8 ms, 41.2 ms | 1.66 s, 1.68 s, 1.67 s |
| `simulate.loop-512x256-oversized` | 708 ms | 6.64 s | 9.39× | 9.18× | 3 of 3 | 708 ms, 717 ms, 692 ms | 6.65 s, 6.59 s, 6.64 s |
| `simulate.scan-480x16` | 159 ms | 959 ms | 6.04× | 5.73× | 3 of 3 | 159 ms, 167 ms, 156 ms | 979 ms, 957 ms, 959 ms |
| `simulate.payload-990k-rest` | 10.6 ms | 185 ms | 17.56× | 17.44× | 3 of 3 | 10.5 ms, 10.6 ms, 10.6 ms | 187 ms, 185 ms, 185 ms |
| `simulate.payload-400k-fire` | 11.9 ms | 223 ms | 18.81× | 18.58× | 3 of 3 | 11.9 ms, 11.9 ms, 11.9 ms | 223 ms, 220 ms, 226 ms |
| `simulate.refused-scan-bound` | 96.7 µs | 1.39 ms | 14.33× | 14.22× | 3 of 3 | 97.5 µs, 95.2 µs, 96.7 µs | 1.39 ms, 1.37 ms, 1.39 ms |
| `http.profile` | 71.2 µs | 128 µs | 1.79× | 1.68× | 3 of 3 | 72.4 µs, 71.2 µs, 69.5 µs | 128 µs, 120 µs, 129 µs |
| `http.options` | 71.8 µs | 123 µs | 1.71× | 1.68× | 3 of 3 | 70.4 µs, 71.8 µs, 72.8 µs | 123 µs, 123 µs, 122 µs |
| `http.invalid-400` | 76.1 µs | 145 µs | 1.91× | 1.88× | 3 of 3 | 77.3 µs, 74.1 µs, 76.1 µs | 145 µs, 141 µs, 151 µs |
| `http.simulate-fixture-32` | 269 µs | 3.1 ms | 11.52× | 11.40× | 3 of 3 | 269 µs, 272 µs, 258 µs | 3.14 ms, 3.1 ms, 3.06 ms |

## Earlier figures

- Date: 2026-10-10. Runner and round trips: 21:14–21:22 local (UTC-3), commit `74e6b1e` with
  the switch to wall-clock time in `bench/Main.hs`. Load: commit `146bfdd`.
- Machine: Darwin arm64, Apple M4 (10 cores, 24 GB). Other work was running
  on the machine, so each table gives the 1-minute load average measured
  with it.
- Haskell: GHC 9.10.3 at `-O2`, `-threaded` on one capability, run with
  `+RTS -M2G`.
- Python: CPython 3.14.6 from the upstream venv.

## How to rerun

From the repository root (`scripts/bench petrus-simulation` runs exactly this block, once;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
# simulate and round-trip rows: the Haskell rows, then the Python twin
scripts/bench-run petrus-simulation --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-simulation/bench/python_bench.py)
# load: one Haskell client drives both services, 5 interleaved repetitions
scripts/bench-run petrus-simulation load 5 +RTS -M2G -RTS
```

`scripts/bench-compare petrus-simulation 3` interleaves three runs of the simulate and
round-trip rows on both sides and prints the table below.

## Runner and round trips

On the Haskell side the `simulate.*` rows time `simulate`, and on the Python
side `petrus.simulation.simulate`. The `http.*` rows make one request per
iteration to a service over the owner fixture build. Each request uses a
fresh loopback connection, read to the end and closed with a reset
(`SO_LINGER` 0). Each language uses its own client: `network` under
tasty-bench (mean, wall-clock time) for Haskell, and `socket` under
`scripts/bench_timing.py` (median of timed batches, wall-clock time) for
Python.

| Row | What runs |
| --- | --- |
| `simulate.fixture-32` | the owner fixture (`build_scenario()`), `max_actions` 32 |
| `simulate.loop-24x256` | `a → t → a` with 24 black tokens, all 256 actions |
| `simulate.loop-512x256-oversized` | the same Net with 512 tokens: 256 actions, then the result is refused because it is larger than 4 MiB once fully serialized |
| `simulate.scan-480x16` | 20 transitions consuming from and producing to `a`, 480 tokens, 16 actions (near the 10,000 input-scan bound) |
| `simulate.payload-990k-rest` | one 990 KB token and no transitions: admission, the payload bounds and the result |
| `simulate.payload-400k-fire` | one 400 KB token moved from `a` to `b` by one action |
| `simulate.refused-scan-bound` | 20 sink transitions over 512 tokens, refused at admission by the scan bound |
| `http.profile` | `GET /v1/simulation-profile` |
| `http.options` | `OPTIONS /v1/simulations` |
| `http.invalid-400` | `POST /v1/simulations` with `"max_actions":true` |
| `http.simulate-fixture-32` | `POST /v1/simulations` for the owner fixture, 32 actions |

The table gives the median over three interleaved repetitions
(`scripts/bench-compare petrus-simulation 3`). The 1-minute load average was
2.98 to 9.86 (other work spiked during the run); the three repetitions agree
closely on both sides.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `simulate.fixture-32` | 166 µs | 2.85 ms | 17.12× | 166 µs, 174 µs, 166 µs | 2.85 ms, 2.84 ms, 2.86 ms |
| `simulate.loop-24x256` | 49.1 ms | 1.68 s | 34.18× | 49.5 ms, 48.5 ms, 49.1 ms | 1.68 s, 1.67 s, 1.69 s |
| `simulate.loop-512x256-oversized` | 843 ms | 6.65 s | 7.89× | 843 ms, 812 ms, 849 ms | 6.65 s, 6.6 s, 6.81 s |
| `simulate.scan-480x16` | 164 ms | 982 ms | 5.98× | 164 ms, 162 ms, 165 ms | 1.01 s, 966 ms, 982 ms |
| `simulate.payload-990k-rest` | 13.1 ms | 189 ms | 14.40× | 13.1 ms, 13 ms, 13.1 ms | 212 ms, 189 ms, 186 ms |
| `simulate.payload-400k-fire` | 12.7 ms | 228 ms | 17.90× | 12.7 ms, 12.6 ms, 12.8 ms | 241 ms, 228 ms, 224 ms |
| `simulate.refused-scan-bound` | 152 µs | 1.4 ms | 9.25× | 152 µs, 148 µs, 152 µs | 1.49 ms, 1.4 ms, 1.39 ms |
| `http.profile` | 70.3 µs | 130 µs | 1.84× | 71.4 µs, 70.3 µs, 69.1 µs | 130 µs, 122 µs, 132 µs |
| `http.options` | 71.9 µs | 122 µs | 1.69× | 82.2 µs, 71.9 µs, 66.9 µs | 122 µs, 122 µs, 126 µs |
| `http.invalid-400` | 71.9 µs | 144 µs | 2.00× | 68.7 µs, 73.4 µs, 71.9 µs | 144 µs, 141 µs, 148 µs |
| `http.simulate-fixture-32` | 274 µs | 3.18 ms | 11.57× | 287 µs, 268 µs, 274 µs | 3.11 ms, 3.23 ms, 3.18 ms |

These rows were first measured at `146bfdd` with tasty-bench's default CPU
time. The two clocks differ in both directions:

- The `http.*` round trips wait on the kernel for the connection and the
  response, which CPU time leaves out. They read 61–65 µs then and 70–72 µs
  now; against Python they went from 2.0–2.2× to 1.7–2.0×.
- The two payload rows take about 13 ms in wall-clock time, against 4.7 ms
  of CPU time. Their time goes to allocating and copying megabyte-sized
  strings; where the difference goes (page faults, the kernel's memory
  mapping) was not investigated. They remain 14–18× faster than Python.
- The other `simulate.*` rows are faster now than then (for example
  `simulate.fixture-32` 214 µs then, 166 µs now), most likely from library
  work merged since.

## Load

A single Haskell load client (`bench/Load.hs`) drives this service and the
upstream service with identical requests. The upstream service is started by
`test/reference_simulation.py real`. The client therefore costs the same on
both sides.

- **Same answers first.** Before measuring, it checks that both services
  answer each request with the same bytes, ignoring the `Server` and `Date`
  lines.
- **One connection per request.** Each request opens its own connection,
  sends, half-closes, reads to the end and resets.
- **At most 4 clients.** Both servers listen with CPython's backlog of 5.
  Past that, macOS drops SYNs and the client waits a full one-second
  retransmission, which would measure the kernel instead.
- **Simulations run with one client only.** The profile allows one
  simulation at a time and answers overlaps with 429, so concurrent
  simulations would measure refusals.
- **Repetitions.** Each repetition runs every scenario on both services,
  alternating which goes first, after a warm-up.

The table gives the median over 3 repetitions of throughput and of the
per-request p50 and p99 latencies, measured on 2026-10-12, 23:24–23:25
local (UTC-3), at commit `e506718`, with the 1-minute load average at 4.29
to 4.41, by `scripts/bench-run petrus-simulation load 3 +RTS -M2G -RTS`.
The five-repetition run at `81bbdc5` (load average 2.61 to 2.85) gave
1.68–11.02×, and an earlier run (load average 2.95 to 3.12) 1.64–8.13×.

| Scenario | Clients | Haskell req/s | Haskell p50 / p99 | Python req/s | Python p50 / p99 | Haskell / Python |
|---|---:|---:|---:|---:|---:|---:|
| GET profile | 1 | 14211 | 65 µs / 116 µs | 7407 | 112 µs / 404 µs | 1.92× |
| GET profile | 4 | 18249 | 198 µs / 266 µs | 10336 | 363 µs / 729 µs | 1.77× |
| OPTIONS preflight | 1 | 15317 | 63 µs / 88 µs | 8799 | 109 µs / 204 µs | 1.74× |
| POST invalid body (400) | 1 | 14040 | 69 µs / 96 µs | 7511 | 127 µs / 189 µs | 1.87× |
| POST invalid body (400) | 4 | 18225 | 218 µs / 286 µs | 8386 | 432 µs / 875 µs | 2.17× |
| POST fixture, 32 actions | 1 | 3065 | 275 µs / 626 µs | 313 | 3.13 ms / 4.13 ms | 9.79× |

## Notes

- **Server placement.** The Haskell service runs inside the benchmark
  process, on one capability, and shares it with the load client. The
  Python service runs in its own process under the GIL.
- **Where the lead comes from.** The smallest leads, about 1.6× to 2.2×,
  are on requests that do almost nothing but HTTP. There a large share of
  each round trip is the kernel's loopback connect, accept and teardown,
  which costs both servers the same. The largest leads are runs dominated
  by JSON encoding and canonical History records, such as the payload rows.
- **The oversized loop.** Both runtimes serialize a result larger than
  4 MiB before refusing it, because the profile's limit applies to the
  serialized bytes. The row therefore measures the full run plus a large
  serialization on both sides.
