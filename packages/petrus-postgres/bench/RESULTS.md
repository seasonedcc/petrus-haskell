# petrus-postgres benchmarks

<!-- scripts/bench: measured sources 86fcaeac67519f3e at 16e39fa0735a -->

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures come from `bench/Main.hs`, which uses the same names and
values. Both are wall-clock time. Ratios above 1 mean Haskell is faster.
Haskell is faster on every row, by 1.20× (`tx.join-insert-commit`, an insert
and a commit that are almost all server time) to 2.0× on the client-side
work, and 13× on placeholder conversion, which never leaves the process.
Statements run prepared from their sixth execution, as psycopg's do (see
below).

The `tx`, `fence` and `notify` rows are timed with the twin's own protocol
on both sides (`Petrus.TestSupport.BenchTwin` against
`scripts/bench_timing.py`'s `report(..., number=N)`): one warm-up call, then
10 batches of exactly the same number of calls (3000 commits, 600 owned
transactions, 4000 fences, 7000 notifications), the median batch's time per
call. Commits grow the event table with every call and the other two are
mostly server time; as tasty-bench means, which run as many calls as the
noise demands, they swung with the machine (`tx.join-insert-commit` read
0.83× in one CI run and 1.28× in another). The other rows are tasty-bench
means.

## Current figures

Measured on 2026-10-12, 12:39–12:42 local (UTC-3), on the commit that times
the `tx`, `fence` and `notify` rows with the twin's protocol, on the Apple
M4 (Darwin arm64) with a 1-minute load average of 3.66–8.37 (other agents
were building): five interleaved repetitions, alternating which side goes
first, of

    scripts/bench-compare petrus-postgres 5

Haskell figures are the twin-protocol medians above for `tx`, `fence` and
`notify`, and tasty-bench means in wall-clock time (`--stdev 5`) for the
others, the benchmark executable run directly in the package directory with
`+RTS -M2G`; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The server was
`scripts/with-postgres`'s throwaway PostgreSQL 17.7 on 127.0.0.1 over TCP
(`initdb` defaults, `fsync` on). Haskell won every repetition of the `tx`
rows and 4 of 5 of `fence` and `notify`; the two it lost were both in the
first repetition, which Haskell ran first against the freshly started
server, and in which its `fence` and `notify` rows took 1.6–2× their time
in the other four. The tables
in the sections below are earlier measurements, kept with the analysis that
came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `tx.join-insert-commit` | 54.3 µs | 65 µs | 1.20× | 1.13× | 57.4 µs, 54.3 µs, 55.9 µs, 51.1 µs, 53.2 µs | 65 µs, 71.5 µs, 68.7 µs, 64.9 µs, 64.9 µs |
| `tx.owned-insert-10` | 256 µs | 333 µs | 1.30× | 1.12× | 256 µs, 265 µs, 238 µs, 245 µs, 280 µs | 368 µs, 333 µs, 356 µs, 307 µs, 315 µs |
| `fence.acquire-release` | 34.9 µs | 50.9 µs | 1.46× | 0.91× | 55.7 µs, 38.5 µs, 34.9 µs, 34.1 µs, 34.3 µs | 50.9 µs, 61.1 µs, 53.9 µs, 48.2 µs, 48.3 µs |
| `notify.roundtrip` | 26.6 µs | 34.9 µs | 1.31× | 0.61× | 50.8 µs, 26.9 µs, 19.9 µs, 24.3 µs, 26.6 µs | 31.2 µs, 39.6 µs, 28.3 µs, 35.7 µs, 34.9 µs |
| `roundtrip.select-1` | 18.5 µs | 24.5 µs | 1.33× | 1.24× | 17.6 µs, 18.5 µs, 18.7 µs, 17.5 µs, 19 µs | 24.5 µs, 22.9 µs, 23.4 µs, 25.7 µs, 30.6 µs |
| `roundtrip.select-param` | 17.8 µs | 25.1 µs | 1.41× | 0.97× | 17.5 µs, 19.3 µs, 22.2 µs, 17.8 µs, 17.7 µs | 25.1 µs, 24.7 µs, 21.6 µs, 26.9 µs, 29 µs |
| `query.select-1000-decoded` | 679 µs | 1.38 ms | 2.03× | 1.38× | 664 µs, 704 µs, 1 ms, 679 µs, 651 µs | 1.37 ms, 1.38 ms, 1.38 ms, 1.39 ms, 1.43 ms |
| `params.convert-placeholders` | 303 ns | 4.05 µs | 13.36× | 12.71× | 296 ns, 303 ns, 289 ns, 315 ns, 333 ns | 4.02 µs, 4.05 µs, 3.99 µs, 4.09 µs, 4.23 µs |

## The socket wait and the result accessors, measured (2026-10-12)

Two low-level choices were measured against the plain alternatives, three
builds of this benchmark run interleaved over five repetitions (rotating
which goes first) against one `scripts/with-postgres` server, on the
Apple M4 at a load average of 5.9–9.0. Medians of the tasty-bench means:

| Row | As built | IO manager wait | postgresql-libpq accessors | Python (`81bbdc5`, below) |
|---|---:|---:|---:|---:|
| `roundtrip.select-1` | 17.6 µs | 20.2 µs | 19.0 µs | 25.2 µs |
| `roundtrip.select-param` | 17.7 µs | 20.9 µs | 18.8 µs | 26.4 µs |
| `query.select-1000-decoded` | 672 µs | 698 µs | 14.09 ms | 1.34 ms |
| `tx.join-insert-commit` | 56.4 µs | 68.3 µs | 59.7 µs | 69.6 µs |
| `tx.owned-insert-10` | 276 µs | 325 µs | 285 µs | 359 µs |
| `fence.acquire-release` | 35.3 µs | 46.2 µs | 41.7 µs | 53.8 µs |
| `notify.roundtrip` | 20.8 µs | 45.2 µs | 22.0 µs | 28.6 µs |

- **The wait** is petrus-posix's `waitReadable`, a `poll` on the calling OS
  thread, as psycopg waits. Parking on GHC's IO manager instead
  (`threadWaitRead`) costs an event round trip per wake-up: 15–31% on
  every row that talks to the server, and twice the time on
  `notify.roundtrip`, which put that row behind the reference (0.63×) and
  the gated `tx.join-insert-commit` level with it (1.02×).
- **The result accessors** are direct `unsafe` imports of libpq's
  read-only accessors (`PQgetvalue`, `PQgetisnull`, …).
  postgresql-libpq's own are safe calls on a `ForeignPtr`, three per value:
  the 1 000-row decode took 14.09 ms with them, a tenth of the reference's
  speed.

Both stay, with these figures beside them in the code.

## Earlier figures

Measured on 2026-10-12, 02:40–02:41 local (UTC-3), at commit `81bbdc5`,
load average 2.66–2.79, by `scripts/bench-compare petrus-postgres 3`, with
every Haskell row a tasty-bench mean:

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `roundtrip.select-1` | 17.6 µs | 25.2 µs | 1.43× | 1.42× | 17.8 µs, 17.6 µs, 17.6 µs | 25.5 µs, 25.2 µs, 25.1 µs |
| `roundtrip.select-param` | 17.5 µs | 26.4 µs | 1.51× | 1.50× | 17.5 µs, 17.6 µs, 17.4 µs | 26.7 µs, 26.4 µs, 26.1 µs |
| `query.select-1000-decoded` | 660 µs | 1.34 ms | 2.03× | 2.03× | 664 µs, 660 µs, 659 µs | 1.36 ms, 1.34 ms, 1.34 ms |
| `tx.join-insert-commit` | 56.9 µs | 69.6 µs | 1.22× | 1.22× | 58.4 µs, 55.3 µs, 56.9 µs | 71 µs, 69.2 µs, 69.6 µs |
| `tx.owned-insert-10` | 272 µs | 359 µs | 1.32× | 1.31× | 271 µs, 274 µs, 272 µs | 364 µs, 359 µs, 358 µs |
| `fence.acquire-release` | 35.5 µs | 53.8 µs | 1.52× | 1.50× | 35.9 µs, 35.5 µs, 35.1 µs | 54.1 µs, 53.1 µs, 53.8 µs |
| `notify.roundtrip` | 19.6 µs | 28.6 µs | 1.46× | 1.40× | 20.5 µs, 19.6 µs, 19.5 µs | 28.8 µs, 28.6 µs, 28.2 µs |
| `params.convert-placeholders` | 271 ns | 3.89 µs | 14.36× | 14.24× | 270 ns, 271 ns, 273 ns | 3.89 µs, 3.89 µs, 3.89 µs |

Before that:

- Date: 2026-10-11 01:02–01:05 local (UTC-3), on the commit that adds the
  prepared-statement cache
- Machine: Darwin arm64, Apple M4, shared with other agents; 1-minute load average 3.65–5.40
  around the run
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time, `--stdev 5`, `+RTS -M2G -RTS`
- Python: CPython 3.14.6 (upstream venv), psycopg 3.3.4, median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- PostgreSQL 17.7, a throwaway server from `scripts/with-postgres` (Postgres.app binaries,
  `initdb` defaults) on 127.0.0.1
- Interleaved by `scripts/bench-compare petrus-postgres 6`, alternating Haskell first and
  Python first. The figures are the medians of the six repetitions; "lowest" is the worst
  single repetition's ratio, and the last column counts the repetitions Haskell won.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `roundtrip.select-1` | 17.4 µs | 25.3 µs | 1.45× | 1.40× | 6/6 |
| `roundtrip.select-param` | 18 µs | 26.4 µs | 1.47× | 1.37× | 6/6 |
| `query.select-1000-decoded` | 660 µs | 1.41 ms | 2.13× | 2.05× | 6/6 |
| `tx.join-insert-commit` | 58.7 µs | 69.7 µs | 1.19× | 1.09× | 6/6 |
| `tx.owned-insert-10` | 275 µs | 342 µs | 1.24× | 0.83× | 5/6 |
| `fence.acquire-release` | 36.6 µs | 50.2 µs | 1.37× | 0.78× | 5/6 |
| `notify.roundtrip` | 21 µs | 33.5 µs | 1.59× | 0.86× | 5/6 |
| `params.convert-placeholders` | 280 ns | 4.12 µs | 14.70× | 14.45× | 6/6 |

The three repetitions Haskell lost were all the fifth, a load spike that
slowed Haskell's `tx.owned-insert-10` from 275 µs to 399 µs, its
`fence.acquire-release` from 36 µs to 54 µs and its `notify.roundtrip` from
21 µs to 42 µs within one run.

### The prepared-statement cache

psycopg prepares a statement on the server once a connection has run it five
times (`prepare_threshold = 5`), keeps up to 100 of them (`prepared_max`),
names them `_pg3_0`, `_pg3_1`, … and runs them by name from then on, which
spares the server the parse and plan. petrus-postgres used to send every
statement unnamed, so the server parsed and planned it on every call; that
was the whole difference in the statement logs of the two clients, and why
the Fabric and Processes store rows trailed Python. `Petrus.Postgres` now
keeps the same cache: same threshold and size, same statement names, keyed on
the statement text and parameter types, evicting the least recently used
statement, and discarding all of them on `ROLLBACK` and after `DROP …`, as
psycopg does. Statement logs (`log_statement = all`) of the two clients are
now identical line for line, statement names included, and a test compares
`pg_prepared_statements` after the same sequence on both. The cache costs one
extra round trip (the `Parse`) at the sixth execution of each statement, as
psycopg's does. `ConnectOptions` exposes the threshold (`Nothing` turns
preparing off) and the size.

Against the table below, the parameterised round trip went from 23.6 µs to
18 µs, the joined insert from 68.3 µs to 58.7 µs and the owned ten inserts
from 362 µs to 275 µs. `SELECT 1` gains little from a plan cache; a
same-process A/B (15 alternating batches of 2 000 queries each, on one
server) measured it at 17.60 µs prepared against 17.97 µs unprepared, and
`SELECT $1::int8 + 1` at 16.67 µs against 20.15 µs.

### Before the prepared-statement cache

<!-- bench: superseded -->

2026-10-10 21:08–21:09 local, commit `74e6b1e`, `scripts/bench-compare petrus-postgres 2`,
load average 2.5–4.2:

| Benchmark | Haskell | Python | Python / Haskell (before) | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `roundtrip.select-1` | 18.7 µs | 25.7 µs | 1.37× | 18.9 µs, 18.6 µs | 25.7 µs, 25.8 µs |
| `roundtrip.select-param` | 23.6 µs | 26.9 µs | 1.14× | 23 µs, 24.2 µs | 27 µs, 26.9 µs |
| `query.select-1000-decoded` | 721 µs | 1.44 ms | 2.00× | 721 µs, 721 µs | 1.43 ms, 1.45 ms |
| `tx.join-insert-commit` | 68.3 µs | 77.4 µs | 1.13× | 69.2 µs, 67.4 µs | 74 µs, 80.8 µs |
| `tx.owned-insert-10` | 362 µs | 364 µs | 1.01× | 358 µs, 366 µs | 365 µs, 363 µs |
| `fence.acquire-release` | 45.1 µs | 54 µs | 1.20× | 45.3 µs, 44.9 µs | 54 µs, 53.9 µs |
| `notify.roundtrip` | 24.8 µs | 29.8 µs | 1.21× | 26 µs, 23.5 µs | 29.9 µs, 29.7 µs |
| `params.convert-placeholders` | 276 ns | 3.99 µs | 14.43× | 277 ns, 275 ns | 3.99 µs, 3.98 µs |

The figures committed before those came from the old `scripts/bench`, which timed Haskell
in tasty-bench's default CPU time against Python's wall-clock time. CPU time
leaves out the wait for the server, so every row that talks to it read
2.7–5.3× faster than Python (`roundtrip.select-1` 9.8 µs, `tx.owned-insert-10`
121 µs). Measured the same way as Python, the round trips are 1.1–1.4× faster
and the owned ten-insert transaction was level with Python.

## What each row measures

Session-local temporary tables only:

- **`roundtrip.*`**: `SELECT 1`, and `SELECT $1::int8 + 1` with one parameter,
  on an autocommit connection, fetching the result.
- **`query.select-1000-decoded`**: a 1 000-row result (`int`, `text`, `jsonb`),
  every column decoded.
- **`tx.join-insert-commit`**: one History-event insert in the caller's
  transaction, then `COMMIT`.
- **`tx.owned-insert-10`**: ten such inserts in one owned transaction.
- **`fence.acquire-release`**: the authority fence (`PostgresAuthorityFence`)
  taken and released.
- **`notify.roundtrip`**: `pg_notify` on one connection, received on a
  listening one.
- **`params.convert-placeholders`**: the insert's `%s` placeholders converted
  to `$n`, in memory.

## Rerun

From the repository root (`scripts/bench petrus-postgres` runs exactly this block, once;
`scripts/bench-compare petrus-postgres 5` interleaves the two sides over five repetitions and prints the table above).
It needs a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that
is unset, both scripts start a throwaway one with `scripts/with-postgres`.

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-postgres --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-postgres/bench/python_bench.py)
```
