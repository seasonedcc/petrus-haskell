# petrus-simulation benchmarks

This compares the Haskell runner and service with upstream
`petrus.simulation` and `petrus.simulation_http` at the pin in
[UPSTREAM.md](../../../UPSTREAM.md). Ratios above 1 mean Haskell is faster.
Haskell is faster on every row.

- Date: 2026-10-10. Commit: `146bfdd`.
- Machine: Darwin arm64, Apple M4 (10 cores, 24 GB). Other work was running
  on the machine, so each table gives the 1-minute load average measured
  with it.
- Haskell: GHC 9.10.3 at `-O2`, `-threaded` on one capability, run with
  `+RTS -M2G`.
- Python: CPython 3.14.6 from the upstream venv.

## How to rerun

From the repository root, with `~/.ghcup/bin` on `PATH`:

```bash
# simulate and round-trip rows: alternates cabal bench and bench/python_bench.py, 3 repetitions
python3 packages/petrus-simulation/bench/interleave.py 3
# load: one Haskell client drives both services, 5 interleaved repetitions
cabal bench petrus-simulation -j2 --benchmark-options "load 5 +RTS -M2G -RTS"
```

`scripts/bench petrus-simulation` runs the first set of rows once, without
interleaving, and replaces this file with its plain table.

## Runner and round trips

On the Haskell side the `simulate.*` rows time `simulate`, and on the Python
side `petrus.simulation.simulate`. The `http.*` rows make one request per
iteration to a service over the owner fixture build. Each request uses a
fresh loopback connection, read to the end and closed with a reset
(`SO_LINGER` 0). Each language uses its own client: `network` under
tasty-bench (mean) for Haskell, and `socket` under
`scripts/bench_timing.py` (median of timed batches) for Python.

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

The table gives the median over three interleaved repetitions. The 1-minute
load average was 2.26 to 3.64.

| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `simulate.fixture-32` | 214 µs | 2.81 ms | 13.10× | 214 µs, 214 µs, 229 µs | 2.79 ms, 2.81 ms, 2.89 ms |
| `simulate.loop-24x256` | 63.1 ms | 1.7 s | 27.02× | 63.1 ms, 62.9 ms, 65.5 ms | 1.7 s, 1.69 s, 1.71 s |
| `simulate.loop-512x256-oversized` | 1.03 s | 6.79 s | 6.56× | 1.03 s, 1.03 s, 1.16 s | 6.57 s, 6.96 s, 6.79 s |
| `simulate.scan-480x16` | 190 ms | 972 ms | 5.10× | 180 ms, 190 ms, 208 ms | 967 ms, 999 ms, 972 ms |
| `simulate.payload-990k-rest` | 4.75 ms | 187 ms | 39.38× | 4.75 ms, 4.75 ms, 4.99 ms | 187 ms, 187 ms, 190 ms |
| `simulate.payload-400k-fire` | 4.7 ms | 224 ms | 47.59× | 4.54 ms, 4.7 ms, 4.86 ms | 223 ms, 224 ms, 224 ms |
| `simulate.refused-scan-bound` | 321 µs | 1.39 ms | 4.33× | 291 µs, 321 µs, 372 µs | 1.39 ms, 1.39 ms, 1.39 ms |
| `http.profile` | 62.6 µs | 124 µs | 1.98× | 62.2 µs, 62.6 µs, 62.8 µs | 126 µs, 124 µs, 123 µs |
| `http.options` | 61.4 µs | 122 µs | 1.99× | 61.4 µs, 63.4 µs, 60.7 µs | 122 µs, 121 µs, 123 µs |
| `http.invalid-400` | 64.9 µs | 145 µs | 2.24× | 62.6 µs, 66.6 µs, 64.9 µs | 145 µs, 144 µs, 148 µs |
| `http.simulate-fixture-32` | 339 µs | 3.16 ms | 9.31× | 308 µs, 339 µs, 345 µs | 3.16 ms, 3.09 ms, 3.26 ms |

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

The table gives the median over 5 repetitions of throughput and of the
per-request p50 and p99 latencies. The 1-minute load average was 2.95 to
3.12.

| Scenario | Clients | Haskell req/s | Haskell p50 / p99 | Python req/s | Python p50 / p99 | Haskell / Python |
|---|---:|---:|---:|---:|---:|---:|
| GET profile | 1 | 14191 | 63 µs / 140 µs | 8654 | 109 µs / 183 µs | 1.64× |
| GET profile | 4 | 18874 | 203 µs / 350 µs | 9663 | 385 µs / 738 µs | 1.95× |
| OPTIONS preflight | 1 | 15194 | 62 µs / 116 µs | 8570 | 108 µs / 209 µs | 1.77× |
| POST invalid body (400) | 1 | 13514 | 70 µs / 115 µs | 7328 | 129 µs / 206 µs | 1.84× |
| POST invalid body (400) | 4 | 17296 | 223 µs / 333 µs | 7908 | 461 µs / 877 µs | 2.19× |
| POST fixture, 32 actions | 1 | 2410 | 344 µs / 537 µs | 296 | 3.19 ms / 4.70 ms | 8.13× |

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
