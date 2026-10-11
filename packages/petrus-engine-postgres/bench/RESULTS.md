# petrus-engine-postgres benchmarks

The Haskell side is `bench/Main.hs`. The Python twin is `bench/python_bench.py`, which runs the reference's `petrus.engine.postgres` doors with the same names, net, and workloads. Both create a scratch database and drop it afterwards. Ratios above 1 mean Haskell is faster, and Haskell is faster on every row in every repetition. Statements now run prepared from their sixth execution, as psycopg's do (petrus-postgres's prepared-statement cache).

- Date: 2026-10-11 01:34–01:35 local (UTC-3), on the commit that adds petrus-postgres's prepared-statement cache
- Machine: Darwin arm64, Apple M4; shared with other agents. Load average 4.3–5.6 (1-minute) around the run.
- Server: a throwaway PostgreSQL 17.7 from `scripts/with-postgres` (Postgres.app binaries, `initdb` defaults, fsync on) on 127.0.0.1, TCP, trust auth; started for the runs and removed afterwards
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean in **wall-clock time** (`--stdev 5`, per-group `RelStDev 0.2`), run with `+RTS -M2G -RTS`
- Python: CPython 3.14.6, psycopg 3.3.4 (binary, bundled libpq 18), the pinned upstream venv; median of 10 timed batches of 0.2 s (scripts/bench_timing.py)
- Interleaved by `scripts/bench-compare petrus-engine-postgres 6`, alternating Haskell first and Python first. The figures are the medians of the six repetitions; "lowest" is the worst single repetition's ratio, and the last column counts the repetitions Haskell won.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `engine.deliver` | 371 µs | 807 µs | 2.18× | 1.39× | 6/6 |
| `engine.redeliver-prior` | 1.26 µs | 9.28 µs | 7.34× | 6.87× | 6/6 |
| `engine.create-close` | 1.95 ms | 2.37 ms | 1.21× | 1.07× | 6/6 |

The load was higher than for the superseded table below, and `engine.deliver` moved with it on both sides: Haskell's ranged from 264 µs to 570 µs over the six repetitions, Python's from 451 µs to 924 µs.

What each row measures:

- **`engine.deliver`** is one identified delivery through the joined transaction. The accept step writes the delivery and begin facts, then commits. The complete step writes the production and completion facts, then commits. Every 256 deliveries, both sides close the Engine and create a fresh one on a fresh connection, so the in-memory History stays bounded. That cost is amortized into the figure on both sides alike.
- **`engine.redeliver-prior`** is an exact redelivery of a completed identity. It is answered from memory and commits nothing.
- **`engine.create-close`** connects, takes the fence, loads the absent History, creates the Instance and commits, then closes (unlock, rollback, close). Connecting and closing dominate it on both sides: psycopg's connect plus close alone measured 1.06 ms on this kind of server.

### Before the prepared-statement cache

<!-- bench: superseded -->

2026-10-10 21:00–21:01 local, commit `74e6b1e`, `scripts/bench-compare petrus-engine-postgres 2`, load average 3.0–3.7:

| Benchmark | Haskell | Python | Python / Haskell (before) | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `engine.deliver` | 249 µs | 405 µs | 1.63× | 239 µs, 258 µs | 403 µs, 407 µs |
| `engine.redeliver-prior` | 1.13 µs | 8.94 µs | 7.93× | 1.16 µs, 1.1 µs | 8.94 µs, 8.94 µs |
| `engine.create-close` | 2.03 ms | 2.23 ms | 1.10× | 2.01 ms, 2.05 ms | 2.23 ms, 2.24 ms |

## Wall-clock time, and the earlier figures

The figures committed before the superseded table were tasty-bench's default CPU time, against Python's wall-clock time. CPU time leaves out the time the client waits for the server, which is most of every row here, so it flattered Haskell by 3–12× on the rows that talk to the server (`engine.create-close` read 166–181 µs against a wall-clock 2.03 ms). `engine.redeliver-prior`, which never leaves memory, read 2.2–2.4 µs in CPU time and 1.1 µs in wall-clock time: the threaded runtime's CPU time adds up every OS thread of the process. Measured the same way as Python, Haskell was still faster on every row, by 1.1× (`engine.create-close`, dominated by connecting and the fence) to 1.6× (`engine.deliver`), and 7.9× on the in-memory redelivery.

## A note on the server

Run against the Docker Desktop container the tests used, the Python rows came out several times slower than on a native server: through Docker's port forward one `SELECT 1` round trip costs about 170 µs for every blocking libpq client measured (`pgbench`, psycopg). The Haskell figure then looked unaffected, at about 8.5 µs, but that was CPU time, which leaves out the wait; it was not a faster round trip. The committed figures come from a native server, where `pgbench` and psycopg see 16–24 µs per round trip.

## Rerun

From the repository root (`scripts/bench petrus-engine-postgres` runs exactly this block). It needs a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is unset, `scripts/bench` and `scripts/bench-compare` start a throwaway one with `scripts/with-postgres`. A scratch database is created and dropped on each side.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-engine-postgres --benchmark-options '--stdev 5 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-engine-postgres/bench/python_bench.py)
```

`scripts/bench-compare petrus-engine-postgres 6` interleaves both sides over six repetitions and prints the table above.
