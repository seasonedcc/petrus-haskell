# petrus-json benchmarks: Haskell vs CPython's C-accelerated `json`

<!-- scripts/bench: measured sources 5a71271078f89149 at c550dcb1ddee -->
<!-- scripts/bench: carried to 1bb6fb3da10e385d at c33829edc562: the loads admit path is unchanged (only the refusal fallback moved into parseOrExplain); the rest are additions and docs -->
<!-- scripts/bench: carried to dc2967e0db88f3b2 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: Json's == (pythonEq) compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared, names aside), its numeric core numericEq/intFloatEq now being pyNumberEq/exactFloatEq, moved from Petrus.Json.Python.Object into Petrus.Json.Value and inlined at that call; PyObject's pyEq compiles as before; pythonTruthy is an addition -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` parse and write the
same realistic Petrus documents with the options of the upstream call site
each row stands for. The Python side is CPython 3.14.6's `json` with its C
scanner and C encoder (`python_bench.py` asserts both are in use), so this
compares petrus-json against the fastest path the reference has, not the
pure-Python fallbacks.

The documents are in `bench/fixtures/`, committed, written once by
`bench/make_fixtures.py` with the pinned reference (both sides read the same
bytes):

- **`history.jsonl`** (1 202 lines, 350 780 bytes): the schema-5 JSONL
  History an upstream `Instance` writes (`JsonlHistoryStore`) while 80 order
  tokens run through a three-step net. Token data has nested customers, item
  lists, float prices, an absent coupon, and names with accents, CJK and
  emoji.
- **`net-document.json`** (126 011 bytes): a portable Net document
  (`serialize_net_document`) of a 60-step pipeline with view positions and a
  20-entry execution lineage carrying token data.
- **`threads.jsonl`** (32 lines, 117 627 bytes): the 32 largest agenticus
  Thread documents of `packages/petrus-agenticus-core/differential/thread_corpus.json`.

The rows:

| row | upstream call it stands for | petrus-json call |
| --- | --- | --- |
| `history.loads` | `json.loads(line)` per History line (`petrus.impetus.history_store.jsonl`) | `parseJson surrogateRefusingLoads` |
| `history.dumps` | `json.dumps(record, allow_nan=False)` per record (the same writer) | `dumps defaultDumps {allowNan = False}` |
| `history.dumps-canonical` | `json.dumps(…, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":"))`, the canonical spelling of conflict judgments (simulation, observation, fabric) | `dumps compact {sortKeys = True}` |
| `net-document.loads` | `json.loads(document)` | `parseJson surrogateRefusingLoads` |
| `net-document.loads-strict` | `parse_net_document`: `object_pairs_hook` refusing duplicate members, `parse_constant` refusing `NaN`/`Infinity` | `parseJson surrogateRefusingLoads {duplicateMembers = RejectDuplicates, allowNonFiniteConstants = False}` |
| `net-document.dumps` | `serialize_net_document`: `indent=2, ensure_ascii=False, allow_nan=False` | `dumps indented` |
| `thread.loads` | `json.loads(text)` per Thread document | `parseJson surrogateRefusingLoads` |
| `thread.dumps` | the Thread repository's writer: `allow_nan=False, separators=(",", ":"), sort_keys=True` (ASCII) | `dumps defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True, allowNan = False}` |

Every row starts from bytes and ends in bytes or a fully evaluated value: the
Python side reads `bytes` and calls `.encode()` on what `dumps` returns, and
the Haskell side forces every node of a parsed value.

## Current figures

Measured on 2026-10-12, 19:54–19:58 local (UTC-3), at commit `f3b300b`
(the duplicate-member pre-check back, below), on the Apple M4 (Darwin
arm64), with a 1-minute load average of 2.11–4.01. Five interleaved
repetitions of

    scripts/bench-compare petrus-json 5

alternated which side went first. Haskell figures are tasty-bench means in
wall-clock time (`--stdev 5`, `+RTS -M2G`), with the benchmark executable
run directly in the package directory. Python figures are the twin's own
timing (CPython 3.14.6). Each figure is the median over the repetitions.
The ratio is Python ÷ Haskell, so above 1 means Haskell is faster; Haskell
was ahead in every repetition of every row, by 1.53× (`thread.loads`) to
2.97×. The run before the pre-check came back (19:18–19:22 at `2eb0f2a`,
load 2.80–3.25, five repetitions) read the same within 3% on every row but
`thread.loads`, which was 1.40× (336 µs). The tables in the sections below
are earlier measurements, kept with the analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `history.loads` | 1.13 ms | 2.55 ms | 2.26× | 2.21× | 5 of 5 | 1.1 ms, 1.13 ms, 1.1 ms, 1.15 ms, 1.15 ms | 2.55 ms, 2.83 ms, 2.55 ms, 2.54 ms, 2.56 ms |
| `history.dumps` | 969 µs | 2.88 ms | 2.97× | 2.97× | 5 of 5 | 962 µs, 959 µs, 975 µs, 969 µs, 969 µs | 2.88 ms, 2.87 ms, 2.9 ms, 2.88 ms, 2.97 ms |
| `history.dumps-canonical` | 1.39 ms | 3.82 ms | 2.75× | 2.68× | 5 of 5 | 1.39 ms, 1.39 ms, 1.39 ms, 1.38 ms, 1.42 ms | 3.81 ms, 3.84 ms, 3.83 ms, 3.82 ms, 3.8 ms |
| `net-document.loads` | 247 µs | 465 µs | 1.88× | 1.85× | 5 of 5 | 246 µs, 246 µs, 247 µs, 248 µs, 251 µs | 457 µs, 479 µs, 467 µs, 465 µs, 463 µs |
| `net-document.loads-strict` | 249 µs | 588 µs | 2.37× | 2.35× | 5 of 5 | 249 µs, 246 µs, 246 µs, 249 µs, 251 µs | 588 µs, 594 µs, 585 µs, 584 µs, 592 µs |
| `net-document.dumps` | 154 µs | 414 µs | 2.69× | 2.66× | 5 of 5 | 154 µs, 154 µs, 153 µs, 154 µs, 156 µs | 415 µs, 416 µs, 413 µs, 413 µs, 414 µs |
| `thread.loads` | 307 µs | 469 µs | 1.53× | 1.49× | 5 of 5 | 307 µs, 315 µs, 301 µs, 315 µs, 299 µs | 469 µs, 508 µs, 462 µs, 469 µs, 466 µs |
| `thread.dumps` | 351 µs | 667 µs | 1.90× | 1.88× | 5 of 5 | 351 µs, 350 µs, 350 µs, 351 µs, 352 µs | 667 µs, 668 µs, 663 µs, 668 µs, 662 µs |

## How to rerun

From the repository root (`scripts/bench petrus-json` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-json --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-json/bench/python_bench.py)
```

`scripts/bench-compare petrus-json 3` interleaves the two, which is how the
table below was taken.

## Numbers

Apple M4 (10 cores, 24 GiB), macOS 26.3.1, GHC 9.10.3 (`-O2`), CPython 3.14.6;
2026-10-11. Three interleaved repetitions (`scripts/bench-compare petrus-json
3`), with the one-minute load average between 4.6 and 6.9 (other builds were
running on the machine). Haskell figures are tasty-bench means in wall-clock
time (`localOption WallTime`, `--stdev 5`, `+RTS -M2G`); Python figures are
`scripts/bench_timing.py` medians (`time.perf_counter_ns`). Each cell is the
median over the repetitions; ratios read Python ÷ Haskell (how many times
faster Haskell is).

<!-- bench: superseded -->

| row | Haskell | Python | Python ÷ Haskell | lowest repetition |
|---|---:|---:|---:|---:|
| `history.loads` | 1.22 ms | 2.76 ms | 2.26× | 2.14× |
| `history.dumps` | 1.19 ms | 3.16 ms | 2.67× | 2.60× |
| `history.dumps-canonical` | 1.74 ms | 4.22 ms | 2.43× | 2.11× |
| `net-document.loads` | 280 µs | 508 µs | 1.82× | 1.49× |
| `net-document.loads-strict` | 257 µs | 664 µs | 2.59× | 2.30× |
| `net-document.dumps` | 195 µs | 501 µs | 2.57× | 2.38× |
| `thread.loads` | 285 µs | 556 µs | 1.95× | 1.75× |
| `thread.dumps` | 424 µs | 762 µs | 1.80× | 1.63× |

The strict reader is faster than CPython's by more than the plain one is,
because CPython's `object_pairs_hook` calls back into Python once per object
while petrus-json checks duplicates inside the parser.

## Optimizations kept and removed

Each A/B below ran the benchmark executables of the variants alternately,
five interleaved repetitions with the order rotating every repetition
(tasty-bench means in wall-clock time, `--stdev 5`, `+RTS -M2G`), on the
Apple M4 at a one-minute load average of 2.0–2.6, on 2026-10-12. Each cell is
the median of the five means; Python is the "Current figures" column above.

### The direct writer

<!-- bench: superseded -->

`dumps` writes straight into one growing buffer (`Petrus.Json.Encode`). The
plain alternative, a `Data.ByteString.Builder` encoder, cannot keep up with
CPython's C encoder, so the writer stays and the `Builder` encoder lives on
only as the test suite's oracle (`test/Petrus/Json/ReferenceEncode.hs`), which
the properties compare `dumps` against.

| row | `Builder` encoder | direct writer | Python | `Builder` vs Python |
| --- | ---: | ---: | ---: | ---: |
| `history.dumps` | 3.72 ms | 976 µs | 2.9 ms | 0.78× |
| `history.dumps-canonical` | 4.01 ms | 1.42 ms | 3.79 ms | 0.94× |
| `net-document.dumps` | 785 µs | 156 µs | 402 µs | 0.51× |
| `thread.dumps` | 1.10 ms | 356 µs | 645 µs | 0.59× |

### The parser's scans

<!-- bench: superseded -->

Three lower-level tricks in `Petrus.Json.Parse` were measured one at a time
against the parser that had them all (A), then removed together (C):

- B1: an eight-bytes-at-a-time (SWAR) scan for a string's end, replaced by
  `Data.ByteString.findIndex`;
- B2: an open-addressing hash pre-check for duplicate members of objects
  over 8 members, replaced by a `Data.Set` of the keys;
- B3: `copyAscii`, a private copy of an ASCII run into a `Text`, replaced by
  `Data.Text.Encoding.decodeLatin1`. It was slower (1.04–1.07×), and
  `copyAscii` was byte for byte petrus-json's own
  `Wtf8.unsafeTextFromBytes`, so C uses that one definition instead.

| row | A | B1 | B2 | B3 | C (all removed) | Python | C vs Python |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `history.loads` | 1.07 ms | 1.12× | 1.00× | 1.06× | 1.18 ms (1.10×) | 2.52 ms | 2.14× |
| `net-document.loads` | 233 µs | 1.10× | 0.98× | 1.04× | 255 µs (1.09×) | 439 µs | 1.72× |
| `net-document.loads-strict` | 233 µs | 1.10× | 0.98× | 1.05× | 253 µs (1.08×) | 567 µs | 2.24× |
| `thread.loads` | 270 µs | 1.19× | 1.09× | 1.07× | 353 µs (1.31×) | 458 µs | 1.30× |

The B and C columns are relative to A in the same run (above 1 is slower).
The plain parser still clears CPython on every row, so the tricks are gone.
`thread.loads` is now the thinnest margin, and `scripts/bench-gate` checks it
beside `thread.dumps`. B2 came back later, on a downstream measurement (next
section).

### The duplicate-member pre-check

<!-- bench: superseded -->

Without B2, hamsterdan-contracts' `contract decode Snapshot (validate_json)`
fell behind pydantic: 0.92× of CPython (1.77 µs against 1.62 µs, behind in
5 of 5 repetitions, 2026-10-12 19:24–19:26 at `4d5049e`), where it had read
1.41× with the parser A above. The row parses a 546-byte, 21-member object,
and checking 21 names through a `Data.Set` costs more than the rest of the
parse's savings. Measured with the bench's own rows plus two temporary ones
(parse alone, validate alone), three interleaved repetitions on 2026-10-12
around 19:45, load about 2.1:

| variant | parse | validate | decode (parse + validate) |
| --- | ---: | ---: | ---: |
| A (all three tricks) | 0.91 µs | 0.21 µs | 1.14 µs |
| C (none) | 1.51 µs | 0.21 µs | 1.77 µs |
| A without B2 (SWAR scan kept) | 1.35 µs | 0.21 µs | 1.57 µs |
| A without B1 (pre-check kept) | 1.15 µs | 0.21 µs | 1.38 µs |
| C plus an `IntSet` of FNV-1a hashes over the characters | 1.40 µs | 0.21 µs | 1.61 µs |
| C plus an `IntSet` of (length, first, last character) | 1.35 µs | 0.21 µs | 1.58 µs |

So the duplicate pre-check is the part that matters here, and an `IntSet`
of hashes is not cheap enough; the SWAR scan stays out. The parser now has
B2 again (`namesMayRepeat` in `Petrus.Json.Parse`, with `readArray` and
`writeArray` rather than the unchecked accessors it had before). Five
interleaved repetitions, 2026-10-12 19:48–19:50, load 2.1–2.5:

| row | C | C plus the pre-check |
| --- | ---: | ---: |
| `contract decode Snapshot (validate_json)` | 1.82 µs | 1.36 µs |
| `contract decode GateFact (validate_json)` (7 members) | 588 ns | 591 ns |
| `history.loads` | 1.13 ms | 1.13 ms |
| `net-document.loads` | 241 µs | 246 µs |
| `net-document.loads-strict` | 241 µs | 245 µs |
| `thread.loads` | 335 µs | 314 µs |

Objects of eight members or fewer still take the pairwise check, so the
rows without large objects do not change beyond noise.
