# Kernel benchmarks: Haskell vs the Python reference

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` build the same
workloads: the same nets, markings, and sizes. Each Python line also prints a
result size (bindings, firings, records, bytes), which is how you can see that
the two sides do the same work.

## How to rerun

From the repository root:

    cabal bench petrus-impetus

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python ../../packages/petrus-impetus/bench/python_bench.py

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median of
5–20 runs after one warm-up. Both were run on 2026-10-10 on an Apple M4 with
24 GB of memory, using GHC 9.10.3 (`-O2`) and CPython 3.14.6. The reference
was pinned at `upstream/petrus` 3f85fc2.

## Results

| workload | size | Python | Haskell | speed-up |
| --- | --- | ---: | ---: | ---: |
| candidates / wide fan-in (6 places × 3 tokens) | 729 bindings | 0.683 ms | 21.6 µs | 32× |
| candidates / long FIFO (10 000 tokens) | 10 000 bindings | 14.7 ms | 1.51 ms | 9.7× |
| candidates / weight-3 arc (30 tokens) | 4 060 bindings | 5.14 ms | 0.283 ms | 18× |
| Instance run / wide fan-out (200 tokens → 50 places) | 200 firings, 10 000 tokens | 2 153 ms | 23.0 ms | 94× |
| Instance run / long FIFO (1 000 tokens) | 1 000 firings | 1 184 ms | 67.9 ms | 17× |
| History encode (records → JSON text) | 20 002 records, 2.8 MB | 47.1 ms | 28.3 ms | 1.7× |
| History decode (JSON text → records) | 20 002 records | 110.5 ms | 138 ms | 0.80× |
| History replay → marking | 20 002 records | 3 921 ms | 216 ms | 18× |
| Net definition v3 serialize (200-place chain) | 110 kB | 9.96 ms | 2.14 ms | 4.7× |
| Net definition v3 parse (200-place chain) | 200 places | 11.2 ms | 4.48 ms | 2.5× |

There are also two Haskell-only diagnostic rows:

- `history / dumps-only` (28.5 ms) is the JSON writer alone, over
  already-encoded record values.
- `history / parse-only` (38.6 ms) is the JSON reader alone.

They split the encode and decode rows into their parts.

## Notes

- **Instance runs.** Each run is the whole door: candidate enumeration, the
  begin/complete firing, the canonical record batch, the durable append to the
  in-memory store, and the mirror update. Python recomputes candidates from
  dict-based queues on every step. The Haskell Instance keeps its queues and
  entry instants in persistent maps and appends through one `IORef` write per
  door.
- **History replay.** The reference replays the whole History through its
  validating queue fold. The Haskell fold applies the same validations over
  `OMap` queues and is about 18× faster.
- **History decode is about 1.25× slower than Python.** About 39 ms of the
  138 ms is the pure-Haskell JSON reader; CPython's `json.loads` is C. The
  rest is the strict decoder, which matches the reference step for step:
  - it converts each field by name, then runs the constructor's argument
    checks and record invariants;
  - it re-encodes the record and compares it with the payload, to refuse any
    non-canonical spelling.

  This is the one workload where the port is slower. It is a candidate for a
  fused reader.
- **History encode was 134 ms before this package's change to
  `petrus-json`.** The writer now copies runs of characters that need no
  escaping as whole UTF-8 slices, and decides the non-finite refusal before
  it builds instead of threading `Either` through every node. The output
  bytes are unchanged.
