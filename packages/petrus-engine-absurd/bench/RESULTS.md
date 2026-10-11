# petrus-engine-absurd benchmarks

The Haskell side is [`bench/Main.hs`](Main.hs). The Python twin is
[`bench/python_bench.py`](python_bench.py), which runs the reference's
`petrus.engine.absurd.create_engine` on the same net (the topology net of
`tests/absurd_support.py`) and the same doors.

Both sides do the following:

- create a scratch database;
- provision the pinned History and Absurd schemas;
- drop the database afterwards.

Ratios above 1 mean Haskell is faster. Haskell is faster than Python on every row, in every round.

- Date: 2026-10-10, about 20:05 local (UTC-3).
- Machine: Darwin arm64, Apple M4, shared with other agents. The 1-minute load average was taken
  before, between and after every run:
  - round 1: 3.3 → 4.3;
  - round 2: 4.3 → 4.1;
  - round 3: 4.1 → 6.0 / 5.7.
- Server: a private PostgreSQL 17 (Postgres.app binaries, `fsync=off`) on 127.0.0.1, over TCP with
  trust auth. It was started for the runs and stopped afterwards.
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean (`--stdev 5`), run with
  `+RTS -M2G -RTS`. Both rows use wall-clock time (`localOption WallTime` in `Main.hs`).
- Python: CPython 3.14.6 with psycopg 3 (binary), in the pinned upstream venv. The figure is the
  median of 10 timed batches (`scripts/bench_timing.py`) of at least 0.5 s each.
- The runs were interleaved: Haskell, then Python, three times.

| Benchmark | Haskell (rounds 1 / 2 / 3) | Python (rounds 1 / 2 / 3) | Python / Haskell |
|---|---:|---:|---:|
| `engine.create-close` | 2.91 / 2.94 / 3.13 ms | 3.43 / 3.39 / 3.83 ms | 1.18× / 1.15× / 1.22× |
| `roundtrip.issue-to-completion` | 9.20 / 9.36 / 11.34 ms | 11.82 / 13.04 / 11.78 ms | 1.28× / 1.39× / 1.04× |

Round 3's round trip ran at the highest load of the session (above 6 by the end of the Haskell
run). Both of its figures are the noisiest in the table.

## What each row measures

**`engine.create-close`** opens fresh joined and listen connections, then calls `create_engine`
for a fresh Instance. That covers:

- connection validation;
- the authority fence;
- the empty History load;
- the construction commit;
- the `LISTEN` on the results channel.

The row then closes the Engine, which releases the fence and closes both connections. Opening the
two connections is part of the figure on both sides.

**`roundtrip.issue-to-completion`** is one Instance's whole life, with an in-process
`AbsurdWorkerDispatch`:

1. Create the Engine and deliver an issue.
2. Advance until blocked. The begin batch, its `absurd.spawn_task` and the `impetus_dispatch`
   doorbell commit together.
3. The Worker claims `spark_work` and completes it.
4. The Engine drives until rest: it collects the result and projects it.
5. The approval arrives and the Engine drives to completion. The row checks the `Completed`
   status, then closes the Engine.

Every 256 Instances, the round trip's queue retires. A fresh queue and Worker take over, and the
old queue is dropped with `absurd.drop_queue`. This keeps the queue's tables bounded, because
Absurd's claim sweeps scan them. Both sides do this the same way, and its cost is amortized into
both figures.

## Measurement notes

The same notes as [petrus-motus-absurd's results](../../petrus-motus-absurd/bench/RESULTS.md)
apply:

- **Wall time.** Most of each row is server round trips, which tasty-bench's default CPU time
  would not count.
- **Equal samples.** The cost of a row grows with the Absurd state that has accumulated, so
  `python_bench.py` uses 0.5 s batches rather than `bench_timing.py`'s 0.05 s default. With the
  default, Python would sample only the first Instances of a fresh database, while tasty-bench
  samples thousands.

## Rerun

```sh
# any server where the role may create databases; a scratch database is created and dropped
export PETRUS_TEST_POSTGRES=postgresql://postgres@127.0.0.1:5432/postgres
cabal build -j2 petrus-engine-absurd:bench:petrus-engine-absurd-bench
(cd packages/petrus-engine-absurd && \
  $(cabal list-bin petrus-engine-absurd:bench:petrus-engine-absurd-bench) --stdev 5 --timeout 300 +RTS -M2G -RTS)
(cd upstream/petrus && "$(../../scripts/upstream-python)" ../../packages/petrus-engine-absurd/bench/python_bench.py)
# or both in one go, which regenerates this file in scripts/bench's standard layout:
# scripts/bench petrus-engine-absurd
```
