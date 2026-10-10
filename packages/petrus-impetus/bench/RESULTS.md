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
| candidates / wide fan-in (6 places × 3 tokens) | 729 bindings | 0.698 ms | 23.4 µs | 30× |
| candidates / long FIFO (10 000 tokens) | 10 000 bindings | 15.9 ms | 1.51 ms | 10.5× |
| candidates / weight-3 arc (30 tokens) | 4 060 bindings | 5.19 ms | 0.279 ms | 19× |
| Instance run / wide fan-out (200 tokens → 50 places) | 200 firings, 10 000 tokens | 2 433 ms | 25.0 ms | 97× |
| Instance run / long FIFO (1 000 tokens) | 1 000 firings | 1 282 ms | 71.4 ms | 18× |
| History encode (records → JSON text) | 20 002 records, 2.8 MB | 47.2 ms | 29.3 ms | 1.6× |
| History decode (JSON text → records) | 20 002 records | 119.3 ms | 47.9 ms | 2.5× |
| History replay → marking | 20 002 records | 4 079 ms | 237 ms | 17× |
| Net definition v3 serialize (200-place chain) | 110 kB | 10.5 ms | 2.49 ms | 4.2× |
| Net definition v3 parse (200-place chain) | 200 places | 11.8 ms | 5.30 ms | 2.2× |

These numbers are from a rerun on 2026-10-10, after the History decode work
described in the notes. The machine was busy during the rerun (load average
5–8 on 10 cores), so both sides came out a few percent slower than in the
first run. Only the decode row changed because of code: it was **138 ms**
(Python 110.5 ms, 0.80×) before. Across three Haskell runs it measured
42.9–47.9 ms; the table shows the slowest.

There are also three Haskell-only diagnostic rows:

- `history / dumps-only` (28.4 ms) is the JSON writer alone, over
  already-encoded record values.
- `history / parse-only` (28.2 ms) is the JSON reader alone. It now forces
  every node of the parsed document. The old row (38.6 ms) forced only the
  outer structure, so number tokens were never converted and its time was
  understated.
- `history / records-only` (14.0 ms) is the record decoder alone, over
  already-parsed values.

The decode row is roughly parse-only plus records-only.

## Notes

- **Instance runs.** Each run is the whole door: candidate enumeration, the
  begin/complete firing, the canonical record batch, the durable append to the
  in-memory store, and the mirror update. Python recomputes candidates from
  dict-based queues on every step. The Haskell Instance keeps its queues and
  entry instants in persistent maps and appends through one `IORef` write per
  door.
- **History replay.** The reference replays the whole History through its
  validating queue fold. The Haskell fold applies the same validations over
  `OMap` queues and is about 17–18× faster.
- **History decode was 138 ms (0.80× Python) before the 2026-10-10 change.**
  It is now about 48 ms (2.5×). The same records are accepted and refused,
  with the same error texts. In `petrus-json`'s reader:
  - Each step returns an unboxed `Done value offset | Failed message`
    instead of `Either String (value, offset)`.
  - Integer tokens of up to 18 digits are summed directly from the bytes.
  - Short decimals (at most 15 significant digits, |scale| ≤ 22) take
    Clinger's fast path: one exact multiplication or division, which rounds
    to the same double as the exact conversion. Every other float takes the
    old exact path.
  - Escape-free all-ASCII strings are sliced without UTF-8 validation.
  - Objects under 16 members check duplicates with a list scan instead of
    building a `Set`.

  In the schema-5 codec:
  - Each record layout's field converters and builder are looked up once
    per record, not by name per field.
  - A payload whose members are in the canonical order skips the
    unexpected/missing-argument scan. That scan cannot fail on such a
    payload.
  - The canonical-spelling check still requires the re-encoded record to
    equal the payload under the reference's value equality. It now compares
    member by member when the keys line up. Both sides have unique keys
    there, so this is the same as the mapping comparison. Any misaligned
    key falls back to the full comparison.

  The old reader and the old codec are kept as test oracles:
  - `petrus-json/test/Petrus/Json/ReferenceParse.hs` checks the reader on
    encoder output, on mutated documents, on number spellings, and on byte
    soup, under four option sets.
  - `petrus-impetus/test/Petrus/Impetus/ReferenceCodec.hs` checks the
    codec on 20 000 mutated payloads per run.

  Property tests require identical values or identical refusal texts from
  both versions.
- **History encode was 134 ms before this package's change to
  `petrus-json`.** The writer now copies runs of characters that need no
  escaping as whole UTF-8 slices, and decides the non-finite refusal before
  it builds instead of threading `Either` through every node. The output
  bytes are unchanged.
