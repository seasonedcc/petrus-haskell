# hamsterdan-contracts benchmarks

<!-- scripts/bench: measured sources 98bc8a2aa76a463b at 5a73d7a7f019 -->

These are the hot paths Hamsterdan runs on every token:

- strict contract decoding (`TypeAdapter(T).validate_json`);
- canonical encoding (`json.dumps(dump_python(mode="json"))`);
- the dashboard's Python-literal entries (`f"{kind}:{body}"`);
- dashboard digests (`f"{kind}:{sorted(body.items())!r}"`);
- `ast.literal_eval` of a stored entry.

Both sides run the same operations on the same inputs (`bench/inputs.json`):

- a V5 `Snapshot` of 21 fields;
- a `GateFact` whose body holds quotes and non-ASCII text.

## Current figures

Measured on 2026-10-12, 03:34–03:34 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.22–2.47:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare hamsterdan-contracts 3 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-contracts/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `contract decode Snapshot (validate_json)` | 1.14 µs | 1.6 µs | 1.41× | 1.37× | 1.15 µs, 1.14 µs, 1.13 µs | 1.58 µs, 1.6 µs, 1.64 µs |
| `contract encode Snapshot (dump + json.dumps)` | 1.41 µs | 4.18 µs | 2.96× | 2.92× | 1.43 µs, 1.41 µs, 1.41 µs | 4.18 µs, 4.22 µs, 4.17 µs |
| `contract decode GateFact (validate_json)` | 514 ns | 799 ns | 1.55× | 1.51× | 511 ns, 528 ns, 514 ns | 796 ns, 799 ns, 806 ns |
| `contract encode GateFact (dump + json.dumps)` | 508 ns | 2.73 µs | 5.37× | 5.36× | 509 ns, 503 ns, 508 ns | 2.73 µs, 2.73 µs, 2.72 µs |
| `literal print dashboard entry (f'{kind}:{body}')` | 385 ns | 636 ns | 1.65× | 1.60× | 386 ns, 385 ns, 385 ns | 617 ns, 640 ns, 636 ns |
| `literal print digest (sorted items repr)` | 617 ns | 1.36 µs | 2.21× | 2.20× | 617 ns, 614 ns, 620 ns | 1.36 µs, 1.36 µs, 1.39 µs |
| `literal parse dashboard entry (literal_eval)` | 3.2 µs | 10.8 µs | 3.37× | 3.36× | 3.2 µs, 3.18 µs, 3.21 µs | 10.8 µs, 10.7 µs, 10.8 µs |

## Results

The machine was an Apple M4 (10 cores), macOS 26.3, shared with other
builds; the load average was 5–6 during these runs.

- Haskell: GHC 9.10.3 with `-O2`, `tasty-bench`; each cell is the mean of
  that benchmark run.
- Python: CPython 3.14.6 with pydantic 2.13.4; each cell is the best of 5
  `timeit` repeats of 20000 calls.
- Both suites were run twice, interleaved. The table shows each side's best
  run.

<!-- bench: superseded -->

| Operation | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| decode `Snapshot` (`validate_json`) | 1.14 µs | 1.66 µs | 1.5× |
| encode `Snapshot` (`dump` + `json.dumps`) | 2.63 µs | 4.30 µs | 1.6× |
| decode `GateFact` (`validate_json`) | 0.50 µs | 0.85 µs | 1.7× |
| encode `GateFact` (`dump` + `json.dumps`) | 0.95 µs | 2.90 µs | 3.1× |
| print dashboard entry (`f"{kind}:{body}"`) | 0.42 µs | 0.65 µs | 1.5× |
| print dashboard digest (`sorted(body.items())!r`) | 0.69 µs | 1.42 µs | 2.1× |
| parse a dashboard entry (`ast.literal_eval`) | 3.52 µs | 11.50 µs | 3.3× |

Haskell is faster on every operation. Getting there took these changes:

- **`petrus-json` parser:**
  - an unboxed result instead of `Either`/tuple returns;
  - an 8-bytes-at-a-time string scan;
  - machine-`Int` short integers;
  - a duplicate-key check by small quadratic scan or hashed pre-check.
- **`petrus-json` encoder:** exact sizing and one direct write.
- **Generated positional decoders:** each record decodes by position when the
  input members arrive in declaration order.
- **Literal printing:** the printer writes a JSON body straight into one
  buffer.

## Rerun

From the repository root (`scripts/bench hamsterdan-contracts` runs exactly
this; `scripts/upstream-python hamsterdan` provisions the pinned Hamsterdan):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run hamsterdan-contracts +RTS -M2G -RTS
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-contracts/bench/bench.py
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

`bench.py` finds `inputs.json` next to itself, so it can run from any
directory. Add `--benchmark-options='+RTS -T'` to the first command to see
allocation figures.
