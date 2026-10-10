# History store benchmarks: Haskell vs the Python reference

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` build the same
History: 20 002 records from a drained 4 000-token FIFO. They time the same
workloads over it. Each Python line prints a result size (a record count),
and the Haskell side computes the same number.

## How to rerun

From the repository root:

    cabal bench petrus-history-store

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python ../../packages/petrus-history-store/bench/python_bench.py

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median of
3–20 runs after one warm-up. Both sides were run back to back on 2026-10-10 on
an Apple M4 with 24 GB of memory, using GHC 9.10.3 (`-O2`, `-A32m`) and
CPython 3.14.6. The reference was pinned at `upstream/petrus` 3f85fc2.

The machine was shared and under load (load average 3–5) during these runs,
so expect ±10% noise on the millisecond rows.

## Results

| workload | size | Python | Haskell | speed-up |
| --- | --- | ---: | ---: | ---: |
| JSONL append, one batch (encode + open/write/close) | 20 002 records, 2.8 MB | 62.1 ms | 33.9 ms | 1.8× |
| JSONL append, one record per append (2 000 open/write/close) | 2 000 records | 67.1 ms | 58.6 ms | 1.15× |
| JSONL load (open: read + decode every line into the mirror) | 20 002 records | 98.0 ms | 87.0 ms | 1.13× |
| JSONL resume (load + the Instance's validating replay) | 20 002 records | 7 552 ms | 555 ms | 13.6× |
| in-memory append, one record at a time | 20 002 records | 0.469 ms | 0.360 ms | 1.3× |
| in-memory `records` (snapshot + length) | 20 002 records | 45 µs | 4.4 ns | ~10 000× |
| JSONL `records` (snapshot + length) | 20 002 records | 44 µs | 5.3 ns | ~8 000× |
| in-memory iterate (count every record) | 20 002 records | 210 µs | 26.4 µs | 8× |

There are also three Haskell-only rows:

- `store / in-memory-records-list` (45.8 µs) materializes `records` as a list.
  It is the closest twin of Python's `tuple(self._records)` copy.
- `diagnostic / encode-payload` (43.6 ms) is the JSONL write path's encoder
  alone, without file IO.
- `diagnostic / decode-lines` (94.8 ms) is the JSONL read path's decoder
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
- **JSONL load is the closest row.** Almost all of it is the kernel's record
  decoder (`decode-lines`, about 95 ms). CPython's `json.loads` is C, and the
  pure-Haskell reader plus `decodeRecord` only just beat it. A separate kernel
  branch that speeds up History decode about 2.5× (`154a44d`, not merged at
  the time of writing) would carry over to this row and to `resume`
  unchanged, because the store calls the kernel decoder.
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

From the repository root (the second command runs only the SQLite rows):

    cabal bench petrus-history-store
    cabal bench petrus-history-store --benchmark-options='-p sqlite +RTS -M2G -RTS'

Python, from `upstream/petrus` as above:

    .venv/bin/python ../../packages/petrus-history-store/bench/python_bench.py

The two sides ran interleaved (Python, Haskell, Python, ...) for three rounds
on 2026-10-10, on the machine and toolchains named above. The Haskell side is
direct-sqlite 2.3.29, which bundles SQLite 3.45.0, and CPython 3.14.6 links
SQLite 3.53.4. The load average was 2.3–2.8 throughout.

### Results

Each cell is the median of the three rounds. A round is a tasty-bench mean
for Haskell, and the median of 3–5 runs after a warm-up for Python.

| workload | size | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: |
| append-one-batch (one fsynced transaction) | 20 002 records | 112 ms | 108 ms | 1.04× |
| append-per-record (2 000 fsynced transactions) | 2 000 records | 102 ms | 72.5 ms | 1.4× |
| append-batches-of-8 (250 fsynced transactions) | 2 000 records | 31.2 ms | 28.2 ms | 1.1× |
| load (open + decode every row) | 20 002 records | 109 ms | 46.1 ms | 2.4× |
| resume (load + validating replay) | 20 002 records | 7 249 ms | 465 ms | 15.6× |
| terminal-resend-ack (1 000 re-sends) | 20 002 records | 1 139 ms | 8.42 ms | 135× |

The individual rounds, Python / Haskell:

- append-one-batch: 115.0 / 108, 112.3 / 106, 111.3 / 108 ms;
- append-per-record: 92.6 / 72.5, 102.4 / 71.5, 106.5 / 76.1 ms;
- append-batches-of-8: 31.2 / 28.2, 32.5 / 28.1, 30.8 / 28.2 ms;
- load: 110.3 / 48.3, 106.2 / 46.1, 109.0 / 46.0 ms;
- resume: 7 310 / 465, 7 208 / 461, 7 249 / 470 ms;
- terminal-resend-ack: 1 216 / 8.34, 1 139 / 8.45, 1 133 / 8.42 ms.

### Notes

- **append-one-batch is the closest row.** It is about half encoding and half
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
