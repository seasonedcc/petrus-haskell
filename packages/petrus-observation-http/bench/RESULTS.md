# petrus-observation-http benchmarks

This compares the Haskell observation server with the upstream
`petrus.engine.observation_http` at the pin in [UPSTREAM.md](../../../UPSTREAM.md).
Both serve the same Engine: the upstream test's Net with its move looping
back to `a`, advanced 100 times, which gives 201 History records
(`busyEngine` in `bench/Main.hs`, `make_busy_engine` in
`test/reference_observation.py`). Ratios above 1 mean Haskell is faster.
Haskell is faster on every row.

- Date: 2026-10-10. Commit: `146bfdd`.
- Machine: Darwin arm64, Apple M4 (10 cores, 24 GB). Other work was running
  on the machine, so the 1-minute load averages for each table are given
  with it.
- Haskell: GHC 9.10.3 at `-O2`, `-threaded`, run with `+RTS -M2G`.
- Python: CPython 3.14.6 from the upstream venv.

## How to rerun

From the repository root, with `~/.ghcup/bin` on `PATH`:

```bash
# Round trips: alternates cabal bench and bench/python_bench.py, 3 repetitions
python3 packages/petrus-observation-http/bench/interleave.py 3
# Load: one Haskell client drives both servers, 5 interleaved repetitions
cabal bench petrus-observation-http -j2 --benchmark-options "load 5 +RTS -M2G -RTS"
```

`scripts/bench petrus-observation-http` runs the round-trip rows once (not
interleaved) and replaces this file with its plain table.

## Round trips

Each iteration makes one request on a fresh loopback connection and reads
the response to the end. The connection is closed with a reset
(`SO_LINGER` 0), so `TIME_WAIT` sockets do not pile up. Each language uses
its own client:

- Haskell: `network` in tasty-bench, giving the mean;
- Python: `socket`, through `scripts/bench_timing.py`, giving the median of
  timed batches.

The requests are:

- `GET /v1/snapshot`;
- `GET /v1/document`, the Net document with 201 records;
- `GET /v1/history?after=0&limit=100`;
- `POST /v1/snapshot`, which is refused with 405.

The table gives the median over three interleaved repetitions. The
1-minute load average was 2.98 to 4.31.

| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `roundtrip.snapshot` | 61.2 µs | 227 µs | 3.71× | 61.2 µs, 58.5 µs, 62.7 µs | 227 µs, 232 µs, 221 µs |
| `roundtrip.document` | 8.03 ms | 23.9 ms | 2.98× | 7.88 ms, 8.03 ms, 8.22 ms | 23.9 ms, 24.1 ms, 23.5 ms |
| `roundtrip.history-100` | 314 µs | 597 µs | 1.90× | 314 µs, 380 µs, 296 µs | 602 µs, 597 µs, 590 µs |
| `roundtrip.refused-405` | 44.4 µs | 134 µs | 3.01× | 41.7 µs, 59.9 µs, 44.4 µs | 134 µs, 143 µs, 123 µs |

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
  in Haskell and 23 ms in Python, and neither server can overlap that work.
  Only the per-request cost differs.
- **History has the smallest lead.** Each page reads History from the
  in-memory store and re-encodes 100 canonical records, and much of that
  work is shared code: petrus-engine and petrus-observation. The HTTP layer
  itself, shown by the 405 row, is 1.7× to 3× faster.
