# petrus-json benchmarks: Haskell vs CPython's C-accelerated `json`

<!-- scripts/bench: measured sources d0554ed1502e9147 at d354c961785e -->

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

Measured on 2026-10-12, 13:14–13:20 local (UTC-3), at commit `d354c96`
(the plain parser and the in-place `str` reader), on the Apple M4 (Darwin
arm64), with a 1-minute load average of 5.6–11.4 (other builds were running).
Three interleaved repetitions of

    scripts/bench-compare petrus-json 3

alternated which side went first. Haskell figures are tasty-bench means in
wall-clock time (`--stdev 5`, `+RTS -M2G`), with the benchmark executable
run directly in the package directory. Python figures are the twin's own
timing (CPython 3.14.6). Each figure is the median over the repetitions.
The ratio is Python ÷ Haskell, so above 1 means Haskell is faster. The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `history.loads` | 1.34 ms | 2.88 ms | 2.14× | 1.65× | 1.75 ms, 1.34 ms, 1.23 ms | 2.88 ms, 3.24 ms, 2.76 ms |
| `history.dumps` | 1.16 ms | 3.32 ms | 2.87× | 2.21× | 1.36 ms, 1.16 ms, 1.14 ms | 3.01 ms, 3.46 ms, 3.32 ms |
| `history.dumps-canonical` | 2.05 ms | 4.37 ms | 2.14× | 1.85× | 2.05 ms, 1.62 ms, 2.14 ms | 4.39 ms, 4.37 ms, 3.97 ms |
| `net-document.loads` | 260 µs | 480 µs | 1.85× | 1.84× | 260 µs, 264 µs, 259 µs | 477 µs, 519 µs, 480 µs |
| `net-document.loads-strict` | 252 µs | 658 µs | 2.61× | 2.41× | 249 µs, 262 µs, 252 µs | 1.26 ms, 658 µs, 608 µs |
| `net-document.dumps` | 168 µs | 461 µs | 2.75× | 2.52× | 164 µs, 174 µs, 168 µs | 502 µs, 461 µs, 423 µs |
| `thread.loads` | 361 µs | 565 µs | 1.56× | 1.44× | 361 µs, 372 µs, 343 µs | 574 µs, 565 µs, 493 µs |
| `thread.dumps` | 390 µs | 723 µs | 1.85× | 1.80× | 376 µs, 399 µs, 390 µs | 883 µs, 723 µs, 702 µs |

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
beside `thread.dumps`.
