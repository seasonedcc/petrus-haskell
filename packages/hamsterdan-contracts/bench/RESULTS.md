# hamsterdan-contracts benchmarks

These are the hot paths Hamsterdan runs on every token:

- strict contract decoding (`TypeAdapter(T).validate_json`);
- canonical encoding (`json.dumps(dump_python(mode="json"))`);
- the dashboard's Python-literal entries (`f"{kind}:{body}"`);
- dashboard digests (`f"{kind}:{sorted(body.items())!r}"`);
- `ast.literal_eval` of a stored entry.

Both sides run the same operations on the same inputs (`bench/inputs.json`):

- a V5 `Snapshot` of 21 fields;
- a `GateFact` whose body holds quotes and non-ASCII text.

## Results

The machine was an Apple M4 (10 cores), macOS 26.3, shared with other
builds; the load average was 5–6 during these runs.

- Haskell: GHC 9.10.3 with `-O2`, `tasty-bench`; each cell is the mean of
  that benchmark run.
- Python: CPython 3.14.6 with pydantic 2.13.4; each cell is the best of 5
  `timeit` repeats of 20000 calls.
- Both suites were run twice, interleaved. The table shows each side's best
  run.

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
cabal bench -j2 hamsterdan-contracts --benchmark-options='+RTS -M2G -RTS'
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
