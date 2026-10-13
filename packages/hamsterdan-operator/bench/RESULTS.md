# hamsterdan-operator benchmarks

<!-- scripts/bench: measured sources 6c62304c8824cb7f at df073f3106e5 -->

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

Measured on 2026-10-13, 03:02–03:04 local (UTC-3), at commit `df073f3` (after the operator moved onto petrus-json's shared Python value model), on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.64–2.88, by

    scripts/bench-run hamsterdan-operator --runs 21 +RTS -M2G -RTS

One run of the harness: each cell is the median of 21 runs (210 for the in-process rows), the two sides interleaved, with the minimum in parentheses; the last column counts the runs in which Haskell was faster than the Python run paired with it. `qualification-setup` stays close to 1.0× (1.04×, Haskell ahead in 159 of 210; 1.02× at `1d05283`), as in the seven-run table below and for the reason given under it. The hero-review `inspect` reads 1.15× (148 of 210; 863 µs against 989 µs), against 1.19× at `1d05283` (781 µs against 926 µs) and 1.50× at `81bbdc5` (649 µs): since `81bbdc5` the operator reads its JSON with petrus-json's plain `loadsValue` instead of its own fast path (`d354c96`; 1.37× against CPython when that change was measured). In this run both sides of that row read slower than at `1d05283`, Haskell by 10% and Python by 7%. The tables in the sections below are earlier measurements.

| Workload | Shape | Haskell median (min) | Python median (min) | Python / Haskell | Haskell ahead |
| --- | --- | ---: | ---: | ---: | ---: |
| `--help` | CLI (fresh process) | 21.46 ms (16.41 ms) | 699.50 ms (691.80 ms) | 32.60× | 21 of 21 |
| `preflight` | CLI (fresh process) | 134.84 ms (120.10 ms) | 820.08 ms (813.92 ms) | 6.08× | 21 of 21 |
| `inspect --pr 7 --expect-hero-review` (25 fake `gh` calls) | CLI (fresh process) | 596.41 ms (580.72 ms) | 1.34 s (1.30 s) | 2.24× | 21 of 21 |
| inspect, hero review (200 comments, 20 runs of 30 jobs) | in process | 863.0 µs (747.0 µs) | 989.1 µs (958.4 µs) | 1.15× | 148 of 210 |
| inspect-authority (40 rules, 99 reviews, 100 threads) | in process | 91.0 µs (80.0 µs) | 147.1 µs (133.6 µs) | 1.62× | 210 of 210 |
| Git ref projection parse (2000 refs) | in process | 995.0 µs (916.0 µs) | 1.86 ms (1.74 ms) | 1.87× | 210 of 210 |
| qualification-setup success path (scripted Git and gh) | in process | 926.0 µs (850.0 µs) | 965.5 µs (878.5 µs) | 1.04× | 159 of 210 |

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

## The JSON fast path

Provider answers are parsed by `json.loads` of a `str`. The operator used
to read them with its own subset parser, `Hamsterdan.Operator.FastJson`,
before the shared loader. That parser is gone. Its in-place reading of a
`Text` is now `Petrus.Json.Parse.InPlace`, which petrus-json's
`loadsText` tries before its byte parser, so every port's `json.loads` of
a `str` takes the same path. This A/B was measured on 2026-10-12 on the
Apple M4, at a one-minute load average of 4.1–5.5, with the
`inspect` row (`--repeat inspect 210`). The variants ran alternately, and
each figure is the median of the runs' medians:

| variant | `inspect` (210 runs, median of medians) | repetitions |
| --- | ---: | ---: |
| `FastJson` in the operator | 714 µs | 6 |
| petrus-json's byte parser only (`parseJson`, then the scanner on a refusal) | 1.20 ms | 5 |
| petrus-json's `loadsText` with the in-place reader (now) | 790 µs | 6 |

Python's figure was 971.5 µs in "Current figures". So the byte parser alone
would put the row at 0.81×. One harness run with Python interleaved
(`--runs 5`, load 4.1) gave 746 µs against 1.02 ms (1.37×) for the
in-place reader, and 747 µs against 1.06 ms (1.41×) for `FastJson`.

On the 25 documents of one run (112 528 bytes), measured outside the
harness:

- the byte parser took 360 µs;
- the in-place reader took 250 µs, including the conversion to Python
  values;
- `FastJson`, which built the operator's values directly, took 175 µs.

## The allocation area

The binary and the benchmark used to run with a 16 MB allocation area
(`-with-rtsopts=-A16m`); both now run with the RTS defaults (4 MB). Six
full runs of the harness (`--runs 21`) alternated the two settings on
2026-10-12, 16:33–16:50 local, at a one-minute load average of 2.9–3.9:
the binary was built once each way (`HAMSTERDAN_OPERATOR` names it), and
the in-process rows ran with `+RTS -A16m` or `-A4m`. Each figure is the
median over the six runs of each setting's Haskell median; the ratio is
the median of the six paired ratios, `-A16m` time over `-A4m` time (below
1 means `-A16m` was faster):

| Workload | `-A16m` | `-A4m` | `-A16m` / `-A4m` | runs `-A4m` was faster |
| --- | ---: | ---: | ---: | ---: |
| `--help` (fresh process) | 19.93 ms | 20.09 ms | 0.99 | 2 of 6 |
| `preflight` (fresh process) | 133.4 ms | 130.9 ms | 1.01 | 6 of 6 |
| `inspect --pr 7 --expect-hero-review` (fresh process) | 583.3 ms | 575.0 ms | 1.00 | 2 of 6 |
| inspect, hero review (in process) | 765 µs | 882 µs | 0.90 | 1 of 6 |
| inspect-authority (in process) | 104 µs | 97 µs | 1.08 | 4 of 6 |
| Git ref projection parse (in process) | 1.03 ms | 993 µs | 1.04 | 5 of 6 |
| qualification-setup (in process) | 945 µs | 959 µs | 0.99 | 2 of 6 |

A command's run, which is what ships, did not get faster with `-A16m`.
Of the in-process rows, only the hero-review `inspect` did: it parses 25
provider answers (112 KB) per run, and a larger nursery collects less
often. Two others were faster with the default. So the binary keeps the
default, and the benchmark keeps the binary's settings.

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

CI's smoke run on a `full` dispatch (`scripts/bench --smoke`, not a measurement):

<!-- scripts/bench: smoke -->
```sh
cd packages/hamsterdan-operator && "$BENCH_BIN" --runs 1 +RTS -M2G -RTS
```

Note `uptime` before and after each run. For profiling,
`--repeat NAME N` runs one in-process workload N times, Haskell only
(`inspect`, `authority`, `refs` or `setup`). It prints the median and
minimum wall clock and the mean CPU time per run, and combines with
`+RTS -s`.
