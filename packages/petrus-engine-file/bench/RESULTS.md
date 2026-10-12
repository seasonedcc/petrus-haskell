# fileVersion 2 benchmarks: Haskell vs petrus-engine

<!-- scripts/bench: measured sources b13b5e034dbd1ad1 at db35a07b61f1 -->

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
cabal bench -j2 petrus-engine-file --benchmark-options='+RTS -M2G -RTS'
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

## Results

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

Run on 2026-10-11 on the same machine (Apple M4, 10 cores, 24 GB, macOS 26),
with CPython 3.14.6 and petrus-engine at the pin. The run had 11 rounds,
with a load average of 5.8 at the start and 5.6 at the end; the machine was
shared with other builds.

| scenario | Python | Haskell | speed-up | lowest round |
| --- | ---: | ---: | ---: | ---: |
| --infile/--outfile chain-10 | 85.8 ms | 17.0 ms | 5.05× | 4.75× |
| --infile/--outfile chain-1000 | 121.4 ms | 29.5 ms | 4.12× | 3.83× |
| --infile/--outfile chain-10000 | 486.5 ms | 212.1 ms | 2.29× | 2.17× |
| in place, 100 x chain-10 | 130.0 ms | 28.3 ms | 4.59× | 4.27× |

Python spends about 85 ms starting the interpreter and importing pydantic
and petrus-engine before it formats anything. That start-up cost decides
the small inputs. On chain-10000 the formatting itself dominates, and the
ratio approaches the library rows' `format` ratio (3.0×), less the time
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
