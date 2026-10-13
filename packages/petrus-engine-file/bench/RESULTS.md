# fileVersion 2 benchmarks: Haskell vs petrus-engine

<!-- scripts/bench: measured sources fc866794e24395b7 at f6aeabc89de1 -->

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

Measured on 2026-10-12, 23:02–23:05 local (UTC-3), at commit `f6aeabc`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.84–3.96:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-engine-file 3 --twin '"$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/python_bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The earlier figures below were taken with other work loading the machine, which slowed the Python side more than the Haskell side. The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `chain-10.parse` | 17.8 µs | 48 µs | 2.70× | 2.64× | 3 of 3 | 17.9 µs, 17.8 µs, 17.3 µs | 48 µs, 47 µs, 48 µs |
| `chain-10.to_json` | 32.8 µs | 292 µs | 8.90× | 8.63× | 3 of 3 | 34.1 µs, 32.8 µs, 32.3 µs | 294 µs, 288 µs, 292 µs |
| `chain-10.format` | 51.7 µs | 351 µs | 6.79× | 6.67× | 3 of 3 | 51.7 µs, 51.9 µs, 50.6 µs | 351 µs, 346 µs, 355 µs |
| `chain-10.load` | 65.2 µs | 176 µs | 2.70× | 2.58× | 3 of 3 | 65.2 µs, 65.2 µs, 64.2 µs | 176 µs, 168 µs, 176 µs |
| `chain-1000.parse` | 3.99 ms | 5.17 ms | 1.29× | 1.24× | 3 of 3 | 4.17 ms, 3.99 ms, 3.84 ms | 5.17 ms, 5 ms, 5.17 ms |
| `chain-1000.to_json` | 8.74 ms | 26.5 ms | 3.04× | 2.71× | 3 of 3 | 9.79 ms, 8.53 ms, 8.74 ms | 26.5 ms, 26.5 ms, 27.1 ms |
| `chain-1000.format` | 13.5 ms | 33.6 ms | 2.49× | 2.38× | 3 of 3 | 13.8 ms, 12.4 ms, 13.5 ms | 32.9 ms, 33.8 ms, 33.6 ms |
| `chain-1000.load` | 12.8 ms | 17.6 ms | 1.37× | 1.33× | 3 of 3 | 13.5 ms, 12.6 ms, 12.8 ms | 18 ms, 16.9 ms, 17.6 ms |
| `chain-10000.parse` | 59 ms | 84.6 ms | 1.43× | 1.38× | 3 of 3 | 61.2 ms, 57.6 ms, 59 ms | 84.6 ms, 85.1 ms, 84.3 ms |
| `chain-10000.to_json` | 114 ms | 291 ms | 2.56× | 2.43× | 3 of 3 | 114 ms, 105 ms, 119 ms | 302 ms, 291 ms, 290 ms |
| `chain-10000.format` | 165 ms | 408 ms | 2.48× | 2.34× | 3 of 3 | 175 ms, 154 ms, 165 ms | 408 ms, 408 ms, 415 ms |
| `chain-10000.load` | 179 ms | 268 ms | 1.50× | 1.43× | 3 of 3 | 178 ms, 179 ms, 188 ms | 270 ms, 265 ms, 268 ms |
| `mounted-10.load` | 1.17 ms | 2.1 ms | 1.80× | 1.80× | 3 of 3 | 1.17 ms, 1.1 ms, 1.17 ms | 2.1 ms, 2.05 ms, 2.14 ms |
| `mounted-100.load` | 16.2 ms | 21.8 ms | 1.35× | 1.28× | 3 of 3 | 16.2 ms, 15.7 ms, 16.9 ms | 22.6 ms, 21.8 ms, 21.6 ms |
| `mounted-1000.load` | 208 ms | 292 ms | 1.40× | 1.37× | 3 of 3 | 216 ms, 199 ms, 208 ms | 297 ms, 286 ms, 292 ms |

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
