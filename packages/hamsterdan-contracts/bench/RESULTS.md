# hamsterdan-contracts benchmarks

<!-- scripts/bench: measured sources 3888921f1d3b5af4 at df073f3106e5 -->
<!-- scripts/bench: carried to 2ace458e0b741478 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: Hamsterdan.Python.Value.truthy is petrus-json's pythonTruthy, the same seven equations; Codec's Literal int-against-float test calls pyNumberEq, the same exact test it spelled out; Hamsterdan.PyLiteral's constructors are renamed (PyNone..PyDict to LitNone..LitDict), names only; Hamsterdan.Sqlite gains a comment only; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->

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

Measured on 2026-10-13, 02:49–02:51 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.92–3.55:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare hamsterdan-contracts 3 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-contracts/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `contract decode Snapshot (validate_json)` | 1.42 µs | 1.6 µs | 1.13× | 1.10× | 5 of 5 | 1.46 µs, 1.43 µs, 1.42 µs, 1.3 µs, 1.39 µs | 1.6 µs, 1.6 µs, 1.63 µs, 1.68 µs, 1.58 µs |
| `contract encode Snapshot (dump + json.dumps)` | 1.45 µs | 4.15 µs | 2.86× | 2.47× | 3 of 3 | 1.45 µs, 1.42 µs, 1.69 µs | 4.15 µs, 4.11 µs, 4.18 µs |
| `contract decode GateFact (validate_json)` | 602 ns | 811 ns | 1.35× | 1.26× | 3 of 3 | 643 ns, 592 ns, 602 ns | 811 ns, 829 ns, 800 ns |
| `contract encode GateFact (dump + json.dumps)` | 509 ns | 2.74 µs | 5.39× | 5.31× | 3 of 3 | 510 ns, 507 ns, 509 ns | 2.71 µs, 2.74 µs, 2.74 µs |
| `literal print dashboard entry (f'{kind}:{body}')` | 425 ns | 644 ns | 1.52× | 1.45× | 3 of 3 | 437 ns, 423 ns, 425 ns | 635 ns, 644 ns, 645 ns |
| `literal print digest (sorted items repr)` | 648 ns | 1.36 µs | 2.11× | 2.11× | 3 of 3 | 650 ns, 643 ns, 648 ns | 1.39 µs, 1.36 µs, 1.36 µs |
| `literal parse dashboard entry (literal_eval)` | 3.2 µs | 10.8 µs | 3.37× | 3.32× | 3 of 3 | 3.2 µs, 3.17 µs, 3.26 µs | 10.8 µs, 10.8 µs, 10.8 µs |

Haskell was ahead in every repetition of every row. The closest row is
`contract decode Snapshot`, 1.13× (lowest repetition 1.10×): it read
1.12× after the three repetitions, so it got two more of its own
(03:55, load average 3.59–3.79, the same command with
`2 --pattern '/decode Snapshot/'`), and its line pools all five; it read
1.11× at `f3b300b` (five repetitions). Measured at
`4d5049e` (19:24–19:26, five repetitions), before petrus-json's duplicate
pre-check came back, it read 0.92× (1.77 µs against 1.62 µs, behind in 5 of
5): the row parses a 21-member object, and petrus-json had replaced the
pre-check with a `Data.Set` of the member names. The A/B that brought it
back is in petrus-json's `bench/RESULTS.md` ("The duplicate-member
pre-check"). The two decode rows are still slower than in the `81bbdc5`
table (1.14 µs and 514 ns there, three repetitions at load 2.22–2.47), whose
parser also had the eight-bytes-at-a-time string scan that petrus-json
dropped; the Snapshot figures also spread more (1.30–1.46 µs in this run).

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
  - machine-`Int` short integers;
  - an 8-bytes-at-a-time string scan and a hashed duplicate-key pre-check.
    Both were later removed, because the plain parser clears CPython
    without them (petrus-json's `bench/RESULTS.md`, "The parser's scans").
- **`petrus-json` encoder:** exact sizing and one direct write.
- **Generated positional decoders:** each record decodes by position when the
  input members arrive in declaration order.
- **Literal printing:** the printer writes a JSON body straight into one
  buffer (below).

### The literal printer

<!-- bench: superseded -->

`Hamsterdan.PyLiteral` prints a dashboard entry (`f"{kind}:{body}"`) and a
projection digest (`f"{kind}:{sorted(body.items())!r}"`). Both are the
`repr` of a JSON value, which petrus-json's `Petrus.Json.Python.JsonRepr`
writes. A plain printer cannot keep up with CPython. That printer built
difference lists of the pieces, joined them with one `T.concat`, and spelled
each string with `pythonStrRepr`. So the exact-size writer stays, and it
moved from this package into petrus-json, the lowest layer, behind
`jsonRepr` and `jsonItemsRepr`.

The A/Bs ran on 2026-10-12 on the Apple M4, at a one-minute load average
of 5–6. The variants' benchmark executables ran alternately, five
interleaved repetitions each (tasty-bench means in wall-clock time,
`--stdev 5`, `+RTS -M2G`). Each cell is the median of the five means;
Python is the "Current figures" column above.

| row | plain printer | writer in this package | writer in petrus-json (now) | Python | plain vs Python | now vs Python |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dashboard entry | 916 ns | 423 ns / 421 ns | 487 ns | 636 ns | 0.69× | 1.31× |
| digest | 1.41 µs | 675 ns / 667 ns | 769 ns | 1.36 µs | 0.96× | 1.77× |

The writer was measured twice: once against the plain printer, and once
against its petrus-json home. Across the package boundary it is about 15%
slower, and it still clears CPython with margin.

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
