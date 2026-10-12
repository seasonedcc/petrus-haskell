# petrus-postgres benchmarks

<!-- scripts/bench: measured sources ddd3613f65322093 at 14f6d69e9572 -->

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names and values. Both are wall-clock time. Ratios above 1 mean Haskell is
faster. Haskell is faster on every row, by 1.22× (`tx.join-insert-commit`, an
insert and a commit that are almost all server time) to 2.0× on the
client-side work, and 14× on placeholder conversion, which never leaves the
process. Statements now run prepared from their sixth execution, as psycopg's
do (see below).

## Current figures

Measured on 2026-10-12, 02:40–02:41 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.66–2.79:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-postgres 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The server was `scripts/with-postgres`'s throwaway PostgreSQL 17.7 on 127.0.0.1 over TCP (`initdb` defaults, `fsync` on). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

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

## Earlier figures

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
`scripts/bench-compare petrus-postgres 6` interleaves the two sides over six repetitions and prints the table above).
It needs a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that
is unset, both scripts start a throwaway one with `scripts/with-postgres`.

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-postgres --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-postgres/bench/python_bench.py)
```
