# petrus-motus-absurd benchmarks

The Haskell side is [`bench/Main.hs`](Main.hs). The Python twin is
[`bench/python_bench.py`](python_bench.py), which runs the reference's
`petrus.motus.dispatch.absurd` with the same invocations, queues and doors. Both create a scratch
database, provision the pinned Absurd schema, and drop the database afterwards. Ratios above 1
mean Haskell is faster. Haskell is at least as fast as Python on every row, in every round.

- Date: 2026-10-10, about 20:10 local (UTC-3)
- Machine: Darwin arm64, Apple M4, shared with other agents. Load average 2.4–3.4 (1-minute),
  taken before, between and after every run.
- Server: a private PostgreSQL 17 (Postgres.app binaries, `fsync=off`) on 127.0.0.1, TCP,
  trust auth; started for the runs and stopped afterwards.
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean (`--stdev 5`), run with
  `+RTS -M2G -RTS`. The PostgreSQL rows use wall-clock time (set in `Main.hs`): their time is
  mostly spent waiting on the server, which tasty-bench's default CPU time would not count.
  `wire.encode-decode`, which is pure, was taken in CPU time; `Main.hs` now measures every row in
  wall-clock time, and for a pure single-threaded row the two agree.
- Python: CPython 3.14.6, psycopg 3 (binary), the pinned upstream venv; median of 10 timed
  batches (`scripts/bench_timing.py`) of at least 0.5 s each (see below).
- Interleaved: Haskell, Python, three times.

| Benchmark | Haskell (rounds 1 / 2 / 3) | Python (rounds 1 / 2 / 3) | Python / Haskell |
|---|---:|---:|---:|
| `wire.encode-decode` | 0.95 / 0.96 / 0.95 µs | 3.5 / 3.5 / 3.5 µs | 3.7× / 3.7× / 3.7× |
| `calibration.select-1` | 18.7 / 18.5 / 18.6 µs | 24.4 / 25.2 / 24.3 µs | 1.31× / 1.36× / 1.31× |
| `dispatch.spawn-commit` | 320 / 311 / 319 µs | 330 / 338 / 341 µs | 1.03× / 1.09× / 1.07× |
| `roundtrip.dispatch-claim-complete-collect` | 1.75 / 1.75 / 1.60 ms | 1.80 / 1.76 / 1.71 ms | 1.03× / 1.00× / 1.07× |

What each row measures:

- **`wire.encode-decode`**: one invocation to its task payload and back through the strict
  decoder (`encode_invocation`, `decode_invocation`). Pure.
- **`calibration.select-1`**: one `SELECT 1` on an autocommit connection, the round trip every
  other row is built from.
- **`dispatch.spawn-commit`**: one fresh occurrence through `AbsurdDispatch.dispatch` on a
  join-mode connection, then the commit: the advisory lock, the lookup across every queue, the
  keyed `absurd.spawn_task`, and the `impetus_dispatch` doorbell.
- **`roundtrip.dispatch-claim-complete-collect`**: one occurrence's whole custody cycle. The
  authority dispatches and commits. An `AbsurdWorkerDispatch` claims the task (the claim, the
  lease extension, the latest-details read) and completes it (the fenced run lock, `complete_run`,
  the `impetus_results` doorbell). The authority then collects the outcome and commits.

Every 256 dispatches a row's lane retires: a fresh queue, adapter, Instance and (for the round
trip) Worker take over, and the old queue is dropped. Both sides do this alike, and its cost is
amortized into both figures.

## Why the PostgreSQL rows are close

The two PostgreSQL rows send the same statements on both sides (checked with
`log_statement = all`): 6 round trips for a spawn, about 16 for a round trip. The server's work
for them (plpgsql, the queue's tables and indexes, the commit) is most of each figure, and it is
the same for both clients. The client-side difference shows in `calibration.select-1`: Haskell's
round trip is about 6 µs cheaper, which is 2–3% of a spawn.

## Measurement notes

- **State-dependent rows need equal samples.** Absurd's claim sweeps scan the queue's task
  table, and every queue rotation leaves catalog churn behind, so a round trip costs more after
  thousands of them than after the first few hundred. tasty-bench samples thousands of
  iterations. With `bench_timing.py`'s default 0.05 s batches, Python sampled only about 400
  round trips of a fresh database and reported 1.2 ms, against 1.9–2.2 ms for the same code
  over thousands of iterations. `python_bench.py` therefore defaults to 0.5 s batches.
- **Wall time, not CPU time.** Under tasty-bench's default CPU-time mode, the round trip reads as
  a fraction of its real duration, because the client sleeps while the server works. The
  PostgreSQL rows here set wall time explicitly.
- **Load matters more than the client.** An earlier set of rounds at load average 4–5 spread the
  round trip between 1.57 and 2.02 ms on the Haskell side and 1.66 and 2.13 ms on the Python
  side.

## Rerun

From the repository root (`scripts/bench petrus-motus-absurd` runs exactly this block). It needs a server
where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is unset, `scripts/bench`
starts a throwaway one with `scripts/with-postgres`. A scratch database is created and dropped.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-motus-absurd --benchmark-options '--stdev 5 --timeout 300 +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-motus-absurd/bench/python_bench.py)
```

The PostgreSQL rows were wall-clock time from the start; `bench/Main.hs` now applies
`localOption WallTime` to every row, like the Python side.
