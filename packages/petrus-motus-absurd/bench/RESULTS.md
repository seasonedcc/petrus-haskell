# petrus-motus-absurd benchmarks

<!-- scripts/bench: measured sources 8e72756f73239cc8 at 679f2e606e7a -->
<!-- scripts/bench: carried to a6892c5035b7b106 at c33829edc562: Postgres-backed; the petrus-sqlite bind guard and the petrus-json/posix changes are off its measured path -->
<!-- scripts/bench: carried to 641ada61ac45e379 at f87d05b6f42b: replaces the c33829e carry's wording, which put every petrus-json change off the measured path: since 679f2e6 the changes under it were petrus-json's (json.loads refusal path, Exception, PyObject additions, uuid4 hex digits through intToDigit), petrus-posix's additions and docs and petrus-sqlite's bind length guard; the bench is Postgres-backed and binds no SQLite parameter, and of these only uuid4's digit spelling (the same lowercase digits) is on its measured path, once per lane rotation (openAbsurdWorkerDispatch), which is negligible. Since 50635f0, no behavior or representation change on the measured paths: spellFailure's truthy is petrus-json's pythonTruthy, the same seven equations, on the failure path; petrus-motus's local-dispatch sqlite3 int-against-float == calls pyNumberEq, the same exact test it spelled out; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to c1126384b2ec70ce at b4d1ccb669ad: since f87d05b, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only -->

The Haskell side is [`bench/Main.hs`](Main.hs). The Python twin is
[`bench/python_bench.py`](python_bench.py), which runs the reference's
`petrus.motus.dispatch.absurd` with the same invocations, queues and doors. Both create a scratch
database, provision the pinned Absurd schema, and drop the database afterwards. Ratios above 1
mean Haskell is faster. Haskell is faster on every row: 1.16–1.45× on the PostgreSQL rows, whose
statements now run prepared from their sixth execution as psycopg's do (petrus-postgres's
prepared-statement cache), and 3.5× on the pure wire row.

## Current figures

Measured on 2026-10-12, 23:11–23:14 local (UTC-3), at commit `10b5172`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 4.06–4.82:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-motus-absurd 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `wire.encode-decode` | 968 ns | 3.47 µs | 3.59× | 3.42× | 3 of 3 | 1.01 µs, 968 ns, 956 ns | 3.45 µs, 3.47 µs, 3.48 µs |
| `calibration.select-1` | 17.7 µs | 24.9 µs | 1.40× | 1.39× | 3 of 3 | 17.7 µs, 17.7 µs, 17.9 µs | 24.7 µs, 24.9 µs, 25 µs |
| `dispatch.spawn-commit` | 275 µs | 352 µs | 1.28× | 1.25× | 3 of 3 | 267 µs, 275 µs, 277 µs | 352 µs, 356 µs, 346 µs |
| `roundtrip.dispatch-claim-complete-collect` | 1.46 ms | 1.71 ms | 1.17× | 1.16× | 3 of 3 | 1.46 ms, 1.46 ms, 1.46 ms | 1.74 ms, 1.71 ms, 1.7 ms |

## Earlier figures

- Date: 2026-10-11 01:11–01:34 local (UTC-3), on the commit that adds petrus-postgres's
  prepared-statement cache
- Machine: Darwin arm64, Apple M4, heavily shared with other agents. Load average 3.0–6.5
  (1-minute) around the run.
- Server: a throwaway PostgreSQL 17.7 from `scripts/with-postgres` (Postgres.app binaries,
  `initdb` defaults) on 127.0.0.1, TCP, trust auth.
- Haskell: GHC 9.10.3 `-O2 -threaded`, tasty-bench mean in wall-clock time (`--stdev 5`), run
  with `+RTS -M2G -RTS`.
- Python: CPython 3.14.6, psycopg 3.3.4 (binary), the pinned upstream venv; median of 10 timed
  batches (`scripts/bench_timing.py`) of at least 0.5 s each (see below).
- Interleaved by `scripts/bench-compare petrus-motus-absurd 6`, alternating Haskell first and
  Python first. The figures are the medians of the six repetitions; "lowest" is the worst
  single repetition's ratio, and the last column counts the repetitions Haskell won.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Repetitions Haskell faster |
|---|---:|---:|---:|---:|---:|
| `wire.encode-decode` | 1.01 µs | 3.71 µs | 3.68× | 3.41× | 6/6 |
| `calibration.select-1` | 17.3 µs | 23.2 µs | 1.34× | 0.77× | 5/6 |
| `dispatch.spawn-commit` | 545 µs | 631 µs | 1.16× | 0.68× | 5/6 |
| `roundtrip.dispatch-claim-complete-collect` | 1.86 ms | 2.24 ms | 1.20× | 0.59× | 4/6 |

The load was high and uneven, and the PostgreSQL rows moved with it far more than the
difference between the clients: Haskell's spawn ranged from 272 µs to 643 µs over the six
repetitions and Python's from 361 µs to 1.73 ms; Haskell's round trip from 1.28 ms to 4.06 ms
and Python's from 1.62 ms to 2.88 ms. Haskell lost the round trip in the fourth and sixth
repetitions, while the 1-minute load peaked at 5.2 and 6.5.
An earlier three-repetition run under a heavier load put `calibration.select-1` at 0.90× (Haskell lost all three); the round trip there is the
same `SELECT 1` as petrus-postgres's `roundtrip.select-1`, which a quieter six-repetition run
measured at 1.45×, Haskell faster in every repetition.

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

### Before the prepared-statement cache

<!-- bench: superseded -->

2026-10-10, about 20:10 local, a private PostgreSQL 17 (`fsync=off`), load average 2.4–3.4,
interleaved Haskell, Python, three times. Haskell was at least as fast as Python on every row,
in every round.

| Benchmark | Haskell (rounds 1 / 2 / 3) | Python (rounds 1 / 2 / 3) | Python / Haskell (before) |
|---|---:|---:|---:|
| `wire.encode-decode` | 0.95 / 0.96 / 0.95 µs | 3.5 / 3.5 / 3.5 µs | 3.7× / 3.7× / 3.7× |
| `calibration.select-1` | 18.7 / 18.5 / 18.6 µs | 24.4 / 25.2 / 24.3 µs | 1.31× / 1.36× / 1.31× |
| `dispatch.spawn-commit` | 320 / 311 / 319 µs | 330 / 338 / 341 µs | 1.03× / 1.09× / 1.07× |
| `roundtrip.dispatch-claim-complete-collect` | 1.75 / 1.75 / 1.60 ms | 1.80 / 1.76 / 1.71 ms | 1.03× / 1.00× / 1.07× |

## Why the PostgreSQL rows are close

The two PostgreSQL rows send the same statements on both sides (checked with
`log_statement = all`; since the prepared-statement cache, the same prepared statement names too): 6 round trips for a spawn, about 16 for a round trip. The server's work
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
scripts/bench-run petrus-motus-absurd --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-motus-absurd/bench/python_bench.py)
```

The PostgreSQL rows were wall-clock time from the start; `bench/Main.hs` now applies
`localOption WallTime` to every row, like the Python side.
