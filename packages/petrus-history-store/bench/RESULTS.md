# History store benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 64cfa539be134207 at 5a73d7a7f019 -->

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
WallTime` in `bench/Main.hs`), `--stdev 5`, `+RTS -M2G`. Python numbers are the
median of 3–20 runs after one warm-up (`time.perf_counter`). Both run on an
Apple M4 with 24 GB of memory, using GHC 9.10.3 (`-O2`, `-A32m`) and CPython
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

Measured on 2026-10-12, 01:24–01:35 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.22–2.54:
five interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-history-store 5

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). `jsonl.append-one-batch` went from 1.46× to 2.95× with the one-pass line encoder (Notes, below), and the `diagnostic.encode-payload` row from about 45 ms to 17 ms. The rows without a Python figure are Haskell-only (described under the first table below). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `jsonl.append-one-batch` | 20.4 ms | 60.1 ms | 2.95× | 2.88× | 20.4 ms, 20.6 ms, 20.2 ms, 20.3 ms, 20.8 ms | 60.5 ms, 60.2 ms, 60.1 ms, 60.1 ms, 59.9 ms |
| `jsonl.append-per-record` | 49.6 ms | 64.5 ms | 1.30× | 1.27× | 50 ms, 49.9 ms, 49.5 ms, 49.6 ms, 49.5 ms | 63.7 ms, 64.5 ms, 66.6 ms, 64.9 ms, 63.5 ms |
| `jsonl.load` | 31.2 ms | 93.8 ms | 3.01× | 2.86× | 31.2 ms, 31 ms, 31.3 ms, 32.8 ms, 31 ms | 96.3 ms, 94 ms, 93.5 ms, 93.6 ms, 93.8 ms |
| `jsonl.resume` | 425 ms | 7.07 s | 16.65× | 16.55× | 428 ms, 424 ms, 425 ms, 427 ms, 425 ms | 7.1 s, 7.06 s, 7.09 s, 7.07 s, 7.07 s |
| `sqlite.append-one-batch` | 83.3 ms | 110 ms | 1.32× | 1.27× | 83.3 ms, 82.4 ms, 83.6 ms, 87.1 ms, 82.4 ms | 110 ms, 110 ms, 111 ms, 110 ms, 110 ms |
| `sqlite.append-per-record` | 82.1 ms | 91.9 ms | 1.12× | 1.09× | 85.3 ms, 83.8 ms, 79.3 ms, 82.1 ms, 79.7 ms | 93.4 ms, 94.5 ms, 88.9 ms, 90 ms, 91.9 ms |
| `sqlite.append-batches-of-8` | 26.2 ms | 29.6 ms | 1.13× | 1.13× | 25.6 ms, 26.3 ms, 25.6 ms, 26.2 ms, 26.8 ms | 29 ms, 29.7 ms, 29.6 ms, 29.5 ms, 33.2 ms |
| `sqlite.load` | 47 ms | 106 ms | 2.25× | 2.19× | 47 ms, 47.1 ms, 46.7 ms, 48.7 ms, 46.6 ms | 106 ms, 106 ms, 106 ms, 107 ms, 105 ms |
| `sqlite.resume` | 452 ms | 7.1 s | 15.72× | 15.68× | 452 ms, 452 ms, 450 ms, 452 ms, 450 ms | 7.09 s, 7.1 s, 7.11 s, 7.11 s, 7.09 s |
| `sqlite.terminal-resend-ack` | 7.03 ms | 1.11 s | 157.80× | 157.30× | 7.03 ms, 6.95 ms, 7.05 ms, 7.03 ms, 6.88 ms | 1.13 s, 1.11 s, 1.11 s, 1.11 s, 1.11 s |
| `diagnostic.encode-payload` | 17 ms | — | — | — | 17.1 ms, 17.1 ms, 17 ms, 17 ms, 17 ms |  |
| `diagnostic.decode-lines` | 30.8 ms | — | — | — | 31.2 ms, 30.7 ms, 30.8 ms, 32.2 ms, 30.6 ms |  |
| `store.in-memory-append` | 305 µs | 414 µs | 1.36× | 1.32× | 315 µs, 305 µs, 305 µs, 305 µs, 307 µs | 414 µs, 405 µs, 415 µs, 428 µs, 412 µs |
| `store.in-memory-records` | 4.52 ns | 43.8 µs | 9697.57× | 7979.23× | 4.67 ns, 4.5 ns, 4.62 ns, 4.52 ns, 4.49 ns | 37.3 µs, 44.8 µs, 44.9 µs, 37 µs, 43.8 µs |
| `store.jsonl-records` | 4.35 ns | 43.8 µs | 10057.67× | 9795.83× | 4.33 ns, 4.35 ns, 4.46 ns, 4.39 ns, 4.31 ns | 43.8 µs, 44.4 µs, 43.7 µs, 43.2 µs, 44.3 µs |
| `store.in-memory-iterate` | 25.8 µs | 210 µs | 8.13× | 7.91× | 25.8 µs, 25.8 µs, 25.7 µs, 26.4 µs, 26.2 µs | 214 µs, 210 µs, 214 µs, 209 µs, 208 µs |
| `store.in-memory-records-list` | 39.7 µs | — | — | — | 40.6 µs, 40.1 µs, 39.5 µs, 39.4 µs, 39.7 µs |  |

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
  at the same first value `dumpsBuilder` would refuse; the lines are joined
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
  and ran it at 194 ms. Batching several rows into one multi-row `INSERT` and
  building every payload into one buffer were both tried and gave nothing,
  so they were dropped.
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
