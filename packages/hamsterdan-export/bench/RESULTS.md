# hamsterdan-export benchmarks

<!-- scripts/bench: measured sources 769e555db8036354 at 5a73d7a7f019 -->

One export of pull request 7, from three state directories:

- **fixture:** the upstream test suite's default state directory
  (`test/Fixtures.hs`, the port of `test_export.py`'s `state_dir`).
- **host-driven:** a state directory written by the reference host itself
  (`hamsterdan-host`'s `differential/state_reference.py drive` over
  `differential/host_steps.json`), about 600 History records.
- **large:** the fixture plus 2000 agent review operations (request and
  completion each, half of them with stored bodies) and 400 board
  publications, about 4800 History records.

Each state directory is exported in two shapes, both timed by wall clock
(monotonic):

- **CLI (fresh process):** `python -I -B -m hamsterdan.host.export` against
  the `hamsterdan-export` binary, each a fresh process with the same
  arguments. Interpreter and runtime start-up are included, because an
  operator pays for them.
- **in process:** `hamsterdan.host.export.main` called again and again
  inside one long-lived interpreter (`bench/bench.py`), against
  `Hamsterdan.Export.runExport` called again and again inside the benchmark
  process. Start-up is excluded, and the interpreter is warm after its first
  run.

Both shapes interleave the two sides run by run, and the order flips every
run, so both meet the same file-system state. Output directories are
removed between runs, outside the timed region. Each cell is the median of
21 runs, with the minimum in parentheses.

## Current figures

Measured on 2026-10-12, 03:57–03:58 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.77–3.00, by

    scripts/bench-run hamsterdan-export --runs 21 +RTS -M2G -RTS

Each cell is the median of 21 runs, interleaved as described above, with the minimum in parentheses. The tables in the sections below are earlier measurements.

| State directory | Shape | Haskell median (min) | Python median (min) | Python / Haskell |
| --- | --- | ---: | ---: | ---: |
| fixture | CLI (fresh process) | 18.8 ms (14.5 ms) | 699.9 ms (690.9 ms) | 37.31× |
| fixture | in process | 3.0 ms (2.7 ms) | 3.7 ms (3.5 ms) | 1.26× |
| host-driven | CLI (fresh process) | 19.5 ms (14.5 ms) | 710.2 ms (698.9 ms) | 36.48× |
| host-driven | in process | 6.7 ms (6.3 ms) | 7.2 ms (6.8 ms) | 1.08× |
| large | CLI (fresh process) | 174.7 ms (159.4 ms) | 952.5 ms (931.9 ms) | 5.45× |
| large | in process | 151.4 ms (142.3 ms) | 246.6 ms (232.9 ms) | 1.63× |

## Results

The machine was an Apple M4 (10 cores) running macOS 26.3.1, shared with
other work. The load average was 4.8–5.4 during the run (2026-10-11,
01:38–01:40 local, UTC-3, on top of `e170b69`).

- **Haskell:** GHC 9.10.3. The binary and the benchmark are built with
  `-O2 -threaded "-with-rtsopts=-maxN4"`, and run with `+RTS -M2G`. The
  exporter writes transcripts, History lines and boards on up to four
  cores (DIVERGENCES.md, internal).
- **Python:** CPython 3.14.6, the pinned reference in
  `upstream/hamsterdan/.venv`.

<!-- bench: superseded -->

| State directory | Shape | Haskell median (min) | Python median (min) | Python / Haskell |
| --- | --- | ---: | ---: | ---: |
| fixture | CLI (fresh process) | 58.6 ms (18.0 ms) | 679.5 ms (501.1 ms) | 11.59× |
| fixture | in process | 6.1 ms (3.9 ms) | 7.7 ms (5.2 ms) | 1.25× |
| host-driven | CLI (fresh process) | 34.6 ms (21.5 ms) | 715.7 ms (603.7 ms) | 20.68× |
| host-driven | in process | 11.2 ms (8.7 ms) | 14.6 ms (10.0 ms) | 1.31× |
| large | CLI (fresh process) | 275.8 ms (220.3 ms) | 1.38 s (911.6 ms) | 4.99× |
| large | in process | 244.8 ms (191.7 ms) | 362.2 ms (265.6 ms) | 1.48× |

The Haskell side is faster on every row. The CLI rows are dominated by
CPython's start-up and imports (about 0.5 s). The in-process rows compare
the export itself. The small state directories spend most of that time
creating directories and copying files, which costs the same on both sides,
so their ratios are close to 1.

## The parallel export, measured

`Hamsterdan.Export.Parallel` decodes History lines and writes files on up
to four cores. Against the same binaries run sequentially (`GHCRTS=-N1`,
under which `parallelMap` is `map` and `writeFiles` writes one file after
another), on 2026-10-12, 12:45–13:00 local (UTC-3), load average 3.7–5.2,
eight runs of the benchmark above (21 runs each), alternating the two
builds' order every round:

<!-- bench: superseded -->

| State directory | Shape | Python / Haskell, parallel (4 runs) | Python / Haskell, sequential (4 runs) | Haskell median, sequential / parallel |
| --- | --- | ---: | ---: | ---: |
| fixture | in process | 1.20–1.25× | 1.23–1.30× | 1.0× |
| host-driven | in process | 1.01–1.05× | 1.04–1.12× | 1.0× |
| large | CLI (fresh process) | 4.40–5.10× | 3.51–3.71× | 1.32× |
| large | in process | 1.24–1.47× | 0.97–1.00× | 1.23× |

On the small state directories the two builds tie: those exports take a
few milliseconds, mostly in file-system calls. On the large one, sequential export is 23% slower in process, level with Python
(Haskell won 5 to 10 of 21 runs per round, against 18 to 21 in parallel),
and 32% slower from the command line: the parallel export stays.

## Rerun

From the repository root (`scripts/bench hamsterdan-export` runs exactly
this block; `scripts/upstream-python hamsterdan` provisions the pinned
reference). The benchmark finds the reference with
`upstreamPythonExecutable` and the binary on `PATH` (cabal puts it there
through `build-tool-depends`) or in `HAMSTERDAN_EXPORT`. It prints the table
above.

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run hamsterdan-export --runs 21 +RTS -M2G -RTS
```

CI's nightly smoke run (`scripts/bench --smoke`, not a measurement):

<!-- scripts/bench: smoke -->
```sh
cd packages/hamsterdan-export && "$BENCH_BIN" --runs 1 +RTS -M2G -RTS
```

Note `uptime` before and after each run. `--repeat STATE OWNER/NAME N`
exports one state directory N times in process (Haskell only), and
`--write-large DIR` only builds the large state directory, both for
profiling.
