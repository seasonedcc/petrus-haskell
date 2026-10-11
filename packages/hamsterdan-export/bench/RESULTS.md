# hamsterdan-export benchmarks

<!-- scripts/bench: measured sources 3065c49862aff3a1 at 96eda46a7fc2 -->

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

## Rerun

From the repository root (`scripts/bench hamsterdan-export` runs exactly
this block; `scripts/upstream-python hamsterdan` provisions the pinned
reference). The benchmark finds the reference with
`upstreamPythonExecutable` and the binary on `PATH` (cabal puts it there
through `build-tool-depends`) or in `HAMSTERDAN_EXPORT`. It prints the table
above.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 hamsterdan-export --benchmark-options="--runs 21 +RTS -M2G -RTS"
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
