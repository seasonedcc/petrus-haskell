# petrus-engine-absurd benchmarks

<!-- scripts/bench: measured sources a8d9e387815be5f8 at 570780d31e8a -->

The Haskell side is [`bench/Main.hs`](Main.hs). The Python twin is
[`bench/python_bench.py`](python_bench.py), which runs the reference's
`petrus.engine.absurd.create_engine` on the same net (the topology net of
`tests/absurd_support.py`) and the same doors.

Both sides do the following:

- create a scratch database;
- provision the pinned History and Absurd schemas;
- drop the database afterwards.

## Current figures

Measured on 2026-10-12, 01:57–01:58 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.85–3.17:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-engine-absurd 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The server was `scripts/with-postgres`'s throwaway PostgreSQL 17.7 (`initdb` defaults, so `fsync` on); the `fsync=off` table below was not rerun. The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `engine.create-close` | 2.73 ms | 3.13 ms | 1.15× | 1.13× | 2.78 ms, 2.73 ms, 2.73 ms | 3.13 ms, 3.09 ms, 3.18 ms |
| `roundtrip.issue-to-completion` | 8.72 ms | 11.2 ms | 1.29× | 1.26× | 8.64 ms, 8.89 ms, 8.72 ms | 11.3 ms, 11.2 ms, 11.2 ms |

## Earlier figures

Ratios above 1 mean Haskell is faster. Haskell is faster than Python on every row, on a server
with `fsync` on and with it off, in every repetition. Statements run prepared from their sixth
execution on a connection, as psycopg's do (petrus-postgres's prepared-statement cache).

- Date: 2026-10-11 07:05–07:11 local (UTC-3), at commit `ccc5c9b`.
- Machine: Darwin arm64, Apple M4, shared with other agents. Each run started once the 1-minute
  load average was 3 or below and the 5-minute one 4 or below; the 1-minute load was 1.48–2.54
  around the repetitions. (A run at 06:53–06:58, while another agent's stress tests drove the
  load to 7–25, was discarded.)
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean (`--stdev 5`), run with
  `+RTS -M2G -RTS`, the benchmark executable started directly by bench-compare. Both rows use
  wall-clock time (`localOption WallTime` in `Main.hs`).
- Python: CPython 3.14.6 with psycopg 3.3.4 (binary), in the pinned upstream venv. The figure is
  the median of 10 timed batches (`scripts/bench_timing.py`) of at least 0.5 s each (see
  "Equal samples" below).
- Interleaved by `scripts/bench-compare petrus-engine-absurd 7`, alternating Haskell first and
  Python first. The figures are the medians of the seven repetitions; "lowest" is the worst
  single repetition's ratio, and the last column counts the repetitions Haskell won.

**`fsync` on** (`scripts/with-postgres`'s throwaway PostgreSQL 17.7, `initdb` defaults,
07:05–07:08, load 1.48–2.31):

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `engine.create-close` | 3.03 ms | 3.50 ms | 1.16× | 1.14× | 7/7 |
| `roundtrip.issue-to-completion` | 10.2 ms | 12.4 ms | 1.21× | 1.19× | 7/7 |

**`fsync` off** (a private PostgreSQL 17.7 started with `-c fsync=off`, TCP only, 07:08–07:11,
load 2.02–2.54):

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `engine.create-close` | 3.07 ms | 3.52 ms | 1.15× | 1.13× | 7/7 |
| `roundtrip.issue-to-completion` | 9.87 ms | 12.4 ms | 1.25× | 1.23× | 7/7 |

On a quiet machine `fsync` barely matters here: the round trip's thirteen commits cost about
0.3 ms more on the Haskell side with `fsync` on, and nothing measurable on the Python side.
The 0.72× of the earlier `fsync=on` run below came from disk contention, not from the client.

### The rounds of 2026-10-11, 02:21–02:25

<!-- bench: superseded -->

- Date: 2026-10-11 02:21–02:25 local (UTC-3), on the commit that adds petrus-postgres's
  prepared-statement cache.
- Machine: Darwin arm64, Apple M4, heavily shared with other agents. 1-minute load average
  4.6–5.8 around the run.
- Server: a private PostgreSQL 17.7 (Postgres.app binaries, `fsync=off`, as for the superseded
  table below) on 127.0.0.1, over TCP with trust auth. It was started for the runs and stopped
  afterwards.
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean (`--stdev 5`), run with
  `+RTS -M2G -RTS`. Both rows use wall-clock time (`localOption WallTime` in `Main.hs`).
- Python: CPython 3.14.6 with psycopg 3.3.4 (binary), in the pinned upstream venv. The figure is
  the median of 10 timed batches (`scripts/bench_timing.py`) of at least 0.5 s each.
- Interleaved by `scripts/bench-compare petrus-engine-absurd 6` with `PETRUS_TEST_POSTGRES`
  naming that server, alternating Haskell first and Python first. The figures are the medians
  of the six repetitions; "lowest" is the worst single repetition's ratio, and the last column
  counts the repetitions Haskell won.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `engine.create-close` | 3.36 ms | 3.88 ms | 1.15× | 0.97× | 5/6 |
| `roundtrip.issue-to-completion` | 10.9 ms | 14.5 ms | 1.33× | 1.00× | 6/6 |

### Under `fsync=on` and heavy load (2026-10-11, 01:35–01:50)

<!-- bench: superseded -->

A run twenty minutes earlier (01:35–01:50, load 4.3–5.8) used `scripts/with-postgres`'s
throwaway server, whose `initdb` defaults keep `fsync` on. The round trip commits ten times on
the Engine's connection and three times on the Worker's, and with other agents' builds
contending for the disk the figures swung far more than the clients differ: Haskell's round trip
ranged from 10.5 ms to 33.6 ms over six repetitions and Python's from 14.0 ms to 32.4 ms, and
the medians came out at 6.01 ms against 5.99 ms (1.00×) for `engine.create-close` and 25.8 ms
against 18.6 ms (0.72×) for the round trip. Haskell won the round trip in the second, third and sixth
repetitions (1.13×, 1.47× and 1.36×; in the third and sixth both sides ran fast) and lost the
other three.

Two checks point at the server rather than the client:

- **The statements are the same.** With `log_statement = all`, every round-trip Engine
  connection sent the same 58 statements with the same 10 commits on both sides, prepared at
  the same points and ending with the same
  `ROLLBACK` and `DEALLOCATE ALL`. Haskell spells `BEGIN ISOLATION LEVEL READ COMMITTED` where
  psycopg sends `BEGIN` (see petrus-postgres's DIVERGENCES). The Worker's connection sent 13
  statements per Instance on both sides.
- **The cache neither helps nor hurts here.** The same Haskell bench built with the cache off
  (`prepareThresholdOption = Nothing`) and on, alternated six times on the `fsync=off` server,
  measured the round trip at 12.2 ms off against 11.8 ms on (medians; the cache was faster in
  four of the six pairs) and `engine.create-close` at 3.96 ms against 3.52 ms. Each Engine
  opens fresh connections, so few of its statements reach a sixth execution.

### Before the prepared-statement cache

<!-- bench: superseded -->

2026-10-10, about 20:05 local, a private PostgreSQL 17 (`fsync=off`), interleaved Haskell, then
Python, three times. The 1-minute load average went 3.3 → 4.3 in round 1, 4.3 → 4.1 in round 2
and 4.1 → 6.0 / 5.7 in round 3.

| Benchmark | Haskell (rounds 1 / 2 / 3) | Python (rounds 1 / 2 / 3) | Python / Haskell (before) |
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

From the repository root (`scripts/bench petrus-engine-absurd` runs exactly this block). It needs a server
where the role may create databases in `PETRUS_TEST_POSTGRES`; when that is unset, `scripts/bench`
starts a throwaway one with `scripts/with-postgres`. A scratch database is created and dropped.

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-engine-absurd --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-engine-absurd/bench/python_bench.py)
```

Both rows are wall-clock time (`localOption WallTime` in `bench/Main.hs`), like the Python side.
