# hamsterdan-operator benchmarks

<!-- scripts/bench: measured sources adbbe4679becb0b0 at 5a73d7a7f019 -->

Seven workloads, in two shapes, all timed by wall clock (monotonic) on
both sides.

**CLI (fresh process):** `python -I -B -m hamsterdan.operator` against the
`hamsterdan-operator` binary. Each run is a fresh process with the same
arguments, in one of two directories laid out the same way. `PATH` starts
with scripted fakes of `gh` and `git` (the benchmark binary in its
`--fake-provider` mode, as in the test suite's differential). Interpreter
and runtime start-up and every fake process are included, because an
operator pays for them.

- `--help`;
- `preflight`, with five provider answers;
- `inspect --pr 7 --expect-hero-review`, with 25 fake `gh` calls.

**In process:** each operation is called again and again inside one
long-lived interpreter (`bench/bench.py`), and again and again inside the
benchmark process. Both sides use a scripted runner that answers from the
same table. Start-up is excluded.

- `inspect` with the hero-review checks, over 200 comments and 20 workflow
  runs of 30 jobs;
- `inspect-authority` (`collaboration-clear`), over 40 ruleset rules, 99
  reviews and 100 review threads;
- the Git ref projection parse (`_parse_setup_refs`), over 2000 refs;
- `qualification-setup` along its whole success path:
  - preflight fences;
  - consuming both private inputs;
  - the managed temporary root and its three directories;
  - the scripted fixture Git and `gh` calls;
  - the atomic push with its `fsync`ed spent marker;
  - the cleanup.

  Its two input files are written, and the spent marker removed, before
  each run, outside the timed region.

Before anything is timed, each in-process workload runs once on each side,
and the two results must be the same JSON (`json.dumps(result,
sort_keys=True)`). Each CLI workload must exit with the same status and
print the same output on both sides.

Both shapes interleave the two sides run by run, and the order flips every
run, so both meet the same machine and file-system state. Each cell is the
median, with the minimum in parentheses: 21 runs per CLI row, 210 runs per
in-process row.

## Current figures

Measured on 2026-10-12, 03:58–04:00 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.63–3.00, by

    scripts/bench-run hamsterdan-operator --runs 21 +RTS -M2G -RTS

One run of the harness: each cell is the median of 21 runs, the two sides interleaved, with the minimum in parentheses. `qualification-setup` stays close to 1.0×, as in the seven-run table below and for the reason given under it. The tables in the sections below are earlier measurements.

| Workload | Shape | Haskell median (min) | Python median (min) | Python / Haskell |
| --- | --- | ---: | ---: | ---: |
| `--help` | CLI (fresh process) | 20.77 ms (17.74 ms) | 692.06 ms (683.13 ms) | 33.32× |
| `preflight` | CLI (fresh process) | 129.51 ms (117.51 ms) | 812.42 ms (803.66 ms) | 6.27× |
| `inspect --pr 7 --expect-hero-review` (25 fake `gh` calls) | CLI (fresh process) | 592.46 ms (568.26 ms) | 1.30 s (1.29 s) | 2.20× |
| inspect, hero review (200 comments, 20 runs of 30 jobs) | in process | 649.0 µs (593.0 µs) | 971.5 µs (918.7 µs) | 1.50× |
| inspect-authority (40 rules, 99 reviews, 100 threads) | in process | 76.0 µs (66.0 µs) | 147.6 µs (133.3 µs) | 1.94× |
| Git ref projection parse (2000 refs) | in process | 939.0 µs (883.0 µs) | 1.83 ms (1.71 ms) | 1.95× |
| qualification-setup success path (scripted Git and gh) | in process | 934.0 µs (860.0 µs) | 954.6 µs (872.2 µs) | 1.02× |

## Results

Seven full runs on 2026-10-11, 06:40–06:52 local (UTC-3), at commit
`b7c4c1e`, one after another, each started once the 1-minute load average
was 3 or below (1.84–3.39 around the runs). Each run interleaves the two
sides itself, as described above. Each figure below is the median of the
seven runs' medians, with the lowest minimum in parentheses. The ratio is
the median of the seven runs' ratios; the next columns give the lowest
run's ratio and the runs Haskell won.

- **Haskell:** GHC 9.10.3. The binary and the benchmark are built with
  `-O2 -threaded "-with-rtsopts=-A16m"`, and run with `+RTS -M2G`.
- **Python:** CPython 3.14.6, the pinned reference in
  `upstream/hamsterdan/.venv`.

<!-- bench: superseded -->

| Workload | Shape | Haskell median (min) | Python median (min) | Python / Haskell | Lowest run | Runs Haskell faster |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `--help` | CLI (fresh process) | 21.87 ms (16.78 ms) | 704.29 ms (693.38 ms) | 32.56× | 31.57× | 7/7 |
| `preflight` | CLI (fresh process) | 134.21 ms (118.17 ms) | 831.35 ms (811.28 ms) | 6.26× | 6.09× | 7/7 |
| `inspect --pr 7 --expect-hero-review` (25 fake `gh` calls) | CLI (fresh process) | 598.50 ms (571.27 ms) | 1.34 s (1.28 s) | 2.24× | 2.20× | 7/7 |
| inspect, hero review (200 comments, 20 runs of 30 jobs) | in process | 659.0 µs (578.0 µs) | 972.9 µs (909.4 µs) | 1.48× | 1.23× | 7/7 |
| inspect-authority (40 rules, 99 reviews, 100 threads) | in process | 76.0 µs (64.0 µs) | 149.5 µs (129.1 µs) | 1.95× | 1.71× | 7/7 |
| Git ref projection parse (2000 refs) | in process | 991.0 µs (901.0 µs) | 1.83 ms (1.69 ms) | 1.85× | 1.56× | 7/7 |
| qualification-setup success path (scripted Git and gh) | in process | 910.0 µs (812.0 µs) | 924.0 µs (845.7 µs) | 1.04× | 1.01× | 7/7 |

The Haskell side is faster on every row, in every run.
`qualification-setup` read 1.01×, 1.04×, 1.04×, 1.04×, 1.04×, 1.05× and
1.04× run by run, and Haskell's minimum was below the reference's in each.

- **CLI rows.** CPython's start-up and imports (about 0.7 s) dominate
  them. In the `inspect` row, the 25 fake `gh` processes, which both sides
  spawn, take most of the remaining time.
- **In-process rows.** These compare the operations themselves.

### The run before (2026-10-11, 02:08–02:10)

<!-- bench: superseded -->

One run, on top of `e170b69` with this package's changes, load average
4.6–5.5. Each cell is the median, with the minimum in parentheses.
| Workload | Shape | Haskell median (min) | Python median (min) | Python / Haskell |
| --- | --- | ---: | ---: | ---: |
| `--help` | CLI (fresh process) | 21.14 ms (17.71 ms) | 484.46 ms (437.89 ms) | 22.91× |
| `preflight` | CLI (fresh process) | 137.84 ms (127.51 ms) | 631.78 ms (558.57 ms) | 4.58× |
| `inspect --pr 7 --expect-hero-review` (25 fake `gh` calls) | CLI (fresh process) | 629.67 ms (602.42 ms) | 1.14 s (1.10 s) | 1.82× |
| inspect, hero review (200 comments, 20 runs of 30 jobs) | in process | 810.0 µs (617.0 µs) | 1.06 ms (978.3 µs) | 1.31× |
| inspect-authority (40 rules, 99 reviews, 100 threads) | in process | 82.0 µs (72.0 µs) | 148.8 µs (143.8 µs) | 1.82× |
| Git ref projection parse (2000 refs) | in process | 1.20 ms (1.03 ms) | 1.99 ms (1.89 ms) | 1.67× |
| qualification-setup success path (scripted Git and gh) | in process | 995.0 µs (830.0 µs) | 1.06 ms (881.6 µs) | 1.06× |

### Why `qualification-setup` is close to 1.0×

Almost all of this workload's time is in the kernel. Both sides make the
same costly system calls:

- four `mkdir`s and three `chmod`s;
- the same file creations and writes;
- two `fsync`s;
- the walk that removes the root: four directory opens and listings, and
  six removals.

A libc interposer counted every file-system call over 1000 runs of each
side (outside these tables). The Haskell side made about 100 calls per run
and the reference about 200. The extra ones are cheap: mostly `lstat`,
`fstat` and `lseek` from `pathlib` and the `io` layer. The time spent inside those calls was about the same as the
whole run on both sides.

So the ratio moves with the machine's load. Over the four full runs made
with the final code at load 4.6–5.5, the row read 0.97×, 1.04×, 1.04× and
1.06×; over the seven at load 1.8–3.4 in the table above, 1.01–1.05×. The
Haskell minimum was lower than the reference's in every run.

The row moved from below 1.0× to these figures when the cleanup's
`shutil.rmtree` became CPython's descriptor-relative walk
(DIVERGENCES.md, internal). Before that, it used the `directory` package's
path-based removal, which resolved the full temporary path again for each
of eleven removals.

### Where the walk and the `stat` calls live (2026-10-12)

The `stat` calls and the `shutil.rmtree` walk moved from this package's
`cbits/` to petrus-posix (`Petrus.Posix.At`), the one system layer the
other packages share. The walk was first rewritten there over the
package's existing `openat` primitives, one foreign call per system call.
Interleaved on the Apple M4 at load 3.5–8, that version cost the row its
lead:

- `--repeat setup 2000`, Haskell only: 944, 934 and 936 µs against 892,
  873 and 874 µs for the C walk (medians of the calmer repetitions);
- the full harness (`--runs 21`), four repetitions each: 1.00×, 1.00×,
  1.00× and 1.00× against 1.05×, 1.02×, 1.05× and 1.03×.

A `sample` profile put the difference in the walk, not the `stat` calls:
each safe foreign call pauses the thread (`threadPaused`, 134 samples
against 61), and more time went to reading the listings
(`getdirentries64`, 50 samples against 19). So the walk
stayed one C function, moved unchanged to petrus-posix (`petrus_rmtree`,
whose comment points here), behind `Petrus.Posix.At.rmtree`. Against the
build with the walk still in this package, four interleaved full runs read
1.05×, 1.02×, 1.02× and 1.04× with the walk in petrus-posix, and 1.02×,
1.03×, 1.02× and 1.03× before (load 3.5–4.8): the same.

## Rerun

From the repository root (`scripts/bench hamsterdan-operator` runs exactly
this block; `scripts/upstream-python hamsterdan` provisions the pinned
reference). The benchmark finds:

- the reference with `upstreamPythonExecutable`;
- the binary on `PATH` (cabal puts it there through `build-tool-depends`).

It prints the table above.

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run hamsterdan-operator --runs 21 +RTS -M2G -RTS
```

CI's nightly smoke run (`scripts/bench --smoke`, not a measurement):

<!-- scripts/bench: smoke -->
```sh
cd packages/hamsterdan-operator && "$BENCH_BIN" --runs 1 +RTS -M2G -RTS
```

Note `uptime` before and after each run. For profiling,
`--repeat NAME N` runs one in-process workload N times, Haskell only
(`inspect`, `authority`, `refs` or `setup`). It prints the median and
minimum wall clock and the mean CPU time per run, and combines with
`+RTS -s`.
