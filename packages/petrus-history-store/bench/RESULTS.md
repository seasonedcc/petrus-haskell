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
