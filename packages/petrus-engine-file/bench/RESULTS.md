# fileVersion 2 benchmarks: Haskell vs petrus-engine

<!-- scripts/bench: measured sources 9403c1e47485dfc2 at 5a73d7a7f019 -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` time the same steps
on the same input texts. `bench/process_bench.py` times the format command
as a process, `petrus-format-json` against `python -m
petrus.cli.format_json` ([below](#the-format-command-as-a-process)). Both sides generate the inputs byte for byte the
same and print their sizes, and the sizes agree:

| input | bytes in | out |
| --- | ---: | ---: |
| chain-10 | 1 949 | 2 212 bytes written |
| chain-1000 | 202 056 | 224 667 bytes written |
| chain-10000 | 2 130 285 | 2 356 040 bytes written |
| mounted-10 | 1 277 | 230 arcs resolved |
| mounted-100 | 12 437 | 2 300 arcs resolved |
| mounted-1000 | 128 537 | 23 000 arcs resolved |

The inputs:

- **chain-N**: one file, written on one line. It has N+1 places, N
  transitions and about 2.1N arcs, with keys out of canonical order, float
  coordinates, labels, weights, read arcs, delays, and a layout entry per
  node.
- **mounted-K**: a root file that mounts the `chain-10` net K times through
  `refs`, with an arc into each mount. Loading it means K+1 file reads,
  parses and catalog comparisons, and K mounts inlined.

The steps:

| step | petrus-engine | Haskell |
| --- | --- | --- |
| parse | `FlatNetFile.model_validate_json(text)` | `fromJson` |
| to_json | `file.to_json()` | `toJson` |
| format | `reformat_content(text, indent=2, max_inline=120)` | `reformatContent 2 120` |
| load | `FlatNet.from_filename(path).to_schema()` | `loadFile`, `toSchema` |

Each Haskell result is forced in full (`NFData`).

## How to rerun

From the repository root (`scripts/bench petrus-engine-file` runs exactly
this; `scripts/upstream-python petrus-engine` provisions the pinned
petrus-engine):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-engine-file +RTS -M2G -RTS
"$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/python_bench.py
cabal build -j2 -v0 petrus-engine-file:exe:petrus-format-json
"$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/process_bench.py "$(cabal list-bin -v0 petrus-engine-file:exe:petrus-format-json)" 11
```

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median
of 5 to 200 runs after one warm-up. Both were run on 2026-10-10 on an Apple
M4 with 24 GB of memory, using GHC 9.10.3 (`-O2`), CPython 3.14.6 and the
locked pydantic 2, with petrus-engine at `fc1dd50`. The machine was shared
with other builds, so absolute numbers moved by up to 25% between runs; the
table is one Haskell run and the Python run that followed it.

## Current figures

Measured on 2026-10-12, 03:32–03:34 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.53–2.27:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-engine-file 3 --twin '"$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/python_bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The earlier figures below were taken with other work loading the machine, which slowed the Python side more than the Haskell side. The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `chain-10.parse` | 19.8 µs | 47 µs | 2.38× | 2.37× | 19.6 µs, 19.8 µs, 19.8 µs | 47 µs, 47 µs, 47 µs |
| `chain-10.to_json` | 46.9 µs | 292 µs | 6.22× | 6.22× | 45.7 µs, 46.9 µs, 46.9 µs | 292 µs, 292 µs, 292 µs |
| `chain-10.format` | 70.1 µs | 348 µs | 4.97× | 4.90× | 67.9 µs, 71.2 µs, 70.1 µs | 348 µs, 349 µs, 348 µs |
| `chain-10.load` | 66.1 µs | 171 µs | 2.59× | 2.56× | 64.5 µs, 66.1 µs, 66.9 µs | 171 µs, 170 µs, 171 µs |
| `chain-1000.parse` | 3.44 ms | 4.95 ms | 1.44× | 1.42× | 3.33 ms, 3.45 ms, 3.44 ms | 4.95 ms, 4.9 ms, 5.01 ms |
| `chain-1000.to_json` | 7.08 ms | 26.2 ms | 3.70× | 3.69× | 6.99 ms, 7.11 ms, 7.08 ms | 26.2 ms, 26.3 ms, 26.1 ms |
| `chain-1000.format` | 11 ms | 32.6 ms | 2.97× | 2.95× | 10.9 ms, 11 ms, 11.1 ms | 32.9 ms, 32.5 ms, 32.6 ms |
| `chain-1000.load` | 11.6 ms | 16.7 ms | 1.43× | 1.41× | 11.3 ms, 11.6 ms, 11.8 ms | 16.9 ms, 16.6 ms, 16.7 ms |
| `chain-10000.parse` | 57.9 ms | 77.5 ms | 1.34× | 1.32× | 57 ms, 58 ms, 57.9 ms | 77.5 ms, 77.5 ms, 76.5 ms |
| `chain-10000.to_json` | 94.9 ms | 288 ms | 3.03× | 2.93× | 97.8 ms, 93.8 ms, 94.9 ms | 286 ms, 289 ms, 288 ms |
| `chain-10000.format` | 182 ms | 387 ms | 2.12× | 2.07× | 182 ms, 182 ms, 186 ms | 386 ms, 391 ms, 387 ms |
| `chain-10000.load` | 192 ms | 255 ms | 1.33× | 1.31× | 192 ms, 192 ms, 192 ms | 258 ms, 252 ms, 255 ms |
| `mounted-10.load` | 1.12 ms | 2.08 ms | 1.86× | 1.84× | 1.11 ms, 1.12 ms, 1.12 ms | 2.04 ms, 2.08 ms, 2.08 ms |
| `mounted-100.load` | 15.3 ms | 21.4 ms | 1.40× | 1.39× | 15 ms, 15.4 ms, 15.3 ms | 21.5 ms, 21.4 ms, 21.3 ms |
| `mounted-1000.load` | 215 ms | 267 ms | 1.24× | 1.23× | 213 ms, 215 ms, 217 ms | 267 ms, 269 ms, 267 ms |

## Results

<!-- bench: superseded -->

| input | step | Python | Haskell | speed-up |
| --- | --- | ---: | ---: | ---: |
| chain-10 | parse | 0.048 ms | 0.024 ms | 2.0× |
| chain-10 | to_json | 0.320 ms | 0.060 ms | 5.3× |
| chain-10 | format | 0.384 ms | 0.090 ms | 4.3× |
| chain-10 | load | 0.188 ms | 0.082 ms | 2.3× |
| chain-1000 | parse | 6.64 ms | 4.22 ms | 1.6× |
| chain-1000 | to_json | 33.1 ms | 8.07 ms | 4.1× |
| chain-1000 | format | 42.6 ms | 13.0 ms | 3.3× |
| chain-1000 | load | 22.1 ms | 13.5 ms | 1.6× |
| chain-10000 | parse | 118 ms | 70.1 ms | 1.7× |
| chain-10000 | to_json | 390 ms | 110 ms | 3.5× |
| chain-10000 | format | 529 ms | 179 ms | 3.0× |
| chain-10000 | load | 333 ms | 220 ms | 1.5× |
| mounted-10 | load | 2.77 ms | 1.28 ms | 2.2× |
| mounted-100 | load | 30.2 ms | 17.3 ms | 1.7× |
| mounted-1000 | load | 351 ms | 248 ms | 1.4× |

Over all runs, the closest comparison paired the fastest Python run with the
slowest Haskell run of the same step:

- mounted-1000 load: 351 ms against 301 ms, 1.17×;
- chain-10000 parse: 88.9 ms against 72.8 ms, 1.22×.

Every step was faster in Haskell in every run.

## The format command as a process

The library rows above leave out what a user, or a pre-commit hook, pays
for each run: starting the interpreter or the runtime, parsing arguments,
reading, writing and exiting. `bench/process_bench.py` times whole runs of
the two commands on the same inputs (`python_bench.chain_text`, the texts
of the library rows):

- `--infile/--outfile chain-N`: one file in, one file out;
- `in place, 100 x chain-10`: 100 files named on the command line and
  rewritten in place. The inputs are restored before every run, outside
  the timed region.

Each round runs both commands once per scenario, back to back, and
alternates which one goes first. A run is timed with `time.perf_counter`
around `subprocess.run`, and a warm-up round is not counted. Both outputs
are compared byte for byte after every run. Times are medians, the
speed-up is Python's median over Haskell's, and "lowest round" is the
smallest ratio within a single round.

Run on 2026-10-12, 04:10–04:11 local (UTC-3), at commit `81bbdc5`, on the
same machine (Apple M4, 10 cores, 24 GB, macOS 26), with CPython 3.14.6 and
petrus-engine at the pin, by

    "$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/process_bench.py "$(cabal list-bin -v0 petrus-engine-file:exe:petrus-format-json)" 11

The run had 11 rounds, with a load average of 2.78 at the start and 2.66 at
the end. An earlier run (2026-10-11, load average 5.6–5.8) gave 2.29–5.05×:
Python's start-up was about 10 ms slower under that load, and Haskell's
about 2 ms faster (17.0 ms against 19.4 ms for chain-10).

| scenario | Python | Haskell | speed-up | lowest round |
| --- | ---: | ---: | ---: | ---: |
| --infile/--outfile chain-10 | 76.3 ms | 19.4 ms | 3.94× | 3.77× |
| --infile/--outfile chain-1000 | 108.1 ms | 31.8 ms | 3.40× | 3.19× |
| --infile/--outfile chain-10000 | 454.0 ms | 193.7 ms | 2.34× | 2.26× |
| in place, 100 x chain-10 | 119.7 ms | 30.2 ms | 3.96× | 3.58× |

Python spends 70–85 ms starting the interpreter and importing pydantic
and petrus-engine before it formats anything. That start-up cost decides
the small inputs. On chain-10000 the formatting itself dominates, and the
ratio approaches the library rows' `format` ratio (2.1× in the current figures), less the time
both commands spend reading and writing 2 MB.

## Notes

- **Parsing is where Python is strongest.** pydantic validates JSON in Rust
  through jiter, so `parse` has the smallest margin. This package ports jiter
  and pydantic's checks and error reports, and still parses 1.6–2× faster.
- **Writing is where the gap is widest.** `compact_json` is pure Python and
  serializes each container again at every nesting level. The Haskell port
  keeps that algorithm, so its output and the thresholds it decides by are
  the same, and it runs 3–5× faster.
- **Loading grows a little faster than the input on both sides.** From
  mounted-100 to mounted-1000, Python takes 11.6× longer and Haskell 14×.
  Each mount is read and parsed again and compared with the catalog entry,
  as the reference does.
