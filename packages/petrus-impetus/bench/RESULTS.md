# Kernel benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 24bc95ab03caede2 at 33f3581dd1c5 -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` build the same
workloads: the same nets, markings, and sizes. Each Python line also prints a
result size (bindings, firings, records, bytes), which is how you can see that
the two sides do the same work.

## How to rerun

From the repository root (`scripts/bench petrus-impetus` runs exactly this;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-impetus +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-impetus/bench/python_bench.py)
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median of
5–20 runs after one warm-up. Both were run on 2026-10-10 on an Apple M4 with
24 GB of memory, using GHC 9.10.3 (`-O2`) and CPython 3.14.6. The reference
was pinned at `upstream/petrus` 3f85fc2.

## Current figures

Measured on 2026-10-12, 17:59–18:08 local (UTC-3), at commit `cb654fd`
with the benchmark built `-threaded` (see below), on the Apple M4 (Darwin
arm64) with a 1-minute load average of 1.84–3.69: five interleaved
repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-impetus 5

The benchmark now runs with the RTS defaults, as the executables that run
this code do (no longer `-with-rtsopts=-A32m`; docs/reproducing.md, "The
benchmarks' runtime options"). The rows that build large structures moved
most with it: the candidate rows (`long-fifo` 1.32 to 2.56 ms, `weight-3`
262 to 412 µs) and the parses (`history.parse-only` 24.3 to 31.0 ms,
`net-document.parse` 7.59 to 9.30 ms); the lifecycle, timer, replay and
serialize rows got faster.

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `candidates.wide-fanin` | 21.9 µs | 660 µs | 30.09× | 29.41× | 5 of 5 | 22.3 µs, 21.9 µs, 21.7 µs, 21.8 µs, 22.1 µs | 657 µs, 665 µs, 660 µs, 661 µs, 660 µs |
| `candidates.long-fifo` | 2.56 ms | 13.8 ms | 5.38× | 5.35× | 5 of 5 | 2.56 ms, 2.56 ms, 2.56 ms, 2.55 ms, 2.58 ms | 13.8 ms, 13.7 ms, 13.9 ms, 13.6 ms, 13.8 ms |
| `candidates.weight-3` | 412 µs | 4.78 ms | 11.60× | 11.58× | 5 of 5 | 412 µs, 412 µs, 415 µs, 412 µs, 412 µs | 4.77 ms, 4.77 ms, 4.85 ms, 4.78 ms, 4.83 ms |
| `instance-run.wide-fanout` | 22.7 ms | 1.98 s | 87.55× | 86.98× | 5 of 5 | 22.5 ms, 22.9 ms, 22.7 ms, 22.7 ms, 22.6 ms | 2 s, 1.99 s, 1.98 s, 1.98 s, 1.98 s |
| `instance-run.long-fifo` | 71.2 ms | 1.13 s | 15.88× | 15.83× | 5 of 5 | 71 ms, 71.3 ms, 71.1 ms, 71.2 ms, 71.2 ms | 1.13 s, 1.13 s, 1.14 s, 1.13 s, 1.14 s |
| `history.encode` | 8.12 ms | 39.4 ms | 4.85× | 4.71× | 5 of 5 | 8.2 ms, 8.31 ms, 8.12 ms, 8.09 ms, 8.09 ms | 40.2 ms, 39.1 ms, 39.9 ms, 39.1 ms, 39.4 ms |
| `history.dumps-only` | 7.22 ms | — | — | — | — | 7.43 ms, 7.22 ms, 7.34 ms, 7.19 ms, 7.19 ms |  |
| `history.parse-only` | 31 ms | — | — | — | — | 31.5 ms, 31 ms, 31.1 ms, 30.8 ms, 30.9 ms |  |
| `history.decode` | 45 ms | 87.6 ms | 1.95× | 1.92× | 5 of 5 | 44.9 ms, 45.3 ms, 45.5 ms, 45 ms, 44.9 ms | 87.6 ms, 87.6 ms, 87.5 ms, 89.3 ms, 88.5 ms |
| `history.records-only` | 13.1 ms | — | — | — | — | 13.4 ms, 13.1 ms, 13.2 ms, 12.9 ms, 13 ms |  |
| `history.replay-marking` | 199 ms | 3.46 s | 17.41× | 17.08× | 5 of 5 | 200 ms, 198 ms, 199 ms, 202 ms, 198 ms | 3.47 s, 3.46 s, 3.46 s, 3.46 s, 3.46 s |
| `net-definition.serialize` | 843 µs | 9.34 ms | 11.08× | 10.79× | 5 of 5 | 839 µs, 846 µs, 838 µs, 843 µs, 862 µs | 9.34 ms, 9.31 ms, 9.37 ms, 9.41 ms, 9.3 ms |
| `net-definition.parse` | 5.25 ms | 10.5 ms | 2.01× | 2.00× | 5 of 5 | 5.25 ms, 5.25 ms, 5.17 ms, 5.23 ms, 5.26 ms | 10.6 ms, 10.5 ms, 10.5 ms, 10.6 ms, 10.5 ms |
| `net-definition.compile` | 644 µs | 6.6 ms | 10.25× | 10.09× | 5 of 5 | 650 µs, 644 µs, 636 µs, 636 µs, 644 µs | 6.56 ms, 6.63 ms, 6.62 ms, 6.6 ms, 6.58 ms |
| `net-document.serialize` | 1.74 ms | 13.4 ms | 7.72× | 7.65× | 5 of 5 | 1.75 ms, 1.75 ms, 1.74 ms, 1.74 ms, 1.74 ms | 13.4 ms, 13.5 ms, 13.6 ms, 13.3 ms, 13.4 ms |
| `net-document.parse` | 9.3 ms | 13.2 ms | 1.42× | 1.40× | 5 of 5 | 9.2 ms, 9.4 ms, 9.3 ms, 9.3 ms, 9.28 ms | 13.2 ms, 13.1 ms, 13.2 ms, 13.2 ms, 13.2 ms |
| `timers.delay-ring` | 7.39 ms | 109 ms | 14.78× | 14.62× | 5 of 5 | 7.45 ms, 7.43 ms, 7.35 ms, 7.39 ms, 7.33 ms | 109 ms, 109 ms, 110 ms, 109 ms, 110 ms |
| `lifecycle-scope.fill` | 380 µs | 23.3 ms | 61.46× | 60.51× | 5 of 5 | 380 µs, 381 µs, 377 µs, 378 µs, 382 µs | 23 ms, 23.3 ms, 23.1 ms, 23.4 ms, 23.6 ms |
| `lifecycle-scope.close` | 402 µs | 23.5 ms | 58.39× | 57.48× | 5 of 5 | 402 µs, 402 µs, 401 µs, 404 µs, 406 µs | 23.1 ms, 23.6 ms, 23.4 ms, 23.5 ms, 23.5 ms |
| `lifecycle-scope.reset` | 402 µs | 23.4 ms | 58.32× | 57.27× | 5 of 5 | 402 µs, 400 µs, 398 µs, 402 µs, 404 µs | 23.1 ms, 23.5 ms, 23.4 ms, 23.4 ms, 23.1 ms |

The benchmark is now built with `-threaded`. Built without it, it twice
stopped for good partway through a `scripts/bench-compare` run on
2026-10-12: the process sat at 0% CPU with its main thread in the
non-threaded RTS's deadlock path (`awaitUserSignals`, from `sample`), even
with standard input from `/dev/null`. The threaded build ran through. A
complete non-threaded run from earlier the same night (04:31–04:36, load
2.35–3.05) gave the same figures within a few per cent on every row except
`history.replay-marking` (200 ms, 17.2×) and `history.decode` (42.3 ms,
2.09×), where the threaded build is 10–15% slower.

## Results

<!-- bench: superseded -->

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
| Net definition v3 compile (200-place chain) | 200 places | 7.02 ms | 0.802 ms | 8.8× |
| Net document v1 serialize (chain, full view, 50-entry lineage) | 171 kB | 14.5 ms | 2.18 ms | 6.7× |
| Net document v1 parse (same document) | 50 lineage entries | 14.3 ms | 8.60 ms | 1.7× |
| Timers / delayed self-loop (50 tokens, `Delay(1)`) | 500 firings + 10 wakes | 118.6 ms | 10.2 ms | 12× |
| Lifecycle scope / fill (200 scoped deliveries) | 200 tokens | 25.3 ms | 0.470 ms | 54× |
| Lifecycle scope / close (filled scope) | 200 discarded | 25.2 ms | 0.499 ms | 51× |
| Lifecycle scope / reset (filled scope) | generation 2 | 25.2 ms | 0.515 ms | 49× |

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

The seven rows from Net definition v3 compile down were added on 2026-10-11
(the audit asked for coverage of compile, the Net document, timers, and
lifecycle scopes). Both sides were run that day on the same machine, which
was busy (load average 6–8 on 10 cores). The Haskell and Python sides were
checked to do the same work:

- the two serialized Net documents are byte-identical (171 162 bytes);
- the timer row fires 500 bindings and wakes 10 times on both sides;
- the scope rows fill 200 tokens, discard 200 on close, and reach
  generation 2 on reset on both sides.

The Haskell compile row also forces the compiled net's derived indices (its
arc URIs), because the Python `Net` constructor builds them eagerly. The
scope rows include building the Instance and the 200 deliveries; close and
reset then add one door each, so they differ from fill by that door's cost.

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
