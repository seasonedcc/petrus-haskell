# fileVersion 2 benchmarks: Haskell vs petrus-engine

<!-- scripts/bench: measured sources c915260f96bb147c at df073f3106e5 -->

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

Measured on 2026-10-13, 03:28–03:31 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.79–3.40:
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
| `chain-10.parse` | 17.5 µs | 47 µs | 2.69× | 2.69× | 3 of 3 | 17.4 µs, 17.5 µs, 17.5 µs | 47 µs, 47 µs, 48 µs |
| `chain-10.to_json` | 32 µs | 291 µs | 9.09× | 9.09× | 3 of 3 | 32 µs, 31.7 µs, 32 µs | 291 µs, 291 µs, 293 µs |
| `chain-10.format` | 49.6 µs | 348 µs | 7.02× | 6.99× | 3 of 3 | 49.8 µs, 49.6 µs, 49.4 µs | 348 µs, 348 µs, 346 µs |
| `chain-10.load` | 65 µs | 170 µs | 2.62× | 2.57× | 3 of 3 | 65 µs, 64.3 µs, 65.7 µs | 172 µs, 170 µs, 169 µs |
| `chain-1000.parse` | 3.89 ms | 4.92 ms | 1.26× | 1.23× | 3 of 3 | 3.85 ms, 3.99 ms, 3.89 ms | 4.9 ms, 4.92 ms, 4.97 ms |
| `chain-1000.to_json` | 8.65 ms | 26.3 ms | 3.04× | 2.93× | 3 of 3 | 8.96 ms, 8.65 ms, 8.61 ms | 26.3 ms, 26.3 ms, 27.1 ms |
| `chain-1000.format` | 12.9 ms | 33.3 ms | 2.58× | 2.57× | 3 of 3 | 12.4 ms, 12.9 ms, 13 ms | 33.1 ms, 33.3 ms, 33.5 ms |
| `chain-1000.load` | 12.6 ms | 17.1 ms | 1.36× | 1.31× | 3 of 3 | 12.4 ms, 12.6 ms, 13.1 ms | 17 ms, 17.4 ms, 17.1 ms |
| `chain-10000.parse` | 58.2 ms | 79.1 ms | 1.36× | 1.36× | 3 of 3 | 58.2 ms, 58.5 ms, 57.8 ms | 79.1 ms, 79.7 ms, 78.8 ms |
| `chain-10000.to_json` | 102 ms | 287 ms | 2.81× | 2.68× | 3 of 3 | 102 ms, 107 ms, 102 ms | 286 ms, 287 ms, 287 ms |
| `chain-10000.format` | 163 ms | 395 ms | 2.42× | 2.41× | 3 of 3 | 159 ms, 164 ms, 163 ms | 395 ms, 394 ms, 398 ms |
| `chain-10000.load` | 176 ms | 261 ms | 1.48× | 1.45× | 3 of 3 | 180 ms, 176 ms, 175 ms | 260 ms, 261 ms, 261 ms |
| `mounted-10.load` | 1.12 ms | 2.08 ms | 1.87× | 1.86× | 3 of 3 | 1.12 ms, 1.12 ms, 1.11 ms | 2.08 ms, 2.09 ms, 2.06 ms |
| `mounted-100.load` | 15.7 ms | 21.6 ms | 1.37× | 1.33× | 3 of 3 | 16 ms, 15.7 ms, 15.7 ms | 21.3 ms, 21.6 ms, 21.6 ms |
| `mounted-1000.load` | 201 ms | 276 ms | 1.37× | 1.37× | 3 of 3 | 201 ms, 197 ms, 205 ms | 276 ms, 272 ms, 297 ms |

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

Run on 2026-10-13, 03:31–03:32 local (UTC-3), at commit `df073f3`, on the
same machine (Apple M4, 10 cores, 24 GB, macOS 26), with CPython 3.14.6 and
petrus-engine at the pin, by

    "$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/process_bench.py "$(cabal list-bin -v0 petrus-engine-file:exe:petrus-format-json)" 11

The run had 11 rounds, with a load average of 3.02 at the start and at
the end. The in-place row's lowest round (3.38×) is a single round; the
median over the 11 is 5.98×, against 3.45× in the run at `6be7b9a`
(23:05–23:06 the day before, load average 3.63–3.50), whose Haskell
median was 35.0 ms against 20.1 ms here. That run gave 1.97–4.31× in all. The run at
`81bbdc5` (load average 2.78–2.66) gave 2.34–3.96×. An earlier run (2026-10-11, load average 5.6–5.8) gave 2.29–5.05×:
Python's start-up was about 10 ms slower under that load, and Haskell's
about 2 ms faster (17.0 ms against 19.4 ms for chain-10).

| scenario | Python | Haskell | speed-up | lowest round |
| --- | ---: | ---: | ---: | ---: |
| --infile/--outfile chain-10 | 76.3 ms | 19.6 ms | 3.89× | 3.77× |
| --infile/--outfile chain-1000 | 109.9 ms | 33.4 ms | 3.29× | 3.04× |
| --infile/--outfile chain-10000 | 458.6 ms | 232.7 ms | 1.97× | 1.74× |
| in place, 100 x chain-10 | 120.1 ms | 20.1 ms | 5.98× | 3.38× |

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
