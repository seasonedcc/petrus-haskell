# petrus-json benchmarks: Haskell vs CPython's C-accelerated `json`

<!-- scripts/bench: measured sources 057e29b20061fe51 at 77bb0a55f8cd -->

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
| `history.loads` | `json.loads(line)` per History line (`petrus.impetus.history_store.jsonl`) | `parseJson pythonLoads` |
| `history.dumps` | `json.dumps(record, allow_nan=False)` per record (the same writer) | `dumps defaultDumps {allowNan = False}` |
| `history.dumps-canonical` | `json.dumps(…, allow_nan=False, ensure_ascii=False, sort_keys=True, separators=(",", ":"))`, the canonical spelling of conflict judgments (simulation, observation, fabric) | `dumps compact {sortKeys = True}` |
| `net-document.loads` | `json.loads(document)` | `parseJson pythonLoads` |
| `net-document.loads-strict` | `parse_net_document`: `object_pairs_hook` refusing duplicate members, `parse_constant` refusing `NaN`/`Infinity` | `parseJson pythonLoads {duplicateMembers = RejectDuplicates, allowNonFiniteConstants = False}` |
| `net-document.dumps` | `serialize_net_document`: `indent=2, ensure_ascii=False, allow_nan=False` | `dumps indented` |
| `thread.loads` | `json.loads(text)` per Thread document | `parseJson pythonLoads` |
| `thread.dumps` | the Thread repository's writer: `allow_nan=False, separators=(",", ":"), sort_keys=True` (ASCII) | `dumps defaultDumps {itemSeparator = Just ",", keySeparator = ":", sortKeys = True, allowNan = False}` |

Every row starts from bytes and ends in bytes or a fully evaluated value: the
Python side reads `bytes` and calls `.encode()` on what `dumps` returns, and
the Haskell side forces every node of a parsed value.

## How to rerun

From the repository root (`scripts/bench petrus-json` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-json --benchmark-options='--stdev 5 +RTS -M2G -RTS'
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
