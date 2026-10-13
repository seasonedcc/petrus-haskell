# History store benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 766a1238477868a8 at f87d05b6f42b -->
<!-- scripts/bench: carried to 1df01e70a3ef7e11 at b4d1ccb669ad: since f87d05b, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` build the same
History: 20 002 records from a drained 4 000-token FIFO. They time the same
workloads over it. Each Python line prints a result size (a record count),
and the Haskell side computes the same number.

## How to rerun

From the repository root (`scripts/bench petrus-history-store` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-history-store --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-history-store/bench/python_bench.py)
```

Haskell numbers are tasty-bench means in wall-clock time (`localOption
WallTime` in `bench/Main.hs`), `--stdev 5`, `+RTS -M2G`, except
`sqlite.append-per-record`, which is timed with the twin's protocol (one
warm-up, then the median of 3 runs; "Current figures"). Python numbers are the
median of 3–20 runs after one warm-up (`time.perf_counter`). Both run on an
Apple M4 with 24 GB of memory, using GHC 9.10.3 (`-O2`; `-A32m` until
2026-10-12, the RTS defaults since, see "Current figures") and CPython
3.14.6; the Haskell SQLite is direct-sqlite 2.3.29 (bundled SQLite 3.45.0),
CPython's is SQLite 3.53.4. The reference was pinned at `upstream/petrus`
3f85fc2.

The machine was shared with other agents. Four full rounds ran interleaved
(Haskell, Python, then Python, Haskell), all on 2026-10-10 local time
(UTC-3):
- rounds 1–2 at 21:22–21:29, at commit `74e6b1e` with the switch to
  wall-clock time, load average 7.7–11.6;
- rounds 3–4 at 22:17–22:24, after merging `main` (`57106c2`), load average
  4.4–5.4.

That merge changed petrus-json's encoder, but the diagnostic encode row did
not move beyond noise (44.2 and 43.0 ms, then 46.0 and 58.2 ms), so the
rounds are pooled. Three more rounds of only the closest rows
(`sqlite/append-per-record`, `sqlite/append-batches-of-8`,
`jsonl/append-per-record` and `store/in-memory-append`; tasty-bench's `-p`
against the full Python script) followed at 22:33–22:41, load average 3.1–5.7.

Each figure is the median of the rounds that ran it: four, or seven for
those four rows. The in-memory append and the three SQLite append rows come
instead from a later interleaved run of five rounds, after the changes
described with them (see "Rerun of the append rows" below). The file-system rows (every `jsonl` and `sqlite` append)
swing by 20–50% between rounds on this machine, which is why the closest rows
got more rounds.

## Current figures

Measured on 2026-10-13, 05:25–05:38 local (UTC-3), at commit `f87d05b`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.91–3.80 and
no build running: five interleaved repetitions, alternating which side
goes first, of

    scripts/bench-compare petrus-history-store 5

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory, except `sqlite.append-per-record` (below); Python figures are the
twin's own timing (CPython 3.14.6). Each figure is the median over the
repetitions, and the ratio is Python ÷ Haskell (above 1 means Haskell is
faster). "Haskell ahead" counts the repetitions Haskell was faster in. The
rows without a Python figure are Haskell-only (described under the first
table below). The tables in the sections below are earlier measurements,
kept with the analysis that came with them.

Haskell was ahead in every repetition of every row with a Python twin. The
closest is `sqlite.append-per-record`, 1.18× (lowest repetition 1.07×):
2 000 `fsync`ed commits, with the same system calls on both sides (see the
`c550dcb` figures below), so it follows the device's time per sync, as
petrus-sqlite's transaction rows do. It read 1.13× at `c550dcb`, and 0.98×
over five repetitions at `df073f3` (2026-10-13, Haskell ahead in 3 of 5,
1.07× over the first three); it is level within the device's noise, and
this run has it ahead. Since `c550dcb` the packages under this one changed
(petrus-json, petrus-posix, petrus-sqlite and petrus-impetus), and so did
this package's `floatEqualsInteger`, now petrus-json's `pyNumberEq`, which
no row reaches (positions and occurrences are stored as integers). The
Haskell loads, resumes and diagnostic rows read 4–7% slower than at
`c550dcb`, the Python loads and resumes about 1%; `diagnostic.encode-payload`
is among them (21.3 against 19.9 ms), and its code, petrus-json's encoder,
has not changed since, which points at the machine rather than the code.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `sqlite.append-per-record` | 89 ms | 105 ms | 1.18× | 1.07× | 5 of 5 | 89 ms, 91.4 ms, 86 ms, 91.5 ms, 88 ms | 95.4 ms, 105 ms, 107 ms, 110 ms, 103 ms |
| `jsonl.append-one-batch` | 24.3 ms | 65.6 ms | 2.70× | 2.17× | 5 of 5 | 24.3 ms, 22.9 ms, 23.9 ms, 24.3 ms, 30.3 ms | 68.9 ms, 61.3 ms, 69.7 ms, 64.2 ms, 65.6 ms |
| `jsonl.append-per-record` | 48.6 ms | 67.3 ms | 1.38× | 1.31× | 5 of 5 | 52.9 ms, 47.5 ms, 49.1 ms, 48.6 ms, 47.8 ms | 69.2 ms, 63.6 ms, 68.1 ms, 67.3 ms, 66.7 ms |
| `jsonl.load` | 28.4 ms | 96 ms | 3.38× | 3.36× | 5 of 5 | 28.4 ms, 27.4 ms, 27.3 ms, 28.8 ms, 28.9 ms | 95.5 ms, 93.5 ms, 96 ms, 97.1 ms, 97.5 ms |
| `jsonl.resume` | 385 ms | 7.2 s | 18.69× | 18.35× | 5 of 5 | 385 ms, 372 ms, 389 ms, 381 ms, 387 ms | 7.2 s, 7.09 s, 7.2 s, 7.22 s, 7.1 s |
| `sqlite.append-one-batch` | 72.1 ms | 138 ms | 1.91× | 1.88× | 5 of 5 | 68.2 ms, 72.1 ms, 73.5 ms, 72.8 ms, 71.4 ms | 134 ms, 138 ms, 142 ms, 144 ms, 134 ms |
| `sqlite.append-batches-of-8` | 30.7 ms | 46.4 ms | 1.51× | 1.33× | 5 of 5 | 29 ms, 29.9 ms, 32 ms, 30.7 ms, 31.1 ms | 38.6 ms, 46.4 ms, 47.1 ms, 49.4 ms, 41.9 ms |
| `sqlite.load` | 44.9 ms | 106 ms | 2.36× | 2.29× | 5 of 5 | 46.4 ms, 44.9 ms, 43.6 ms, 45.5 ms, 42.5 ms | 106 ms, 104 ms, 109 ms, 108 ms, 106 ms |
| `sqlite.resume` | 400 ms | 7.23 s | 18.07× | 17.79× | 5 of 5 | 387 ms, 398 ms, 406 ms, 400 ms, 406 ms | 7.21 s, 7.12 s, 7.25 s, 7.26 s, 7.23 s |
| `sqlite.terminal-resend-ack` | 6.84 ms | 1.16 s | 170.28× | 169.27× | 5 of 5 | 6.84 ms, 6.58 ms, 6.84 ms, 6.86 ms, 6.67 ms | 1.16 s, 1.16 s, 1.32 s, 1.16 s, 1.18 s |
| `diagnostic.encode-payload` | 21.3 ms | — | — | — | — | 21.3 ms, 22.3 ms, 21.1 ms, 22.1 ms, 19.9 ms |  |
| `diagnostic.decode-lines` | 28.7 ms | — | — | — | — | 28.7 ms, 28.5 ms, 28.8 ms, 28.7 ms, 27.6 ms |  |
| `store.in-memory-append` | 252 µs | 424 µs | 1.68× | 1.63× | 5 of 5 | 258 µs, 249 µs, 252 µs, 255 µs, 246 µs | 421 µs, 422 µs, 424 µs, 430 µs, 428 µs |
| `store.in-memory-records` | 3.82 ns | 44.9 µs | 11732.67× | 9441.90× | 5 of 5 | 3.85 ns, 3.89 ns, 3.82 ns, 3.82 ns, 3.61 ns | 38.1 µs, 36.7 µs, 44.9 µs, 46.5 µs, 44.9 µs |
| `store.jsonl-records` | 3.67 ns | 44.4 µs | 12099.02× | 11166.93× | 5 of 5 | 3.67 ns, 3.8 ns, 3.49 ns, 3.69 ns, 3.34 ns | 44.4 µs, 42.5 µs, 44.1 µs, 46.1 µs, 44.7 µs |
| `store.in-memory-iterate` | 23 µs | 210 µs | 9.13× | 8.90× | 5 of 5 | 23.4 µs, 23 µs, 23 µs, 23 µs, 22.9 µs | 209 µs, 211 µs, 210 µs, 210 µs, 211 µs |
| `store.in-memory-records-list` | 36.4 µs | — | — | — | — | 36.4 µs, 36.8 µs, 35.5 µs, 36.4 µs, 34.6 µs |  |

### The figures at `c550dcb` (2026-10-12, 19:58–20:11)

<!-- bench: superseded -->

Measured at a 1-minute load average of 2.07–3.86, by the same command and
protocol as above.

Haskell was ahead in every repetition of every row with a Python twin; the
closest is `sqlite.append-per-record`, 1.13× (lowest repetition 1.10×).
Since the figures at `da94728` (09:31–09:42 the same day), the packages
under this one changed (petrus-json, petrus-posix, petrus-sqlite and
petrus-impetus among them). No row moved beyond the file system's swing but
the two batched SQLite rows, a few `fsync`ed commits of many rows each:
`sqlite.append-one-batch` went from 57.2 to 63.9 ms (still 1.96×, its
Python side 113 to 126 ms), and `sqlite.append-batches-of-8` reads 1.31×
there, 1.18× in the run at `fae8539` (17:40–17:52, load 1.98–2.60, five
repetitions) and 1.47× here, mostly on the Python side (30.1, 33.5 and
38.8 ms against 23.0, 28.4 and 26.4 ms). The `fae8539` run, before
petrus-json's duplicate pre-check came back, had `sqlite.append-per-record`
at 1.12×.

The three changes measured at `da94728`, against the figures at `81bbdc5`:

- **`sqlite.append-one-batch` went from 1.32× to 1.98×** (83.3 ms to
  57.2 ms; on the Linux CI runners from 0.91–0.94× to 1.95–2.07×, CI run
  38249569895, three interleaved repetitions on each of two runners). Each
  change was measured on its own here, A/B against the others, on this row
  (medians of interleaved runs):

  | Change | Row before → after | Kept |
  |---|---|---|
  | A batch's payloads encoded into one growing buffer (petrus-json's `dumpsMany`, which answers what `traverse dumps` answers) instead of a 2 000-byte buffer and an exact-size copy per record | 69.0 → 59.3 ms (−14%) | yes |
  | Text parameters bound straight from the `Text`'s UTF-8 array (copied by SQLite, `SQLITE_TRANSIENT`, as CPython binds a `str`) instead of through direct-sqlite's pinned copy, inside petrus-sqlite's `execute`, which still checks the parameter count | 73.5 → 69.0 ms, or 61.8 → 59.3 ms with `dumpsMany` (−4 to −6%) | yes |
  | The event identities spelled into one reused buffer, and each row's values bound without an `SQLData` list | 59.3 → 57.7 ms (−2.7%) | no: it needed a mutable buffer and an unchecked positional binder in the store, and the row is well ahead without it |

  The SQL, the bound values and the stored bytes are unchanged (the
  interop suites compare them with the reference's).
- **`sqlite.append-per-record` is timed with the twin's protocol**
  (`Petrus.TestSupport.BenchTwin`): one warm-up run, then the median of 3
  runs, as `python_bench.py` times it, so both sides are now measured the
  same way. This is a correction of the measurement, not a speed-up. The
  row is 2 000 fsynced commits; strace on Linux and a system-call count on
  macOS show both sides making the same calls (a plain `fsync` per commit
  on both), with the Haskell side spending less CPU around them.
  tasty-bench's mean took in every slow file-system period, which the
  twin's median of 3 leaves out, and the Python twin's own mean sits 9%
  (here) to 11–16% (Linux CI) above its median. Timed alike, the row is
  level within the file system's noise: 1.02× in that run (0.99× in the
  closest repetition), 1.15× in a run an hour earlier at `e113a93`; each
  side's figure swings by 10–15% between repetitions. The busy timeout,
  now set through `sqlite3_busy_timeout` (petrus-sqlite's DIVERGENCES),
  saves a statement per connection, not per commit.
- **The bench runs with the RTS defaults** (`-rtsopts` only), as the
  executables that use these stores do (`hamsterdan-host` sets no `-A`),
  instead of the `-with-rtsopts=-A32m` most benches in this repository
  use. A 32 MB allocation area made the allocation-bound rows slower here:
  interleaved, `store.in-memory-append` ran at 306 µs with `-A32m` and
  246 µs with the default `-A4m`, and the loads and resumes 10–15% slower;
  the fsync-bound rows did not move (`sqlite.append-per-record` 79.3 ms
  with `-A32m` against 78.0 ms, medians of six interleaved runs). That is
  most of the move of `store.in-memory-append` from 1.38× to 1.70×, and of
  the loads and resumes. On the Linux CI runners (run 38249569895) the
  difference is larger: `store.in-memory-append` 1.66–1.68× with the
  defaults against 1.05–1.07× with `-A32m` (0.83× in the closest
  repetition), where `scripts/bench-gate` had failed it at 0.95× and 0.87×
  (run 38242016720).

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `sqlite.append-per-record` | 83.4 ms | 94.6 ms | 1.13× | 1.10× | 5 of 5 | 79.2 ms, 83.4 ms, 83.6 ms, 87.5 ms, 80.7 ms | 91.8 ms, 93 ms, 99.5 ms, 95.8 ms, 94.6 ms |
| `jsonl.append-one-batch` | 21.5 ms | 61.6 ms | 2.87× | 2.32× | 5 of 5 | 26.6 ms, 21.4 ms, 21.5 ms, 21.5 ms, 21.4 ms | 61.6 ms, 61.6 ms, 62.4 ms, 68.7 ms, 61.5 ms |
| `jsonl.append-per-record` | 50.5 ms | 66.4 ms | 1.31× | 1.16× | 5 of 5 | 57.2 ms, 50 ms, 53.4 ms, 50.2 ms, 50.5 ms | 66.6 ms, 70.7 ms, 65 ms, 66.4 ms, 65.2 ms |
| `jsonl.load` | 27.2 ms | 94.9 ms | 3.49× | 3.36× | 5 of 5 | 27.2 ms, 27.5 ms, 27.1 ms, 28 ms, 27.2 ms | 94.9 ms, 94.9 ms, 99.2 ms, 94.3 ms, 96 ms |
| `jsonl.resume` | 368 ms | 7.12 s | 19.36× | 19.24× | 5 of 5 | 368 ms, 370 ms, 368 ms, 360 ms, 367 ms | 7.18 s, 7.12 s, 7.11 s, 7.12 s, 7.11 s |
| `sqlite.append-one-batch` | 63.9 ms | 126 ms | 1.96× | 1.73× | 5 of 5 | 64.1 ms, 63.2 ms, 63.4 ms, 63.9 ms, 64.8 ms | 111 ms, 112 ms, 127 ms, 129 ms, 126 ms |
| `sqlite.append-batches-of-8` | 26.4 ms | 38.8 ms | 1.47× | 1.38× | 5 of 5 | 25.1 ms, 26.5 ms, 26.1 ms, 26.4 ms, 26.7 ms | 35.9 ms, 36.5 ms, 38.8 ms, 39.5 ms, 38.8 ms |
| `sqlite.load` | 42.2 ms | 105 ms | 2.49× | 2.49× | 5 of 5 | 42.2 ms, 42.2 ms, 42.2 ms, 42.4 ms, 42.2 ms | 105 ms, 106 ms, 105 ms, 106 ms, 105 ms |
| `sqlite.resume` | 380 ms | 7.14 s | 18.81× | 18.65× | 5 of 5 | 378 ms, 380 ms, 380 ms, 380 ms, 383 ms | 7.18 s, 7.15 s, 7.14 s, 7.14 s, 7.14 s |
| `sqlite.terminal-resend-ack` | 6.68 ms | 1.12 s | 167.59× | 163.55× | 5 of 5 | 6.68 ms, 6.72 ms, 6.86 ms, 6.6 ms, 6.61 ms | 1.13 s, 1.12 s, 1.12 s, 1.12 s, 1.12 s |
| `diagnostic.encode-payload` | 19.9 ms | — | — | — | — | 20.3 ms, 19.9 ms, 19.8 ms, 19.7 ms, 20.4 ms |  |
| `diagnostic.decode-lines` | 26.9 ms | — | — | — | — | 27 ms, 26.7 ms, 26.9 ms, 26.9 ms, 27 ms |  |
| `store.in-memory-append` | 247 µs | 422 µs | 1.71× | 1.68× | 5 of 5 | 251 µs, 246 µs, 247 µs, 246 µs, 247 µs | 420 µs, 418 µs, 423 µs, 422 µs, 428 µs |
| `store.in-memory-records` | 3.72 ns | 40.5 µs | 10884.58× | 9870.06× | 5 of 5 | 3.74 ns, 3.58 ns, 3.72 ns, 3.73 ns, 3.62 ns | 44.7 µs, 40.5 µs, 36.7 µs, 40 µs, 45.7 µs |
| `store.jsonl-records` | 3.48 ns | 44.4 µs | 12747.77× | 12072.47× | 5 of 5 | 3.58 ns, 3.34 ns, 3.57 ns, 3.48 ns, 3.42 ns | 44.4 µs, 44.5 µs, 43.1 µs, 44.1 µs, 44.4 µs |
| `store.in-memory-iterate` | 23 µs | 209 µs | 9.07× | 9.05× | 5 of 5 | 23 µs, 23.1 µs, 22.9 µs, 22.9 µs, 23 µs | 208 µs, 209 µs, 208 µs, 209 µs, 210 µs |
| `store.in-memory-records-list` | 35.2 µs | — | — | — | — | 35.5 µs, 34.8 µs, 35.4 µs, 34.6 µs, 35.2 µs |  |

### Since these figures (2026-10-12, afternoon)

Two low-level changes were measured again against the plain code, each
binary run five times, interleaved and alternating which goes first
(`-p append --stdev 5 +RTS -M2G`), on the Apple M4 at a load average of
4.4–8.2 (other agents' builds). Medians of the tasty-bench means:

- **The direct text bind.** With direct-sqlite's `bind` instead,
  `sqlite.append-one-batch` read 77.4 ms against 76.6 ms (per repetition
  67.3, 72.8, 81.3, 77.4, 83.7 ms against 71.1, 87.8, 79.0, 76.6, 73.7 ms)
  and `sqlite.append-batches-of-8` 31.9 ms against 31.5 ms: within this
  machine's noise (the JSONL append rows, which neither change touches,
  moved by 6–10% between the two binaries in the same runs). The bind
  stays for petrus-sqlite's gated `tx.immediate-insert-100` row (see that
  package's bench/RESULTS.md).
- **The compare-and-swap append stays.** With `atomicModifyIORef'` in
  place of `Petrus.Impetus.HistoryStore`'s `casMutVar#` loop,
  `store.in-memory-append` took 520 µs (519.7, 518.0, 539.0, 545.7,
  478.7 µs) against 295 µs (266.1, 295.0, 332.7, 314.3, 284.4 µs), behind
  the reference's 422 µs, so the loop is kept, with this figure beside it.

## Results

<!-- parity: rows below 1.0× belong to "History stores: memory", "History stores: SQLite, and the SQLite writer fence" -->

The three append rows of this table come from the seven-repetition run in "Rerun of the append
rows" below; the other rows, and the rounds listed under the table, from the earlier rounds.

<!-- bench: superseded -->

| workload | size | Python | Haskell | speed-up |
| --- | --- | ---: | ---: | ---: |
| JSONL append, one batch (encode + open/write/close) | 20 002 records, 2.8 MB | 61.0 ms | 41.8 ms | 1.46× |
| JSONL append, one record per append (2 000 open/write/close) | 2 000 records | 69.8 ms | 58.9 ms | 1.18× |
| JSONL load (open: read + decode every line into the mirror) | 20 002 records | 96.3 ms | 30.9 ms | 3.1× |
| JSONL resume (load + the Instance's validating replay) | 20 002 records | 7 304 ms | 486 ms | 15× |
| in-memory append, one record at a time | 20 002 records | 0.415 ms | 0.329 ms | 1.26× |
| in-memory `records` (snapshot + length) | 20 002 records | 42.5 µs | 4.98 ns | ~8 500× |
| JSONL `records` (snapshot + length) | 20 002 records | 45 µs | 4.93 ns | ~9 000× |
| in-memory iterate (count every record) | 20 002 records | 217 µs | 24.7 µs | 8.8× |

The rounds, Python / Haskell:
- JSONL append, one batch: 63.5 / 45.7, 63.1 / 48.2, 62.7 / 48.9,
  65.4 / 53.3 ms;
- JSONL append, one record per append: 71.0 / 63.3, 73.6 / 60.0,
  67.8 / 62.1, 74.5 / 85.6, then 68.4 / 60.1, 67.1 / 61.8, 73.4 / 83.9 ms;
- JSONL load: 94.7 / 29.4, 96.0 / 28.8, 96.5 / 32.4, 101.3 / 36.5 ms;
- JSONL resume: 7 329 / 451, 7 789 / 479, 7 181 / 492, 7 279 / 577 ms;
- in-memory append: 0.435 / 0.484, 0.414 / 0.420, 0.446 / 0.528,
  0.455 / 0.424, then 0.421 / 0.445, 0.456 / 0.441, 0.429 / 0.463 ms.

**In-memory append is now faster than Python, at 1.07×.** It was level
(0.98×, Haskell ahead in two of seven rounds) while the append went through
`atomicModifyIORef'_`. That builds a selector thunk and a pair for every
append, which the later reads then force. The append is now a
compare-and-swap loop on the `IORef`'s `MutVar#` that installs the
already-evaluated new `Seq`. It stays atomic, as `atomicModifyIORef'` was.
On this row alone the new append took 354–365 µs against 409–445 µs for the
old one, run back to back. The five rounds of the later run, Python /
Haskell: 0.438 / 0.411, 0.416 / 0.328, 0.440 / 0.406, 0.427 / 0.485 and
0.450 / 0.486 ms. Haskell was ahead in three.

There are also three Haskell-only rows (medians of the four rounds):

- `store / in-memory-records-list` (42.6 µs) materializes `records` as a list.
  It is the closest twin of Python's `tuple(self._records)` copy.
- `diagnostic / encode-payload` (45.1 ms) is the JSONL write path's encoder
  alone, without file IO.
- `diagnostic / decode-lines` (32.0 ms) is the JSONL read path's decoder
  alone, without file IO.

## Notes

- **Durability posture.** Both sides use the reference's default, which is
  crash-durable: each batch opens the file for appending, writes, and closes
  it, with no fsync and no lock. `Durability = PowerFailure` opts into an
  fsync per batch (and of the parent directory on creation). It is not
  benchmarked because the reference has no such mode.
- **Snapshots are O(1).** Both stores keep their mirror as a persistent
  `Seq Record` behind one `IORef`. A read hands out the current value: no
  copy, no lock. Python's `records` copies the list into a tuple on every
  call.
- **The JSONL write encodes each line in one pass.** `encodePayload`
  encodes each record with petrus-json's `dumps` (`allowNan = False`),
  which writes the bytes and refuses a non-finite number in the same pass,
  at the same first value CPython's `json.dumps` refuses; the lines are joined
  into one `ByteString`, written with one `write`. The encoder alone
  (`diagnostic.encode-payload`) took about 85 ms when every record's
  `Builder` was held until the whole batch had been checked (the slowdown
  the final audit found at `e47ce6b`, FA-V-1), about 45 ms with a refusal
  check followed by one streamed `Builder` (as at `9728cf6`), and about
  22 ms this way.
- **In-memory append.** The kernel's `inMemoryHistoryStore` is a direct
  `IORef (Seq Record)` with a strict compare-and-swap snoc. It has a
  single-record fast path, which is what `append` produces. It no longer goes
  through `mirroredHistoryStore`'s admission bookkeeping, which an in-memory
  store that admits everything does not need. That change is minimal and
  additive in `petrus-impetus`, and its semantics are unchanged.
- **JSONL load.** Almost all of it is the kernel's record decoder
  (`decode-lines`). That decoder has become about 3× faster since the figures
  committed before these (`decode-lines` 94.8 ms then, 32.0 ms now), and the
  row went from 1.13× to 3.1×; the store calls the kernel decoder, so it
  carried over unchanged.
- **Resume** is dominated by the Instance's validating replay. The kernel
  replays about 14× faster than the reference (see
  `packages/petrus-impetus/bench/RESULTS.md`).

## SQLite store

The `sqlite` group times `SqliteHistoryStore` (`Petrus.HistoryStore.Sqlite`)
over the same 20 002-record History. Both sides use the reference's
connection posture: `busy_timeout=5000`, `foreign_keys=ON`,
`synchronous=FULL`, `journal_mode=WAL`, and one fsynced `BEGIN IMMEDIATE`
transaction per batch.

The workloads:

- **append-one-batch.** Open a fresh database, `extend` with all 20 002
  records in one batch, `count`, close, and delete the file with its `-wal`
  and `-shm` side files.
- **append-per-record.** The same with the first 2 000 records, one `extend`
  each, so 2 000 fsynced transactions.
- **append-batches-of-8.** The first 2 000 records in batches of 8, so 250
  transactions.
- **load.** Open the full database (connect, pragmas, schema check under
  `BEGIN IMMEDIATE`, read and decode every row into the mirror), `count`,
  close.
- **resume.** `load`, then the Instance's validating replay.
- **terminal-resend-ack.** 1 000 re-sends of the History's first
  `FiringCompleted` to a store already open over the full database. Each
  re-send hits the `ON CONFLICT DO NOTHING` path, finds no row by event id,
  and is acknowledged by the terminal-family lookup.

### How to rerun

The rerun block above covers these rows too. To run only the SQLite rows on the Haskell side:

    scripts/bench-run petrus-history-store -p sqlite +RTS -M2G -RTS

### Results

The three append rows come from the seven-repetition run (see "Rerun
of the append rows" below); the rounds listed after the table are the earlier ones. The other rows come from the same rounds as the
rows above.

<!-- bench: superseded -->

| workload | size | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: |
| append-one-batch (one fsynced transaction) | 20 002 records | 112 ms | 85.6 ms | 1.31× |
| append-per-record (2 000 fsynced transactions) | 2 000 records | 95.8 ms | 87.8 ms | 1.09× |
| append-batches-of-8 (250 fsynced transactions) | 2 000 records | 35.4 ms | 27.3 ms | 1.29× |
| load (open + decode every row) | 20 002 records | 110 ms | 47.9 ms | 2.3× |
| resume (load + validating replay) | 20 002 records | 7 617 ms | 498 ms | 15× |
| terminal-resend-ack (1 000 re-sends) | 20 002 records | 1 241 ms | 7.96 ms | 156× |

The rounds, Python / Haskell:
- append-one-batch: 124.7 / 102, 178.4 / 154, 135.9 / 125, 165.3 / 133 ms;
- append-per-record: 138.1 / 103, 117.3 / 158, 102.5 / 112, 103.5 / 113,
  then 104.6 / 129, 102.2 / 140, 114.3 / 181 ms;
- append-batches-of-8: 37.4 / 31.4, 51.5 / 48.8, 40.7 / 61.4, 40.2 / 72.5,
  then 53.6 / 36.6, 40.1 / 42.4, 44.9 / 40.1 ms;
- load: 122.4 / 45.0, 111.1 / 44.6, 107.5 / 50.7, 108.3 / 62.1 ms;
- resume: 8 493 / 481, 7 301 / 457, 7 646 / 514, 7 588 / 674 ms;
- terminal-resend-ack: 1 233 / 8.04, 1 141 / 7.62, 1 250 / 7.87,
  1 383 / 9.34 ms.

**The fsync-bound appends are no longer slower.** In the run of
2026-10-10, `append-per-record` read 0.81× and `append-batches-of-8` 0.96×
(the rounds above). Both rows are 2 000 and 250 fsynced commits. The search
for the gap, measured rather than assumed:

- **SQLite build and durability: not the cause.** Both sides commit with
  plain `fsync` under `synchronous=FULL` in WAL mode, never `F_FULLFSYNC`.
  A probe of 2 000 single-insert commits took the same time, within noise,
  on direct-sqlite's bundled 3.45.0, on the system SQLite (direct-sqlite's
  `systemlib` flag) and from CPython with 3.53.4. So the bundled build
  stays.
- **Transaction control: a small saving.** `petrus-sqlite` ran
  `BEGIN IMMEDIATE`, `COMMIT` and `ROLLBACK` through `sqlite3_exec`, which
  parses and compiles the statement on every transaction. CPython runs
  `execute("BEGIN IMMEDIATE")` from its statement cache. These statements
  now go through the connection's statement cache too, with the same safe
  step (a `BEGIN IMMEDIATE` can wait on the busy handler, a `COMMIT`
  syncs). The SQL, the durability and the error texts are unchanged. The
  saving is under a microsecond per transaction, far less than these rows'
  swings.
- **What is left is the machine.** The raw commit probe puts Haskell's
  fsynced commit level with CPython's, and the store adds little to it. The
  0.81× of the earlier run is best read as file-system load from other work
  on the shared machine. These rows swing by 20–50% between rounds.

The five rounds of the later run, Python / Haskell:
- append-one-batch: 118 / 107, 118 / 89.7, 127 / 92.1, 121 / 100,
  148 / 107 ms;
- append-per-record: 102 / 102, 102 / 90.0, 107 / 95.6, 126 / 154,
  118 / 105 ms;
- append-batches-of-8: 36.1 / 53.6, 34.2 / 26.7, 36.6 / 29.5, 38.8 / 35.1,
  45.4 / 33.1 ms.

Both rows still swing with the machine's file-system load (each lost one
round). The medians are ahead, and Haskell was ahead or level in four of
the five rounds of each.

### Notes

- **append-one-batch.** It is about half encoding and half
  inserting on both sides. The phase split, measured by a probe:
  - Haskell: about 50 ms to encode the 20 002 payloads with `petrus-json`'s
    `dumps`, and about 50 ms for the 20 002 bound inserts and the commit;
  - Python: about 63 ms in `_encode` (C `json.dumps`), and the rest in its
    per-row `execute` inserts and the commit.

  The insert loop is tail-recursive and the load is a strict fold. An earlier
  non-tail-recursive loop (`(x :) <$> go rest`) cost about 80 ms on this row
  and ran it at 194 ms. Batching several rows into one multi-row `INSERT`
  was tried and gave nothing, so it was dropped (it would also change the
  SQL). The split above predates the 2026-10-12 write path ("Current
  figures"): encoding the batch into one buffer and binding text without
  copies took the row from about 83 ms to 57 ms here. Since then SQLite itself is about 70% of the row in
  a profile, and the `recorded_at` default's `strftime`, which both sides
  run per row, about 14%.
- **terminal-resend-ack is fast in Haskell for a reason outside the port.**
  Both sides run the same statement to find an acknowledged terminal
  (`SELECT event_id, record_type, payload FROM impetus_history_events WHERE
  instance = ? AND occurrence = ? AND record_type IN (?, ?)`) and read its
  first row. SQLite answers it by walking the instance's rows. CPython's
  `sqlite3` cursor steps the statement once more to pre-fetch the next row,
  so its `fetchone` walks the rest of the instance's events, about 1.1 ms per
  call at 20 002 rows. The Haskell
  port stops after the first row. The answers are identical (the interop
  suite checks the acknowledgement both ways), only the extra scan is gone.
- **The SQLite builds differ.** On raw inserts the two are comparable: a probe
  of 20 000 small bound inserts in one transaction took 34–37 ms with
  direct-sqlite's 3.45.0 and 41–46 ms with CPython's 3.53.4.
- **resume** is dominated, as for JSONL, by the kernel's validating replay.

## Rerun of the append rows

The four append rows of the first table and the three SQLite append rows
come from seven interleaved repetitions on 2026-10-11, 07:33–07:46 local
(UTC-3), at commit `fc77e8d`, with the 1-minute load average at 1.79–2.54:

    scripts/bench-compare petrus-history-store 7 --pattern append

The pattern limits the Haskell side to the append rows; `python_bench.py`
runs in full and prints `name,nanoseconds` lines for `bench-compare`. Each
figure is the median of the seven repetitions; bench-compare starts the
benchmark executable directly. Haskell was ahead in every repetition of
every row.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition |
|---|---:|---:|---:|---:|
| `jsonl.append-one-batch` | 41.8 ms | 61.0 ms | 1.46× | 1.43× |
| `jsonl.append-per-record` | 58.9 ms | 69.8 ms | 1.18× | 1.08× |
| `sqlite.append-one-batch` | 85.6 ms | 112 ms | 1.31× | 1.29× |
| `sqlite.append-per-record` | 87.8 ms | 95.8 ms | 1.09× | 1.06× |
| `sqlite.append-batches-of-8` | 27.3 ms | 35.4 ms | 1.29× | 1.17× |
| `store.in-memory-append` | 329 µs | 415 µs | 1.26× | 1.22× |

`jsonl.append-per-record`, repetition by repetition (Haskell / Python):
58.3 / 66.9, 58.4 / 69.8, 58.9 / 69.9, 58.7 / 70.4, 62.6 / 67.5,
59.5 / 69.8 and 59.4 / 66.7 ms. The 0.87× of the earlier run below came from
the machine's load (3.6–10.1): on a quiet machine the row is 1.18×, with no
code change.

### The run of 2026-10-11, 02:28–02:42

<!-- bench: superseded -->


The in-memory append and the three SQLite append rows above come from one
interleaved run on 2026-10-11, 02:28–02:42 local (UTC-3), at commit `3f31d2e`
(the CAS append and the cached transaction control), load average 3.6–10.1:

    scripts/bench-compare petrus-history-store 5 --pattern append

The pattern limits the Haskell side to the append rows; `python_bench.py`
runs in full and prints `name,nanoseconds` lines for `bench-compare`. Each
figure is the median of the five rounds. The same run also timed the JSONL
appends. The one-batch append was 1.37× (46.4 ms against 63.3 ms). The
per-record append's medians read 0.87× (87.6 ms against 76.3 ms), but
Haskell was ahead in four of the five rounds: 87.6 / 105, 63.3 / 73.7,
71.2 / 76.3, 112 / 75.1 and 89.5 / 94.9 ms (Haskell / Python). That row
opens, writes and closes a file 2 000 times without fsync, and it swung
the most with the load. The JSONL rows in the first table keep the
seven-round figures.
