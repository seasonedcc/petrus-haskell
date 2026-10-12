# petrus-sqlite benchmarks

<!-- scripts/bench: measured sources db5a903955267dac at 7d1b80ce6e49 -->

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names and values. Both are wall-clock time. Ratios above 1 mean Haskell is
faster. **Haskell is ahead on every row of the current table.** The closest
rows are the two transaction rows, which are bound by the device's `fsync`.
Both sides make the same syncs, and these two rows are level within the
device's noise. In this run they read 1.03× and 1.02×, but pooled over 35
repetitions run the same evening, the commit row's medians read **0.95×**
(Haskell ahead in 21 of the 35) and the 100-insert row's 1.01× (below).
With the database on a RAM disk, where a sync costs next to nothing,
Haskell was ahead in every repetition of both rows (below).

## Current figures

- Date: 2026-10-12, 20:25–20:28 local (UTC-3), at commit `7180a9d`
- Machine: Darwin arm64, Apple M4; 1-minute load average 2.25–3.49 around
  the runs
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time,
  `--stdev 5`, `+RTS -M2G -RTS`; the two `tx` rows use the twin protocol
  (below)
- Python: CPython 3.14.6 (upstream venv), median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- Interleaved by `scripts/bench-compare petrus-sqlite 5`, alternating which
  side goes first. The figures are the medians of the 5 repetitions; the
  last columns give each repetition and the repetitions in which Haskell
  was faster.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `tx.immediate-insert-commit` | 32.4 µs | 33.3 µs | 1.03× | 1.01× | 5 of 5 | 32.3 µs, 32.2 µs, 32.4 µs, 33.1 µs, 32.8 µs | 34.2 µs, 33.8 µs, 33.1 µs, 33.3 µs, 33.2 µs |
| `tx.immediate-insert-100` | 303 µs | 320 µs | 1.06× | 0.92× | 3 of 5 | 327 µs, 292 µs, 303 µs, 294 µs, 336 µs | 320 µs, 373 µs, 326 µs, 314 µs, 310 µs |
| `connect.local-dispatch-profile` | 47 µs | 56.2 µs | 1.19× | 1.18× | 5 of 5 | 47.8 µs, 47 µs, 47 µs, 47.3 µs, 46.8 µs | 58.5 µs, 55.5 µs, 56.2 µs, 55.8 µs, 56.5 µs |
| `query.select-by-key` | 1.2 µs | 1.64 µs | 1.36× | 1.35× | 5 of 5 | 1.21 µs, 1.18 µs, 1.21 µs, 1.2 µs, 1.19 µs | 1.66 µs, 1.64 µs, 1.63 µs, 1.65 µs, 1.63 µs |
| `query.select-1000` | 350 µs | 432 µs | 1.24× | 1.23× | 5 of 5 | 351 µs, 351 µs, 350 µs, 349 µs, 349 µs | 432 µs, 435 µs, 431 µs, 430 µs, 432 µs |
| `schema.normalize-ddl` | 2.72 µs | 5.06 µs | 1.86× | 1.84× | 5 of 5 | 2.74 µs, 2.68 µs, 2.7 µs, 2.72 µs, 2.74 µs | 5.09 µs, 5.06 µs, 5.14 µs, 5.05 µs, 5.04 µs |
| `fence.acquire-release` | 30.1 µs | 37.3 µs | 1.24× | 1.19× | 5 of 5 | 31.5 µs, 29.7 µs, 29.7 µs, 30.1 µs, 30.8 µs | 37.3 µs, 37.3 µs, 37.2 µs, 37.4 µs, 37.5 µs |

Haskell is ahead in every repetition of every row but 100 inserts. The two
transaction rows are `fsync`-bound and level: the commit row 1.03× (5 of 5)
and 100 inserts 1.06× (3 of 5, 0.92× in the slowest repetition). The same
protocol at `fae8539` (finished 17:39, load 2.24–2.58), before petrus-json's
duplicate pre-check came back, read 1.03× (5 of 5) and 1.02× (2 of 5), and
every other row within 4% of this table.

### The transaction rows over 35 repetitions

The protocol above is the documented one, and its five repetitions are the
headline. Right after its run at `fae8539` (finished 17:39), the two
transaction rows were run on their own for 30 more repetitions, on the same
code (`fae8539`, and `cb654fd`, which changed only another package's
results file). Each run's ratio of medians:

- the five-repetition run at `fae8539`: 1.03× for the commit row (Haskell
  ahead in 5 of 5) and 1.02× for 100 inserts (2 of 5);
- 17:51–17:53, load 1.83–2.29, ten repetitions
  (`scripts/bench-compare petrus-sqlite 10 --pattern tx --python-only
  '^tx\.'`): 0.86× (6 of 10) and 1.02× (5 of 10);
- 17:55–17:59, load 1.72–2.90, twenty repetitions (the same command with
  20): 0.93× (10 of 20) and 0.96× (11 of 20).

Pooled, the 35 repetitions read:

| Row | Haskell median | Python median | Haskell ahead | Fastest Haskell | Fastest Python |
| --- | ---: | ---: | ---: | ---: | ---: |
| `tx.immediate-insert-commit` | 36.1 µs | 34.2 µs | 21 of 35 | 32.1 µs | 33.0 µs |
| `tx.immediate-insert-100` | 348 µs | 350 µs | 18 of 35 | 300 µs | 312 µs |

That is **0.95×** for the commit row's medians (the median of the 35
paired ratios is 1.02×) and 1.01× for 100 inserts (paired, 1.01×). Haskell
is faster in more pairs than not, and its fastest repetitions are faster
than Python's. But more of its repetitions fell in the device's slow
stretches: in each long run, a stretch of repetitions ran at 40–70 µs a
commit on both sides, and Haskell's did so more often than Python's.

**Why these rows are level.** Every commit is an `fsync` (WAL,
`synchronous=FULL`), and both sides make the same system calls. Counted
on macOS with an interposed library over one batch and its warm-up, the
commit row makes 5 062 `fsync` and 36 132 `pwrite` calls on each side,
and the 100-insert row 541 and 27 105 (no `F_FULLFSYNC` on either side).
The device's time per sync varies from minute to minute.

**On a RAM disk.** As a check, the two rows were run once more with the
scratch database on a 512 MiB `hdiutil` RAM disk (`TMPDIR` pointing at it,
for both sides), where a sync costs next to nothing. That was on
2026-10-12 at 18:08, load 2.42–2.65, ten repetitions of the command
above, at `33f3581`, with the same bench code. Haskell was ahead in every
repetition of both rows:

- the commit row: 19.5 µs against 20.3 µs a commit (1.04×, 10 of 10,
  1.02× at the least);
- 100 inserts: 244 µs against 260 µs (1.06×, 10 of 10, 1.02× at the
  least).

So the statement and transaction work on both rows, which is the port's,
is faster in Haskell; on the disk, the device's noise decides each
repetition.

## What changed

- **Transaction control through the statement cache.** `BEGIN IMMEDIATE`,
  the implicit `BEGIN`, `COMMIT` and `ROLLBACK` used to go through
  `sqlite3_exec`, which parses and compiles the statement every time. They
  now run from the connection's statement cache, as CPython runs
  `execute("BEGIN IMMEDIATE")`. The step stays a safe FFI call, since a
  `BEGIN IMMEDIATE` can wait on the busy handler and a `COMMIT` syncs. The
  SQL, the durability and the error texts are unchanged.
- **The fence's lock-file path.** The fence opens
  `.impetus-sqlite-locks/<name>.lock` through petrus-posix. Its path
  marshalling now takes one pass and remembers the most recent path (see
  [petrus-posix's results](../../petrus-posix/bench/RESULTS.md)). That took
  the fence row from 0.98× to 1.17× (1.24× now).
- **The `tx` rows: the same iterations on both sides.** Every iteration
  adds rows to one table, so a commit costs more the more iterations have
  run, and a side that runs more iterations measures a bigger table.
  tasty-bench chooses its iteration count from the spread it sees (it kept
  doubling it on a loaded machine: one run of `immediate-insert-commit` took
  78 s, about 20 times the twin's iterations), and the 15% target that
  replaced it still left the counts to chance. Both rows are now timed with
  the twin's protocol on both sides (`twin` from
  `Petrus.TestSupport.BenchTwin`; `report(name, fn, number)` in
  `scripts/bench_timing.py`): one warm-up call, then 10 batches of a fixed
  number of calls, 5 000 for `immediate-insert-commit` and 500 for
  `immediate-insert-100`, and the median per call. Each side's database
  therefore grows by exactly the same rows. The Haskell rows print `twin
  NAME NANOSECONDS`, which `scripts/bench-compare` reads.

Measured and ruled out: the SQLite build. `PRAGMA compile_options` of
direct-sqlite's bundled 3.45.0 and of CPython's 3.53.4 agree on everything
that bears on these rows: `THREADSAFE=1`, `MUTEX_PTHREADS`,
`SYSTEM_MALLOC`, `DEFAULT_SYNCHRONOUS=2`, `DEFAULT_WAL_SYNCHRONOUS=2`,
`DEFAULT_WAL_AUTOCHECKPOINT=1000`, `DEFAULT_MMAP_SIZE=0`, `TEMP_STORE=1`,
`DEFAULT_PAGE_SIZE=4096`, `DIRECT_OVERFLOW_READ`; the effective
`synchronous` (2), `fullfsync` and `checkpoint_fullfsync` (0) and page
cache (`-2000`) are the same. CPython's build adds features the rows do not
use (`ENABLE_STAT4`, `ENABLE_RTREE`, `ENABLE_SESSION`,
`ENABLE_PREUPDATE_HOOK`, `ENABLE_API_ARMOR`, ...). The bench built against
the system SQLite (Homebrew 3.5x, direct-sqlite's `systemlib` flag) was
not faster than the bundled build in three interleaved rounds: 33–34 µs
against 33 µs per commit, 320–324 µs against 300–310 µs for 100 inserts,
378–384 µs against 353–359 µs for `query.select-1000`. So the bundled build
stays. A probe of 2 000 single-insert fsynced commits in WAL mode also took
the same time, within noise, on both SQLite builds and from CPython.
Durability is the same on both sides: `synchronous=FULL`, WAL, and plain
`fsync`, never `F_FULLFSYNC`.

### The direct text bind, measured again (2026-10-12)

`execute` binds text parameters straight from the `Text`'s UTF-8 array
(`cbits/petrus_sqlite.c`) instead of through direct-sqlite's `bind`, which
first copies each text into a pinned buffer. Measured again against
direct-sqlite's `bind`, on the Apple M4 at a load average of 3.1–5.6, each
binary interleaved, alternating which goes first:

- `tx.immediate-insert-100`, ten repetitions: 312 µs with the direct bind
  against 332 µs with `bind` (the direct bind faster in all ten pairs);
  then six more, three-way with the Python twin: 328 µs, 333 µs and
  CPython's 341 µs (1.04× against 1.03×).
- `tx.immediate-insert-commit` (33.5 µs both), `query.select-by-key` and
  `query.select-1000`: level.

`tx.immediate-insert-100` is one of the rows `scripts/bench-gate` gates on
the Linux runners, and it is within a few percent of the reference either
way (an `fsync` per commit on both sides), so the bind stays, with this
figure in its comment.

## Wall-clock time, and the earlier figures

### The table at `da94728` (2026-10-12, 09:48–09:50)

<!-- bench: superseded -->

- Date: 2026-10-12 09:48–09:50 local (UTC-3), at commit `da94728`
  (`connect` now sets the busy timeout with `sqlite3_busy_timeout`, as
  `sqlite3.connect(timeout=…)` does, instead of a `PRAGMA busy_timeout`
  statement; `execute` binds text parameters from the `Text`'s own UTF-8
  array, still checking the parameter count)
- Machine: Darwin arm64, Apple M4; 1-minute load average 2.08–2.26 around
  the runs
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time,
  `--stdev 5`, `+RTS -M2G -RTS`; the two `tx` rows use the twin protocol
  (below)
- Python: CPython 3.14.6 (upstream venv), median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- Interleaved by `scripts/bench-compare petrus-sqlite 5`, alternating which
  side goes first. The figures are the medians of the 5 repetitions; the
  last two columns give each repetition.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `tx.immediate-insert-commit` | 31.6 µs | 33 µs | 1.05× | 0.97× | 31.2 µs, 31.6 µs, 33.7 µs, 33.3 µs, 31.6 µs | 33 µs, 34.6 µs, 32.7 µs, 34.6 µs, 32.7 µs |
| `tx.immediate-insert-100` | 284 µs | 314 µs | 1.11× | 1.04× | 301 µs, 297 µs, 283 µs, 282 µs, 284 µs | 314 µs, 315 µs, 319 µs, 311 µs, 310 µs |
| `connect.local-dispatch-profile` | 47.4 µs | 56.2 µs | 1.19× | 1.16× | 47.4 µs, 47.4 µs, 47.2 µs, 47.9 µs, 47.5 µs | 56.3 µs, 56.2 µs, 56.2 µs, 55.4 µs, 56 µs |
| `query.select-by-key` | 1.17 µs | 1.62 µs | 1.38× | 1.38× | 1.17 µs, 1.18 µs, 1.18 µs, 1.17 µs, 1.16 µs | 1.62 µs, 1.63 µs, 1.63 µs, 1.62 µs, 1.62 µs |
| `query.select-1000` | 348 µs | 432 µs | 1.24× | 1.20× | 346 µs, 357 µs, 348 µs, 348 µs, 346 µs | 431 µs, 430 µs, 437 µs, 432 µs, 432 µs |
| `schema.normalize-ddl` | 2.7 µs | 5.03 µs | 1.87× | 1.80× | 2.79 µs, 2.7 µs, 2.64 µs, 2.71 µs, 2.65 µs | 5.03 µs, 5.02 µs, 5.03 µs, 5.08 µs, 5.04 µs |
| `fence.acquire-release` | 29.7 µs | 37.2 µs | 1.25× | 1.24× | 30 µs, 29.5 µs, 29.7 µs, 29.8 µs, 29.6 µs | 37.1 µs, 37.2 µs, 37.2 µs, 37.3 µs, 37.1 µs |

The table before this one (2026-10-11, seven repetitions at load 3.9–5.1,
commit `3f31d2e`, with tasty-bench choosing the `tx` rows' iteration
counts) read 1.15× for the connection, 1.04× and 1.01× for the two
transaction rows, 1.37× and 1.22× for the queries, 1.69× for the DDL
normalization and 1.17× for the fence. The one before that (2026-10-10, two
repetitions, commit `74e6b1e`) read 1.19×, 1.08×, 1.09×, 1.37×, 1.24×, 1.75×
and 0.98× for the fence (39.1 µs against 38.3 µs).

That table replaced one generated by the old `scripts/bench`, which timed Haskell
in tasty-bench's default CPU time against Python's wall-clock time. CPU time
leaves out the time spent blocked in the kernel, such as the fsync at each
`COMMIT` (`synchronous=FULL`, WAL). For these rows the two clocks came out
close: `tx.immediate-insert-commit` read 34.4 µs in CPU time and 33.8 µs in
wall-clock time, and the other rows are within the run-to-run spread of the
old table or below it. The fence row moved from 1.03× to 0.98× then.

What each row measures, over a scratch database with the reference's
connection posture (`busy_timeout=5000`, `foreign_keys=ON`,
`synchronous=FULL`, `journal_mode=WAL`) and 1 000 seeded History rows:

- **`connect.local-dispatch-profile`**: open and close a connection with Local
  Dispatch's profile (the pragmas).
- **`tx.immediate-insert-commit`**: one History-row insert in a
  `BEGIN IMMEDIATE` transaction, committed.
- **`tx.immediate-insert-100`**: one hundred inserts in one such transaction.
- **`query.select-by-key`**: one row by primary key.
- **`query.select-1000`**: the 1 000 seeded rows, five columns each.
- **`schema.normalize-ddl`**: the DDL normalization the schema check uses, in
  memory.
- **`fence.acquire-release`**: the SQLite writer fence (an exclusive,
  nonblocking `flock` on a lock file under `.impetus-sqlite-locks/` beside the
  database), taken and released.

The Haskell side is direct-sqlite 2.3.29, which bundles SQLite 3.45.0;
CPython 3.14.6 links SQLite 3.53.4.

## Rerun

From the repository root (`scripts/bench petrus-sqlite` runs exactly this block, once;
`scripts/bench-compare petrus-sqlite 5` interleaves the two sides and prints the table above).

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-sqlite --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-sqlite/bench/python_bench.py)
```
