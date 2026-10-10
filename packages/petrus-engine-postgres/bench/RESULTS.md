# petrus-engine-postgres benchmarks

The Haskell side is `bench/Main.hs`. The Python twin is `bench/python_bench.py`, which runs the reference's `petrus.engine.postgres` doors with the same names, net, and workloads. Both create a scratch database and drop it afterwards. Ratios above 1 mean Haskell is faster, and Haskell is faster on every row in both runs.

- Date: 2026-10-10 16:50–16:53 local (UTC-3), commit `e18b1c0` (the library code is unchanged since)
- Machine: Darwin arm64, Apple M4; shared with other agents. Load average 2.3–3.4 (1-minute) throughout; each line of `uptime` was taken before and after every run.
- Server: a private PostgreSQL 17.7 (Postgres.app binaries, `initdb` defaults, fsync on) on 127.0.0.1, TCP, trust auth; started for the runs and stopped afterwards
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean (`--stdev 5`, per-group `RelStDev 0.2`), run with `+RTS -M2G -RTS`
- Python: CPython 3.14.6, psycopg 3.3.4 (binary, bundled libpq 18), the pinned upstream venv; median of 10 timed batches (scripts/bench_timing.py)
- Interleaved: Haskell run 1, Python run 1, Haskell run 2, Python run 2 (for both packages, in that order)

| Benchmark | Haskell (run 1 / run 2) | Python (run 1 / run 2) | Python / Haskell (run 1 / run 2) |
|---|---:|---:|---:|
| `engine.deliver` | 76.9 µs / 74.3 µs | 422 µs / 434 µs | 5.49× / 5.84× |
| `engine.redeliver-prior` | 2.24 µs / 2.42 µs | 9.12 µs / 9.09 µs | 4.08× / 3.76× |
| `engine.create-close` | 166 µs / 181 µs | 2.24 ms / 2.47 ms | 13.55× / 13.65× |

What each row measures:

- **`engine.deliver`** is one identified delivery through the joined transaction. The accept step writes the delivery and begin facts, then commits. The complete step writes the production and completion facts, then commits. Every 256 deliveries, both sides close the Engine and create a fresh one on a fresh connection, so the in-memory History stays bounded. That cost is amortized into the figure on both sides alike.
- **`engine.redeliver-prior`** is an exact redelivery of a completed identity. It is answered from memory and commits nothing.
- **`engine.create-close`** connects, takes the fence, loads the absent History, creates the Instance and commits, then closes (unlock, rollback, close). psycopg's connect plus close alone measured 1.06 ms on this server, about half of the Python figure.

## A note on the server

Run first against the Docker Desktop container the tests use, the Python rows came out 7× to 18× slower than Haskell (`append.autocommit-1`: 31.8 µs against 586 µs). That gap is the Docker port forward, not either implementation. Through it, one `SELECT 1` round trip costs about 170 µs for every blocking libpq client measured: `pgbench`, psycopg (with any of its wait functions, or a busy-polling loop), and petrus-postgres under GHCi's non-threaded runtime. Only the threaded GHC runtime saw about 8.5 µs. That figure belongs to the environment, so the committed figures come from a native server. There, `pgbench` and psycopg see 16–24 µs per round trip, and the ratios above reflect client-side work.

## Rerun

```sh
# any server where the role may create databases; a scratch database is created and dropped
export PETRUS_TEST_POSTGRES=postgresql://postgres@127.0.0.1:5432/postgres
scripts/bench petrus-engine-postgres            # Haskell then Python, rewrites this file
# or by hand, interleaved:
cabal bench -j2 petrus-engine-postgres --benchmark-options '--stdev 5 +RTS -M2G -RTS'
(cd upstream/petrus && .venv/bin/python ../../packages/petrus-engine-postgres/bench/python_bench.py)
```
