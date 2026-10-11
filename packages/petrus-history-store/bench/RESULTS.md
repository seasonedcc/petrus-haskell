# History store benchmarks: Haskell vs the Python reference

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` build the same
History: 20 002 records from a drained 4 000-token FIFO. They time the same
workloads over it. Each Python line prints a result size (a record count),
and the Haskell side computes the same number.

## How to rerun

From the repository root (`scripts/bench petrus-history-store` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-history-store --benchmark-options='--stdev 5 +RTS -M2G -RTS'
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
those four rows. The file-system rows (every `jsonl` and `sqlite` append)
swing by 20–50% between rounds on this machine, which is why the closest rows
got more rounds.

## Results

<!-- parity: rows below 1.0× belong to "History stores: memory", "History stores: SQLite, and the SQLite writer fence" -->

| workload | size | Python | Haskell | speed-up |
| --- | --- | ---: | ---: | ---: |
| JSONL append, one batch (encode + open/write/close) | 20 002 records, 2.8 MB | 63.3 ms | 48.6 ms | 1.30× |
| JSONL append, one record per append (2 000 open/write/close) | 2 000 records | 71.0 ms | 62.1 ms | 1.14× |
| JSONL load (open: read + decode every line into the mirror) | 20 002 records | 96.3 ms | 30.9 ms | 3.1× |
| JSONL resume (load + the Instance's validating replay) | 20 002 records | 7 304 ms | 486 ms | 15× |
| in-memory append, one record at a time | 20 002 records | 0.435 ms | 0.445 ms | 0.98× |
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

**In-memory append is level with Python, not faster.** Haskell was ahead in
two of the seven rounds. The figure committed before these, 0.360 ms (1.3×),
was tasty-bench's default CPU time from an earlier run; this workload does
no IO, so the clock alone should not account for the difference, and these
runs did not establish what does.

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
- **The JSONL write is streamed.** `encodePayload` first runs the refusal
  check (non-finite numbers) over every record. Then one `Builder` produces
  the whole payload in a single `ByteString`, which is written with one
  `write`. The earlier per-record `dumps` kept every encoded
  `Json` alive and ran at 80–97 ms.
- **In-memory append.** The kernel's `inMemoryHistoryStore` is a direct
  `IORef (Seq Record)` with an `atomicModifyIORef'_` snoc. It has a
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

    cabal bench -j2 petrus-history-store --benchmark-options='-p sqlite +RTS -M2G -RTS'

### Results

These rows come from the same rounds as the rows above.

| workload | size | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: |
| append-one-batch (one fsynced transaction) | 20 002 records | 151 ms | 129 ms | 1.17× |
| append-per-record (2 000 fsynced transactions) | 2 000 records | 105 ms | 129 ms | 0.81× |
| append-batches-of-8 (250 fsynced transactions) | 2 000 records | 40.7 ms | 42.4 ms | 0.96× |
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

**Two fsync-bound rows are slower than Python in wall-clock time.**
`append-per-record` is 0.81×: Haskell was behind in six of the seven
rounds, and in each of the last three. `append-batches-of-8` is 0.96× and
swings both ways (0.55× to 1.46× per round). Both rows are dominated by
2 000 and 250 fsynced commits through two different SQLite builds. The
figures committed before these timed Haskell in tasty-bench's default CPU
time, which leaves out the time blocked in fsync: 72.5 and 28.2 ms then,
which read as 1.4× and 1.1×. Where the remaining gap comes from (the SQLite
version and its compile options, or the binding's per-statement work) has
not been measured.

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
