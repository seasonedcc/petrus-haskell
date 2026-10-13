# petrus-observation-http benchmarks

<!-- scripts/bench: measured sources f61bda8c028ae2e0 at 2cf4687e4eac -->
<!-- scripts/bench: carried to 61bc61db8063f37e at c33829edc562: in-package changes are tests and docs only; the upstream library changes (json refusal path, posix additions, SQLite bind guard) are off the measured snapshot and HTTP paths -->
<!-- scripts/bench: carried to f292a1d32ad7bdb8 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: petrus-history-store's floatEqualsInteger calls pyNumberEq, the same exact test, reached only for a REAL position or a float occurrence, which the store never writes; petrus-impetus's literalInt float branch and petrus-motus's local-dispatch sqlite3 int-against-float == call pyNumberEq, the same exact test they spelled out; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->

This compares the Haskell observation server with the upstream
`petrus.engine.observation_http` at the pin in [UPSTREAM.md](../../../UPSTREAM.md).
Both serve the same Engine: the upstream test's Net with its move looping
back to `a`, advanced 100 times, which gives 201 History records
(`busyEngine` in `bench/Main.hs`, `make_busy_engine` in
`test/reference_observation.py`). Ratios above 1 mean Haskell is faster.
Haskell is faster on every row.

## Current figures

Measured on 2026-10-12, 20:53–20:54 local (UTC-3), at commit `ca1eca7`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.23–2.77:
five interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-observation-http 5

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `roundtrip.snapshot` | 60 µs | 212 µs | 3.53× | 3.13× | 5 of 5 | 67.3 µs, 57.7 µs, 64.6 µs, 58.5 µs, 60 µs | 211 µs, 212 µs, 211 µs, 213 µs, 215 µs |
| `roundtrip.document` | 3.83 ms | 22.6 ms | 5.91× | 5.76× | 5 of 5 | 3.94 ms, 3.82 ms, 3.83 ms, 3.84 ms, 3.79 ms | 22.7 ms, 22.8 ms, 22.6 ms, 22.6 ms, 22.6 ms |
| `roundtrip.history-100` | 129 µs | 568 µs | 4.41× | 4.29× | 5 of 5 | 129 µs, 127 µs, 131 µs, 128 µs, 130 µs | 564 µs, 569 µs, 564 µs, 569 µs, 568 µs |
| `roundtrip.refused-405` | 50.8 µs | 124 µs | 2.44× | 2.43× | 5 of 5 | 51 µs, 50.8 µs, 50.3 µs, 50.8 µs, 51.1 µs | 124 µs, 124 µs, 124 µs, 124 µs, 124 µs |

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
  and of the per-request p50 and p99 latencies. Measured on 2026-10-12,
  20:54–21:01 local (UTC-3), at commit `2cf4687`, with the 1-minute load
  average at 2.01 to 4.58, by
  `scripts/bench-run petrus-observation-http load 5 +RTS -M2G -RTS`. The
  run at `a99bed8` (19:01–19:08, load 2.10 to 3.20) read 1.95–5.91×, the
  one at `81bbdc5` (04:03–04:10, load 2.26 to 2.80) 1.86–5.38×; an
  earlier one (load 2.47 to 4.30) had Haskell ahead 1.61–3.48×.

| Scenario | Clients | Haskell req/s | Haskell p50 / p99 | Python req/s | Python p50 / p99 | Haskell / Python |
|---|---:|---:|---:|---:|---:|---:|
| snapshot | 1 | 15770 | 61 µs / 93 µs | 5097 | 195 µs / 219 µs | 3.09× |
| snapshot | 4 | 20950 | 188 µs / 242 µs | 5429 | 704 µs / 1.41 ms | 3.86× |
| document (201 records) | 1 | 258 | 3.64 ms / 5.14 ms | 44 | 22.21 ms / 28.03 ms | 5.82× |
| document (201 records) | 4 | 264 | 15.17 ms / 20.08 ms | 44 | 89.34 ms / 137.50 ms | 5.96× |
| history after=0 limit=100 | 1 | 7680 | 128 µs / 187 µs | 1919 | 507 µs / 587 µs | 4.00× |
| history after=0 limit=100 | 4 | 8969 | 432 µs / 589 µs | 2051 | 1.89 ms / 3.40 ms | 4.37× |
| refused POST (405) | 1 | 17917 | 54 µs / 91 µs | 8959 | 110 µs / 128 µs | 2.00× |

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
