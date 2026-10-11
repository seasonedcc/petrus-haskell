# hamsterdan-operator benchmarks

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

## Results

The machine was an Apple M4 (10 cores) running macOS 26.3.1, shared with
other work. The load average was 4.6–5.5 during the run (2026-10-11,
02:08–02:10 local, UTC-3, on top of `e170b69` with this package's
changes).

- **Haskell:** GHC 9.10.3. The binary and the benchmark are built with
  `-O2 -threaded "-with-rtsopts=-A16m"`, and run with `+RTS -M2G`.
- **Python:** CPython 3.14.6, the pinned reference in
  `upstream/hamsterdan/.venv`.

| Workload | Shape | Haskell median (min) | Python median (min) | Python / Haskell |
| --- | --- | ---: | ---: | ---: |
| `--help` | CLI (fresh process) | 21.14 ms (17.71 ms) | 484.46 ms (437.89 ms) | 22.91× |
| `preflight` | CLI (fresh process) | 137.84 ms (127.51 ms) | 631.78 ms (558.57 ms) | 4.58× |
| `inspect --pr 7 --expect-hero-review` (25 fake `gh` calls) | CLI (fresh process) | 629.67 ms (602.42 ms) | 1.14 s (1.10 s) | 1.82× |
| inspect, hero review (200 comments, 20 runs of 30 jobs) | in process | 810.0 µs (617.0 µs) | 1.06 ms (978.3 µs) | 1.31× |
| inspect-authority (40 rules, 99 reviews, 100 threads) | in process | 82.0 µs (72.0 µs) | 148.8 µs (143.8 µs) | 1.82× |
| Git ref projection parse (2000 refs) | in process | 1.20 ms (1.03 ms) | 1.99 ms (1.89 ms) | 1.67× |
| qualification-setup success path (scripted Git and gh) | in process | 995.0 µs (830.0 µs) | 1.06 ms (881.6 µs) | 1.06× |

The Haskell side is faster on every row.

- **CLI rows.** CPython's start-up and imports (about 0.5 s) dominate
  them. In the `inspect` row, the 25 fake `gh` processes, which both sides
  spawn, take most of the remaining time.
- **In-process rows.** These compare the operations themselves.

### `qualification-setup` sits at about 1.0×

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
with the final code, the row read 0.97×, 1.04×, 1.04× and 1.06×. The
Haskell minimum was lower than the reference's in each run.

The row moved from below 1.0× to these figures when the cleanup's
`shutil.rmtree` became CPython's descriptor-relative walk
(DIVERGENCES.md, internal). Before that, it used the `directory` package's
path-based removal, which resolved the full temporary path again for each
of eleven removals.

## Rerun

From the repository root (`scripts/bench hamsterdan-operator` runs exactly
this block; `scripts/upstream-python hamsterdan` provisions the pinned
reference). The benchmark finds:

- the reference with `upstreamPythonExecutable`;
- the binary on `PATH` (cabal puts it there through `build-tool-depends`).

It prints the table above.

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 hamsterdan-operator --benchmark-options="--runs 21 +RTS -M2G -RTS"
```

Note `uptime` before and after each run. For profiling,
`--repeat NAME N` runs one in-process workload N times, Haskell only
(`inspect`, `authority`, `refs` or `setup`). It prints the median and
minimum wall clock and the mean CPU time per run, and combines with
`+RTS -s`.
