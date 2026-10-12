# petrus-processes benchmarks

<!-- scripts/bench: measured sources 1f60376acea0ea7e at 0b9e2cbea2a7 -->

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names, values and store operations. Both are wall-clock time. Ratios above 1
mean Haskell is faster. Haskell is faster on every row: 1.51–2.23× on the
registry operations, which now run as prepared statements as psycopg's do,
and 2.8–15× on values and the Activity.

## Current figures

Measured on 2026-10-12, 02:41–02:44 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.58–2.87:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-processes 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The server was `scripts/with-postgres`'s throwaway PostgreSQL 17.7 on 127.0.0.1 over TCP (`initdb` defaults, `fsync` on). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `model.child-identity` | 628 ns | 1.75 µs | 2.79× | 2.75× | 635 ns, 628 ns, 618 ns | 1.75 µs, 1.75 µs, 1.78 µs |
| `model.spawn-spec-digest` | 2.56 µs | 15.3 µs | 5.99× | 5.98× | 2.56 µs, 2.5 µs, 2.56 µs | 15.3 µs, 15.3 µs, 15.4 µs |
| `model.spawn-spec-roundtrip` | 1.14 µs | 13.9 µs | 12.22× | 12.14× | 1.15 µs, 1.14 µs, 1.14 µs | 14 µs, 13.9 µs, 13.9 µs |
| `call.request-envelope` | 1.34 µs | 14.4 µs | 10.76× | 10.67× | 1.34 µs, 1.33 µs, 1.34 µs | 14.3 µs, 14.4 µs, 14.4 µs |
| `call.result-envelope` | 1.45 µs | 15.1 µs | 10.40× | 10.30× | 1.46 µs, 1.45 µs, 1.45 µs | 15.1 µs, 15.1 µs, 15.1 µs |
| `call.reply-from-envelope` | 760 ns | 11.6 µs | 15.27× | 15.23× | 759 ns, 760 ns, 761 ns | 11.6 µs, 11.6 µs, 11.6 µs |
| `call.roundtrip-postgres` | 603 µs | 949 µs | 1.58× | 1.54× | 591 µs, 614 µs, 603 µs | 978 µs, 946 µs, 949 µs |
| `spawn.activity` | 5.68 µs | 45.8 µs | 8.05× | 7.95× | 5.76 µs, 5.68 µs, 5.66 µs | 45.8 µs, 45.8 µs, 45.8 µs |
| `postgres.claim-prior` | 65.1 µs | 112 µs | 1.72× | 1.61× | 64.6 µs, 65.1 µs, 66 µs | 112 µs, 112 µs, 107 µs |
| `postgres.child-of` | 39.9 µs | 60.4 µs | 1.51× | 1.48× | 40 µs, 39.8 µs, 39.9 µs | 59 µs, 60.8 µs, 60.4 µs |
| `postgres.claim-new` | 79.8 µs | 132 µs | 1.65× | 1.65× | 79.8 µs, 79.8 µs, 76.1 µs | 132 µs, 132 µs, 129 µs |
| `postgres.spawn-activity` | 82 µs | 183 µs | 2.23× | 2.19× | 82 µs, 85.2 µs, 81.6 µs | 183 µs, 187 µs, 183 µs |

## Earlier figures

- Date: 2026-10-11 00:08–00:46 local (UTC-3), two runs of
  `scripts/bench-compare petrus-processes 6` (00:08–00:19 and 00:37–00:46), on the commit
  that adds petrus-postgres's prepared-statement cache
- Machine: Darwin arm64, Apple M4, heavily shared with other agents' builds and benchmarks;
  1-minute load average 4.9–8.7 around the runs
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time, `--stdev 5`, `+RTS -M2G -RTS`
- Python: CPython 3.14.6 (upstream venv), psycopg 3.3.4, median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- PostgreSQL 17.7, a throwaway server from `scripts/with-postgres` (Postgres.app binaries,
  `initdb` defaults) on 127.0.0.1, one per run; the store rows use a scratch database each
  repetition
- Interleaved: each run alternates Haskell first and Python first over six repetitions. The
  figures are the medians of all twelve repetitions; "lowest" is the worst single
  repetition's ratio, and the last column counts the repetitions Haskell won.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `model.child-identity` | 654 ns | 1.83 µs | 2.80× | 2.48× | 12/12 |
| `model.spawn-spec-digest` | 2.73 µs | 16.1 µs | 5.89× | 5.79× | 12/12 |
| `model.spawn-spec-roundtrip` | 1.3 µs | 14.8 µs | 11.38× | 9.97× | 12/12 |
| `call.request-envelope` | 1.47 µs | 15.5 µs | 10.58× | 10.30× | 12/12 |
| `call.result-envelope` | 1.61 µs | 16 µs | 9.92× | 8.46× | 12/12 |
| `call.reply-from-envelope` | 869 ns | 12.3 µs | 14.18× | 13.19× | 12/12 |
| `spawn.activity` | 6.19 µs | 48.9 µs | 7.90× | 7.36× | 12/12 |
| `postgres.claim-prior` | 93.7 µs | 176 µs | 1.88× | 1.05× | 12/12 |
| `postgres.child-of` | 60.4 µs | 90.4 µs | 1.50× | 0.81× | 11/12 |
| `postgres.claim-new` | 148 µs | 205 µs | 1.39× | 0.95× | 11/12 |
| `postgres.spawn-activity` | 155 µs | 286 µs | 1.85× | 0.93× | 11/12 |

The load moved every registry figure: Haskell's `postgres.child-of` ranged
from 45.6 µs to 126 µs over the twelve repetitions, Python's from 63.9 µs to
160 µs. The two runs agree: `postgres.child-of` came out at 1.64× and 1.47×
on their own medians. Each registry row lost at most one repetition out of
twelve, in the busiest stretches.

`postgres.child-of` is the fabric authentication `SELECT` and the indexed
lineage `SELECT`, two round trips. It used to come out level with Python
(0.97×, the superseded table below). Both clients send the same two
statements (checked with `log_statement = all`), but psycopg executes each by
name once it has run five times on the connection, sparing the server the
parse and plan, while petrus-postgres sent both unnamed every time.
petrus-postgres now keeps psycopg's prepared-statement cache (see its
[DIVERGENCES](../../petrus-postgres/DIVERGENCES.md) and the
[fabric results](../../petrus-fabric/bench/RESULTS.md)), and the two clients'
statement logs are identical, statement names included.

### The call round trip

`call.roundtrip-postgres` is one whole call over the PostgreSQL Fabric
(spec/processes.md §6). The caller and the callee each use their own
connection, and each step is the same on both sides:

1. The caller sends a fresh request envelope.
2. The callee drains it through a door that validates the request
   (`request_from_envelope`) and sends the correlated result envelope.
3. The caller drains the reply through a door that validates it against the
   request (`reply_from_envelope`).

Each drain authenticates, reads the pending delivery, and acknowledges it.

It was added after the table above, and timed on 2026-10-11 10:46–10:50
local, on the commit that adds it. The run was a separate interleaved
`scripts/bench-compare petrus-processes 6` restricted to this row (Haskell
first, then Python first, alternately). The 1-minute load average was 4.1–7.2:

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `call.roundtrip-postgres` | 901 µs | 1.63 ms | 1.81× | 1.08× | 6/6 |

The load moved both sides. Haskell's figure ranged from 674 µs to 1.58 ms over
the six repetitions, and Python's from 1.11 ms to 1.88 ms.

### Before the prepared-statement cache

<!-- bench: superseded -->
2026-10-10 21:06–21:08 local, commit `74e6b1e`, `scripts/bench-compare petrus-processes 2`,
load average 2.7–4.0:

| Benchmark | Haskell | Python | Python / Haskell (before) | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `model.child-identity` | 625 ns | 1.78 µs | 2.85× | 629 ns, 622 ns | 1.78 µs, 1.78 µs |
| `model.spawn-spec-digest` | 2.61 µs | 15.5 µs | 5.93× | 2.57 µs, 2.65 µs | 15.6 µs, 15.4 µs |
| `model.spawn-spec-roundtrip` | 1.24 µs | 14.1 µs | 11.40× | 1.28 µs, 1.2 µs | 14.1 µs, 14.1 µs |
| `call.request-envelope` | 1.37 µs | 14.6 µs | 10.67× | 1.38 µs, 1.35 µs | 14.6 µs, 14.5 µs |
| `call.result-envelope` | 1.51 µs | 15.3 µs | 10.15× | 1.52 µs, 1.49 µs | 15.2 µs, 15.4 µs |
| `call.reply-from-envelope` | 796 ns | 11.9 µs | 14.91× | 804 ns, 789 ns | 11.8 µs, 12 µs |
| `spawn.activity` | 5.83 µs | 46.5 µs | 7.98× | 5.83 µs, 5.82 µs | 45.8 µs, 47.1 µs |
| `postgres.claim-prior` | 92.4 µs | 111 µs | 1.21× | 90.3 µs, 94.5 µs | 111 µs, 112 µs |
| `postgres.child-of` | 59.7 µs | 58 µs | 0.97× | 58.9 µs, 60.6 µs | 60.9 µs, 55 µs |
| `postgres.claim-new` | 100 µs | 135 µs | 1.35× | 101 µs, 99.7 µs | 134 µs, 136 µs |
| `postgres.spawn-activity` | 113 µs | 187 µs | 1.65× | 119 µs, 107 µs | 187 µs, 186 µs |

The figures committed before those timed Haskell in tasty-bench's default CPU
time, against Python's wall-clock time. CPU time leaves out the wait for the
server, so the store rows read 3.0–5.5× faster than Python
(`postgres.child-of` 17.5–19.7 µs).

## Notes

- The `postgres` rows run at 20% relative precision (`RelStDev 0.2`, as
  the other PostgreSQL benchmarks in this repository do). At 5% the
  inserting rows did not converge within 300 s on a loaded machine. Each
  row is a round trip to the server, and `claim-new` and `spawn-activity`
  grow the table they read.

## Rerun

From the repository root (`scripts/bench petrus-processes` runs exactly this block). The store
rows need a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is
unset, `scripts/bench` and `scripts/bench-compare` start a throwaway one with
`scripts/with-postgres`.

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-processes --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-processes/bench/python_bench.py)
```

`scripts/bench-compare petrus-processes 6` interleaves both sides over six repetitions and prints a
table like the one above; the table pools two such runs.
