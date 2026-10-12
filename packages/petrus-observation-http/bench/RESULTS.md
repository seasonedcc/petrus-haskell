# petrus-observation-http benchmarks

<!-- scripts/bench: measured sources a1b138adf022aa8e at 7fc4ecb1d671 -->

This compares the Haskell observation server with the upstream
`petrus.engine.observation_http` at the pin in [UPSTREAM.md](../../../UPSTREAM.md).
Both serve the same Engine: the upstream test's Net with its move looping
back to `a`, advanced 100 times, which gives 201 History records
(`busyEngine` in `bench/Main.hs`, `make_busy_engine` in
`test/reference_observation.py`). Ratios above 1 mean Haskell is faster.
Haskell is faster on every row.

## Current figures

Measured on 2026-10-12, 02:39–02:40 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.86–3.03:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-observation-http 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `roundtrip.snapshot` | 60.6 µs | 213 µs | 3.51× | 3.49× | 58 µs, 60.6 µs, 61.2 µs | 210 µs, 213 µs, 214 µs |
| `roundtrip.document` | 4.19 ms | 22.4 ms | 5.35× | 5.27× | 4.16 ms, 4.25 ms, 4.19 ms | 22.6 ms, 22.4 ms, 22.4 ms |
| `roundtrip.history-100` | 130 µs | 534 µs | 4.10× | 3.83× | 124 µs, 139 µs, 130 µs | 541 µs, 534 µs, 529 µs |
| `roundtrip.refused-405` | 51.5 µs | 123 µs | 2.39× | 1.95× | 49.2 µs, 63.3 µs, 51.5 µs | 122 µs, 123 µs, 124 µs |

## Earlier figures

- Date: 2026-10-10. Round trips: 21:13–21:14 local (UTC-3), commit `74e6b1e` with the switch
  to wall-clock time in `bench/Main.hs`. Load: commit `146bfdd`.
- Machine: Darwin arm64, Apple M4 (10 cores, 24 GB). Other work was running
  on the machine, so the 1-minute load averages for each table are given
  with it.
- Haskell: GHC 9.10.3 at `-O2`, `-threaded`, run with `+RTS -M2G`.
- Python: CPython 3.14.6 from the upstream venv.

## How to rerun

From the repository root (`scripts/bench petrus-observation-http` runs exactly this block, once;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
# Round trips: the Haskell rows, then the Python twin
scripts/bench-run petrus-observation-http --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-observation-http/bench/python_bench.py)
# Load: one Haskell client drives both servers, 5 interleaved repetitions
scripts/bench-run petrus-observation-http load 5 +RTS -M2G -RTS
```

`scripts/bench-compare petrus-observation-http 3` interleaves three runs of the round-trip rows on
both sides and prints the table below.

## Round trips

Each iteration makes one request on a fresh loopback connection and reads
the response to the end. The connection is closed with a reset
(`SO_LINGER` 0), so `TIME_WAIT` sockets do not pile up. Each language uses
its own client:

- Haskell: `network` in tasty-bench, giving the mean in wall-clock time;
- Python: `socket`, through `scripts/bench_timing.py`, giving the median of
  timed batches (wall-clock time).

The requests are:

- `GET /v1/snapshot`;
- `GET /v1/document`, the Net document with 201 records;
- `GET /v1/history?after=0&limit=100`;
- `POST /v1/snapshot`, which is refused with 405.

The table gives the median over three interleaved repetitions
(`scripts/bench-compare petrus-observation-http 3`). The 1-minute load average
was 2.86 to 2.98.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `roundtrip.snapshot` | 70.6 µs | 221 µs | 3.13× | 70.6 µs, 67.2 µs, 73.8 µs | 221 µs, 215 µs, 226 µs |
| `roundtrip.document` | 4.72 ms | 23.9 ms | 5.07× | 4.72 ms, 4.88 ms, 4.63 ms | 24.2 ms, 23.9 ms, 23 ms |
| `roundtrip.history-100` | 192 µs | 592 µs | 3.08× | 183 µs, 202 µs, 192 µs | 593 µs, 591 µs, 592 µs |
| `roundtrip.refused-405` | 61.4 µs | 126 µs | 2.05× | 61.5 µs, 59.1 µs, 61.4 µs | 127 µs, 116 µs, 126 µs |

The round trips were first measured at `146bfdd` with tasty-bench's default
CPU time, which leaves out the time the client waits on the kernel: the two
small requests then read 61.2 µs and 44.4 µs, against 70.6 µs and 61.4 µs in
wall-clock time now. The document and History rows are faster now than then
(8.03 ms and 314 µs) despite the stricter clock, most likely from the
petrus-json speed work merged since; the load table below predates it.

## Load

A single Haskell load client (`bench/Load.hs`) drives this server and the
upstream server, started by `test/reference_observation.py busy`, with
identical requests. The client therefore costs the same on both sides.

- **Same answers first.** Before measuring, it checks that both servers
  answer each request with the same bytes, ignoring the `Server` and `Date`
  lines.
- **Concurrency.** A scenario runs `Clients` threads at once. Each request
  opens its own connection, sends, half-closes, reads to the end and resets.
  Concurrency stays at 4 or below because both servers listen with
  CPython's backlog of 5. Past that, macOS drops SYNs and the client waits a
  full one-second retransmission, which would measure the kernel instead.
- **Repetitions.** Each repetition runs every scenario on both servers,
  alternating which server goes first, after a warm-up.
- **Figures.** The tables give the median over 5 repetitions of throughput
  and of the per-request p50 and p99 latencies. The 1-minute load average
  was 2.47 to 4.30.

<!-- bench: superseded -->

| Scenario | Clients | Haskell req/s | Haskell p50 / p99 | Python req/s | Python p50 / p99 | Haskell / Python |
|---|---:|---:|---:|---:|---:|---:|
| snapshot | 1 | 11878 | 79 µs / 190 µs | 4912 | 197 µs / 268 µs | 2.42× |
| snapshot | 4 | 18633 | 213 µs / 395 µs | 5349 | 719 µs / 1.37 ms | 3.48× |
| document (201 records) | 1 | 128 | 7.94 ms / 10.38 ms | 42 | 23.24 ms / 30.31 ms | 3.04× |
| document (201 records) | 4 | 129 | 30.59 ms / 46.22 ms | 42 | 95.12 ms / 134.46 ms | 3.06× |
| history after=0 limit=100 | 1 | 2750 | 357 µs / 450 µs | 1712 | 576 µs / 811 µs | 1.61× |
| history after=0 limit=100 | 4 | 3701 | 1.04 ms / 2.34 ms | 1958 | 1.96 ms / 4.06 ms | 1.89× |
| refused POST (405) | 1 | 15431 | 59 µs / 127 µs | 8957 | 109 µs / 165 µs | 1.72× |

## Notes

- **Server placement.** The Haskell server runs inside the benchmark
  process, on one capability (`-threaded` without `-N`), so it shares that
  capability with the load client. The Python server runs in its own
  process under the GIL. Neither side gets parallel request handling, and
  the shared client costs the Haskell side, not the Python one.
- **The document does not scale with clients on either server.** Each
  request projects the whole History into a Net document, about 8 ms of CPU
  in Haskell at `146bfdd` (4.7 ms now) and 23 ms in Python, and neither server can overlap that work.
  Only the per-request cost differs.
- **History has the smallest lead.** Each page reads History from the
  in-memory store and re-encodes 100 canonical records, and much of that
  work is shared code: petrus-engine and petrus-observation. The HTTP layer
  itself, shown by the 405 row, is 1.7× to 3× faster.
