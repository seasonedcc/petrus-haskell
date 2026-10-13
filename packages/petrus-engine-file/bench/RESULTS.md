# fileVersion 2 benchmarks: Haskell vs petrus-engine

<!-- scripts/bench: measured sources c66eb0245d3bfaff at b4d1ccb669ad -->

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

Measured on 2026-10-13, 06:58–07:01 local (UTC-3), at commit `b4d1ccb`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.16–2.73:
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
| `chain-10.parse` | 17.3 µs | 48 µs | 2.77× | 2.55× | 3 of 3 | 18 µs, 17.3 µs, 17.2 µs | 46 µs, 48 µs, 48 µs |
| `chain-10.to_json` | 32.2 µs | 292 µs | 9.07× | 8.93× | 3 of 3 | 32.5 µs, 32.2 µs, 31.4 µs | 290 µs, 302 µs, 292 µs |
| `chain-10.format` | 49.7 µs | 352 µs | 7.08× | 6.91× | 3 of 3 | 49.7 µs, 50.7 µs, 49.5 µs | 352 µs, 350 µs, 353 µs |
| `chain-10.load` | 64.4 µs | 173 µs | 2.69× | 2.63× | 3 of 3 | 64.5 µs, 64.4 µs, 63.2 µs | 170 µs, 173 µs, 177 µs |
| `chain-1000.parse` | 3.84 ms | 5.22 ms | 1.36× | 1.27× | 3 of 3 | 3.91 ms, 3.84 ms, 3.8 ms | 4.95 ms, 5.22 ms, 5.23 ms |
| `chain-1000.to_json` | 8.53 ms | 26.4 ms | 3.10× | 3.08× | 3 of 3 | 8.53 ms, 8.41 ms, 8.58 ms | 26.5 ms, 26.4 ms, 26.4 ms |
| `chain-1000.format` | 12.5 ms | 32.6 ms | 2.62× | 2.59× | 3 of 3 | 12.4 ms, 12.6 ms, 12.5 ms | 32.8 ms, 32.5 ms, 32.6 ms |
| `chain-1000.load` | 12.7 ms | 17.1 ms | 1.34× | 1.32× | 3 of 3 | 12.9 ms, 12.7 ms, 12.7 ms | 17.1 ms, 17 ms, 17.1 ms |
| `chain-10000.parse` | 57.2 ms | 80.6 ms | 1.41× | 1.39× | 3 of 3 | 57.2 ms, 57.2 ms, 57.5 ms | 79.8 ms, 80.6 ms, 84.9 ms |
| `chain-10000.to_json` | 101 ms | 288 ms | 2.85× | 2.73× | 3 of 3 | 106 ms, 101 ms, 98.2 ms | 288 ms, 288 ms, 297 ms |
| `chain-10000.format` | 166 ms | 393 ms | 2.37× | 2.24× | 3 of 3 | 166 ms, 159 ms, 175 ms | 400 ms, 393 ms, 392 ms |
| `chain-10000.load` | 176 ms | 270 ms | 1.54× | 1.48× | 3 of 3 | 175 ms, 176 ms, 178 ms | 270 ms, 260 ms, 276 ms |
| `mounted-10.load` | 1.11 ms | 2.1 ms | 1.90× | 1.81× | 3 of 3 | 1.11 ms, 1.11 ms, 1.18 ms | 2.1 ms, 2.06 ms, 2.15 ms |
| `mounted-100.load` | 15.7 ms | 21.8 ms | 1.39× | 1.36× | 3 of 3 | 15.7 ms, 15.7 ms, 16.3 ms | 21.8 ms, 21.4 ms, 22.6 ms |
| `mounted-1000.load` | 199 ms | 275 ms | 1.38× | 1.38× | 3 of 3 | 199 ms, 199 ms, 202 ms | 274 ms, 275 ms, 281 ms |

At `b4d1ccb` the loader's arc sort compares a non-string path segment's
numbers with petrus-json's `pyNumberCompare`, and `pyEqWith` reads numbers
through the module's `valueNumber`; these nets' paths are all strings, so
the sort takes its string-key path. Every row reads within 8% of its
`df073f3` figure, the load rows within 5% (1.34–2.69×, against 1.36–2.62×).

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

Run on 2026-10-13, 07:01 local (UTC-3), at commit `b4d1ccb`, on the
same machine (Apple M4, 10 cores, 24 GB, macOS 26), with CPython 3.14.6 and
petrus-engine at the pin, by

    "$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/process_bench.py "$(cabal list-bin -v0 petrus-engine-file:exe:petrus-format-json)" 11

The run had 11 rounds, with a load average of 2.49 at the start and 2.38
at the end. The in-place row moves the most between runs: its median is
3.82× here (Haskell 31.6 ms), 5.98× in the run at `df073f3` (03:31–03:32,
load average 3.02; Haskell 20.1 ms; 1.97–5.98× in all) and 3.45× in the run at `6be7b9a` (23:05–23:06 the day
before, load average 3.63–3.50; Haskell 35.0 ms), which gave 1.97–4.31× in all. The run at
`81bbdc5` (load average 2.78–2.66) gave 2.34–3.96×. An earlier run (2026-10-11, load average 5.6–5.8) gave 2.29–5.05×:
Python's start-up was about 10 ms slower under that load, and Haskell's
about 2 ms faster (17.0 ms against 19.4 ms for chain-10).

| scenario | Python | Haskell | speed-up | lowest round |
| --- | ---: | ---: | ---: | ---: |
| --infile/--outfile chain-10 | 76.4 ms | 19.3 ms | 3.96× | 3.89× |
| --infile/--outfile chain-1000 | 112.6 ms | 34.7 ms | 3.25× | 2.87× |
| --infile/--outfile chain-10000 | 471.6 ms | 243.8 ms | 1.93× | 1.40× |
| in place, 100 x chain-10 | 120.9 ms | 31.6 ms | 3.82× | 3.45× |

Python spends 70–85 ms starting the interpreter and importing pydantic
and petrus-engine before it formats anything. That start-up cost decides
the small inputs. On chain-10000 the formatting itself dominates, and the
ratio approaches the library rows' `format` ratio (2.4× in the current figures), less the time
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
