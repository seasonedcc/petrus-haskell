# petrus-history-postgres benchmarks

The Haskell side is `bench/Main.hs`. The Python twin is `bench/python_bench.py`, which runs the reference's `PostgresHistoryStore` with the same names, records, and statements. Both create a scratch database and drop it afterwards. Ratios above 1 mean Haskell is faster, and Haskell is faster on every row in both runs.

- Date: 2026-10-10 16:50–16:53 local (UTC-3), commit `e18b1c0` (the library code is unchanged since)
- Machine: Darwin arm64, Apple M4; shared with other agents. Load average 2.3–3.4 (1-minute) throughout; each line of `uptime` was taken before and after every run.
- Server: a private PostgreSQL 17.7 (Postgres.app binaries, `initdb` defaults, fsync on) on 127.0.0.1, TCP, trust auth; started for the runs and stopped afterwards
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean (`--stdev 5`, per-group `RelStDev 0.2`), run with `+RTS -M2G -RTS`
- Python: CPython 3.14.6, psycopg 3.3.4 (binary, bundled libpq 18), the pinned upstream venv; median of 10 timed batches (scripts/bench_timing.py)
- Interleaved: Haskell run 1, Python run 1, Haskell run 2, Python run 2 (for both packages, in that order)

| Benchmark | Haskell (run 1 / run 2) | Python (run 1 / run 2) | Python / Haskell (run 1 / run 2) |
|---|---:|---:|---:|
| `append.autocommit-1` | 23.4 µs / 34.7 µs | 89.6 µs / 99.3 µs | 3.83× / 2.86× |
| `append.autocommit-8` | 261 µs / 318 µs | 550 µs / 606 µs | 2.11× / 1.91× |
| `append.joined-1-commit` | 27.2 µs / 34.5 µs | 86.9 µs / 96.2 µs | 3.20× / 2.79× |
| `append.joined-8-commit` | 293 µs / 336 µs | 550 µs / 583 µs | 1.87× / 1.74× |
| `load.1k` | 1.96 ms / 2.25 ms | 5.75 ms / 6.02 ms | 2.93× / 2.68× |
| `load.10k` | 24 ms / 25.5 ms | 61.3 ms / 63.5 ms | 2.56× / 2.49× |
| `verify.conflict-acknowledge` | 29.1 µs / 50.3 µs | 105 µs / 103 µs | 3.60× / 2.04× |

What each row measures:

- **`append.*`** appends the non-terminal records of a drained FIFO's History: one per batch, or eight. On an autocommit connection, each batch is one owned transaction (`BEGIN`, one insert per record, `COMMIT`). Joined batches ride the caller's transaction, followed by `COMMIT`. Every insert is a server round trip in both implementations, so the 8-record rows are dominated by server work (jsonb parsing and five index updates per row). That is why their ratio is the lowest.
- **`load.*`** opens a store over 1 002 or 10 002 recorded rows: the load query, then each payload read as text, parsed with `json.loads` semantics, and decoded.
- **`verify.conflict-acknowledge`** is a stale writer appending a fact another writer already recorded value-equal at its position: the insert conflicts, the row is re-read, the payloads are compared with Python equality, and the fact is acknowledged.

## A note on the server

Run first against the Docker Desktop container the tests use, the Python rows came out 7× to 18× slower than Haskell (`append.autocommit-1`: 31.8 µs against 586 µs). That gap is the Docker port forward, not either implementation. Through it, one `SELECT 1` round trip costs about 170 µs for every blocking libpq client measured: `pgbench`, psycopg (with any of its wait functions, or a busy-polling loop), and petrus-postgres under GHCi's non-threaded runtime. Only the threaded GHC runtime saw about 8.5 µs. That figure belongs to the environment, so the committed figures come from a native server. There, `pgbench` and psycopg see 16–24 µs per round trip, and the ratios above reflect client-side work.

## Rerun

```sh
# any server where the role may create databases; a scratch database is created and dropped
export PETRUS_TEST_POSTGRES=postgresql://postgres@127.0.0.1:5432/postgres
scripts/bench petrus-history-postgres            # Haskell then Python, rewrites this file
# or by hand, interleaved:
cabal bench -j2 petrus-history-postgres --benchmark-options '--stdev 5 +RTS -M2G -RTS'
(cd upstream/petrus && .venv/bin/python ../../packages/petrus-history-postgres/bench/python_bench.py)
```
