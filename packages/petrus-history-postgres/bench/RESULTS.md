# petrus-history-postgres benchmarks

The Haskell side is `bench/Main.hs`. The Python twin is `bench/python_bench.py`, which runs the reference's `PostgresHistoryStore` with the same names, records, and statements. Both create a scratch database and drop it afterwards. Ratios above 1 mean Haskell is faster. Haskell is faster on every row; the rows that write eight records per batch are server-bound and within 5–8% of Python.

- Date: 2026-10-10 20:59–21:01 local (UTC-3), commit `74e6b1e` with the switch to wall-clock time in `bench/Main.hs` (the library code is unchanged)
- Machine: Darwin arm64, Apple M4; shared with other agents. Load average 3.6–5.2 (1-minute) around the runs.
- Server: a throwaway PostgreSQL 17.7 from `scripts/with-postgres` (Postgres.app binaries, `initdb` defaults, fsync on) on 127.0.0.1, TCP, trust auth; started for the runs and removed afterwards
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean in **wall-clock time** (`--stdev 5`, per-group `RelStDev 0.2`), run with `+RTS -M2G -RTS`
- Python: CPython 3.14.6, psycopg 3.3.4 (binary, bundled libpq 18), the pinned upstream venv; median of 10 timed batches of 0.2 s (scripts/bench_timing.py)
- Interleaved by `scripts/bench-compare petrus-history-postgres 2`: Haskell, Python, then Python, Haskell. The figures are the medians of the two repetitions; the last two columns give each repetition.

| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---|---|
| `append.autocommit-1` | 77.4 µs | 88 µs | 1.14× | 74.4 µs, 80.4 µs | 89.5 µs, 86.6 µs |
| `append.autocommit-8` | 493 µs | 519 µs | 1.05× | 454 µs, 533 µs | 522 µs, 515 µs |
| `append.joined-1-commit` | 78.9 µs | 85.4 µs | 1.08× | 77.3 µs, 80.6 µs | 84.8 µs, 86 µs |
| `append.joined-8-commit` | 494 µs | 534 µs | 1.08× | 476 µs, 512 µs | 517 µs, 551 µs |
| `load.1k` | 2.35 ms | 5.89 ms | 2.51× | 2.35 ms, 2.35 ms | 5.93 ms, 5.85 ms |
| `load.10k` | 26.7 ms | 63.2 ms | 2.37× | 26.6 ms, 26.7 ms | 63.1 ms, 63.2 ms |
| `verify.conflict-acknowledge` | 81.9 µs | 92.9 µs | 1.13× | 82.2 µs, 81.6 µs | 93.8 µs, 92 µs |

What each row measures:

- **`append.*`** appends the non-terminal records of a drained FIFO's History: one per batch, or eight. On an autocommit connection, each batch is one owned transaction (`BEGIN`, one insert per record, `COMMIT`). Joined batches ride the caller's transaction, followed by `COMMIT`. Every insert is a server round trip in both implementations, so the 8-record rows are dominated by the server's work (jsonb parsing and five index updates per row), which is the same for both clients. In the second repetition `append.autocommit-8` came out 0.97× (533 µs against 515 µs); the median over both is the figure above.
- **`load.*`** opens a store over 1 002 or 10 002 recorded rows: the load query, then each payload read as text, parsed with `json.loads` semantics, and decoded.
- **`verify.conflict-acknowledge`** is a stale writer appending a fact another writer already recorded value-equal at its position: the insert conflicts, the row is re-read, the payloads are compared with Python equality, and the fact is acknowledged.

## Wall-clock time, and the earlier figures

The figures committed before these were tasty-bench's default CPU time, against Python's wall-clock time. CPU time leaves out the time the client waits for the server, which is most of every row here, so it flattered Haskell by about 2–4× on the round-trip rows (`append.autocommit-1` read 23–35 µs). Measured the same way as Python, Haskell is still faster on every row, by 5–14% on the round-trip rows and 2.4–2.5× on the loads, which parse every payload client-side.

## A note on the server

Run against the Docker Desktop container the tests used, the Python rows came out several times slower than on a native server: through Docker's port forward one `SELECT 1` round trip costs about 170 µs for every blocking libpq client measured (`pgbench`, psycopg). The Haskell figure then looked unaffected, at about 8.5 µs, but that was CPU time, which leaves out the wait; it was not a faster round trip. The committed figures come from a native server, where `pgbench` and psycopg see 16–24 µs per round trip.

## Rerun

From the repository root (`scripts/bench petrus-history-postgres` runs exactly this block). It needs a server where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is unset, `scripts/bench` and `scripts/bench-compare` start a throwaway one with `scripts/with-postgres`. A scratch database is created and dropped on each side.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-history-postgres --benchmark-options '--stdev 5 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-history-postgres/bench/python_bench.py)
```

`scripts/bench-compare petrus-history-postgres 2` interleaves both sides and prints the table above.
