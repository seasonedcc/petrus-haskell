# petrus-execution benchmark results

<!-- scripts/bench: measured sources 7cf3376d497fc91b at df073f3106e5 -->
<!-- scripts/bench: carried to 20920a39590e067f at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: the Docker and Gondolin providers' local truthy are petrus-json's pythonTruthy, the same seven equations; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to 018978b0d1b7a657 at b4d1ccb669ad: since f87d05b, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only -->

The Haskell port compared with upstream Python Petrus (`petrus.motus.execution` /
`_execution` at the pin in [UPSTREAM.md](../../../UPSTREAM.md)). Both harnesses run the same
workloads, iteration counts and operations:

| Benchmark | Operation (upstream / Haskell) | Iterations per round |
| --- | --- | --- |
| `archive/<w>/pack+sha256` | `workspace_archive(tree)` + SHA-256 hex / `workspaceArchive` + `archiveDigest` | 7 |
| `archive/<w>/validate` | `validate_workspace_archive` / `validateWorkspaceArchive` | 7 |
| `archive/<w>/extract` | `extract_workspace_archive` into a fresh directory / `extractWorkspaceArchive` | 7 |
| `process/run-captured` | `subprocess.run(("/usr/bin/true",), capture_output=True, timeout=5)` / `runCaptured` | 100 |
| `local/execute` | `LocalProcessEnvironment.execute(attachment, Command(("/bin/sh", "-c", "/bin/cat input")))` / `providerExecute` of the Local provider | 50 |
| `sidecar/handshake-round-trip` | `GondolinEnvironment._request(record, {"action": "handshake"})` / `sidecarRequest` | 1000 |
| `sidecar/execute-round-trip` | `environment.execute(attachment, Command(("/bin/sh", "-c", "true")))` / `providerExecute` | 50 |

Workloads (`make_workloads.py`, seeded pseudo-random contents):

- `many-small`: 10 000 files of 1 KiB in 100 directories
- `medium`: 1 000 files of 64 KiB in 10 directories
- `one-large`: 1 file of 256 MiB

The sidecar benchmarks provision one real territory through each implementation's provider. The
territory runs upstream's verbatim `gondolin_sidecar.mjs` on Node, backed by the committed fake
Gondolin SDK (`test/fixtures/fake_gondolin.mjs`). The Node-side work is the same for both, so
these rows measure each client's socket, framing, registry and JSON costs on top of a shared
fixed cost.

## Environment

- Apple M4 (10 cores), macOS 26.3.1, APFS SSD
- Python 3.14.6 (`upstream/petrus/.venv`), GHC 9.10.3 with `-O2 -threaded`, Node v22.22.0 for the sidecar
- 2026-10-10, on a shared machine: other builds and benchmarks kept the load average between 3.8 and 6

## Method

`compare.py` alternates the two harnesses for N rounds (odd rounds Python first, even rounds Haskell first; until 2026-10-12 Python always went first), so both
see the same machine state. Each harness reports one median per benchmark per round. The table
shows the median of those per-round medians. A ratio above 1 means Haskell is faster.

## Current figures

### 2026-10-13, at `df073f3`

Measured on 2026-10-13, 03:33–03:36 local (UTC-3), at commit `df073f3`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 3.16–3.28, by

    "$(scripts/upstream-python)" -B packages/petrus-execution/bench/compare.py WORKDIR 3

Three rounds, alternating which harness goes first; each figure is the
median of the per-round medians, "lowest per round" is the worst round's
ratio, and the last column counts the rounds Haskell won. The archive rows:

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | lowest per round | Haskell ahead |
|---|---:|---:|---:|---:|---:|
| archive/many-small/pack+sha256 | 495.149 | 190.441 | 2.60x | 2.46x | 3 of 3 |
| archive/many-small/validate | 90.375 | 31.831 | 2.84x | 2.80x | 3 of 3 |
| archive/many-small/extract | 1201.405 | 923.412 | 1.30x | 1.29x | 3 of 3 |
| archive/medium/pack+sha256 | 88.091 | 43.084 | 2.04x | 1.73x | 3 of 3 |
| archive/medium/validate | 9.003 | 2.936 | 3.07x | 2.76x | 3 of 3 |
| archive/medium/extract | 158.343 | 118.602 | 1.34x | 1.11x | 3 of 3 |
| archive/one-large/pack+sha256 | 188.843 | 105.820 | 1.78x | 1.68x | 3 of 3 |
| archive/one-large/validate | 0.077 | 0.007 | 11.03x | 11.00x | 3 of 3 |
| archive/one-large/extract | 155.169 | 110.464 | 1.40x | 1.18x | 3 of 3 |

The rows without archive workloads read, in those three rounds, 1.81x
(run-captured), 1.38x (local execute), 1.02x (handshake, 3 of 3) and 1.39x
(execute round trip, 2 of 3, 0.92x at the lowest). The two sidecar rows
were under 1.15×, so those rows got two more rounds (04:02, load average
3.10–3.20), where the execute round trip read 0.96x (Haskell ahead in 0
of 2) and the handshake 1.08x. `compare.py` keeps only each run's medians,
so runs cannot be pooled; the rows were therefore measured again in five
rounds of their own, 04:20 local, load average 3.67–3.89, by

    PETRUS_BENCH_ONLY=none "$(scripts/upstream-python)" -B packages/petrus-execution/bench/compare.py WORKDIR 5

which are the figures for those rows:

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | lowest per round | Haskell ahead |
|---|---:|---:|---:|---:|---:|
| process/run-captured | 1.292 | 0.779 | 1.66x | 1.55x | 5 of 5 |
| local/execute | 3.779 | 3.031 | 1.25x | 1.21x | 5 of 5 |
| sidecar/handshake-round-trip | 0.031 | 0.031 | 1.01x | 0.97x | 4 of 5 |
| sidecar/execute-round-trip | 4.994 | 4.772 | 1.05x | 1.00x | 4 of 5 |

The sidecar rows are level, as in every run before (below): most of each
round trip is the shared Node sidecar, and the execute round trip swings
by several hundred microseconds between runs on either side. The change
measured here (petrus-posix's `writeAll` and `linkAt` in extraction, and
petrus-json's `pythonDict` in `mkCommand`) leaves the extract rows ahead of
Python by 1.30–1.40x.

### The sidecar rows, 2026-10-13, at `c0cb6cb`: the clock and the connect timer (superseded)

<!-- bench: superseded -->

Eleven alternating rounds of the rows without archive workloads on
2026-10-12 (load average 2.5–3.3), by

    PETRUS_BENCH_ONLY=none "$(scripts/upstream-python)" -B packages/petrus-execution/bench/compare.py WORKDIR 11

read the handshake at 0.031 ms against Python's 0.032 ms, 0.98×, Haskell ahead
in 2 of 11 rounds, where eleven rounds at `fc77e8d` on 2026-10-11 had read
1.02× (6 of 11); the execute round trip was level at 1.02× (6 of 11). Three
things were found:

- **The wait did not change.** At `fc77e8d` `exchange` already waited for the
  answer in an `interruptible` `poll` on the calling thread; the POSIX
  consolidation moved that wait into `Petrus.Posix.Poll` (adding its 50 ms
  slices, which a 30 µs answer never reaches). Waiting on GHC's IO manager
  instead (`timeout` around `threadWaitRead`) is slower here too: 31.02 µs
  against 30.46 µs, the poll faster in 6 of 7 interleaved rounds.
- **The Haskell harness timed in whole microseconds.** `bench/Main.hs` read
  `GHC.Clock.getMonotonicTime`, which on macOS is CLOCK_MONOTONIC at 1 µs
  resolution, while the twin's `time.perf_counter` is `mach_absolute_time`
  (41.7 ns ticks). Each 30 µs sample was rounded to a whole microsecond, so
  the Haskell median could only read 31 or 32 µs: 1.02× or 0.98× against the
  same Python figure, a 3% step that decided the "Haskell ahead" count. The
  harness now reads CLOCK_UPTIME_RAW (`clock_gettime_nsec_np`, the clock
  behind `perf_counter`) on macOS; on Linux both read CLOCK_MONOTONIC in
  nanoseconds, as before. With that clock and the library unchanged, two
  runs of eleven interleaved rounds read 31.04 µs against Python's 32.44 µs
  and 31.10 µs against 31.27 µs: level.
- **A timer Python does not pay.** `exchange` wrapped both the connect and
  the send in `System.Timeout.timeout`, and each one registers and cancels a
  timer with the IO manager's timer thread: about 0.55–0.68 µs per call in a
  tight loop. The connect's never fired: a Unix-socket connect never waits
  (the kernel connects or refuses at once, and network's `connect` waits
  only on `EINPROGRESS`), as under CPython's `settimeout`. It is gone; the
  send keeps its timer, since a large request can wait for the sidecar to
  read. Interleaved with the previous build over eleven rounds each:
  31.10 → 30.46 µs (faster in 8 of 11) and 31.65 → 31.04 µs (faster in 7 of
  11), with Python at 31.27 and 31.42 µs in the same rounds.

With both changes, eleven alternating rounds at 00:05–00:06 on 2026-10-13
(load average 2.4–2.8), by the command above:

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | lowest per round | Haskell ahead |
|---|---:|---:|---:|---:|---:|
| process/run-captured | 1.331 | 0.751 | 1.77x | 1.38x | 11 of 11 |
| local/execute | 3.716 | 3.016 | 1.23x | 1.03x | 11 of 11 |
| sidecar/handshake-round-trip | 0.031 | 0.031 | 1.00x | 0.95x | 5 of 11 |
| sidecar/execute-round-trip | 4.837 | 4.404 | 1.10x | 0.95x | 8 of 11 |

The handshake is level with Python: about 31 µs on both sides, most of it
the shared Node sidecar, with round-to-round swings of ±1.5 µs on either side
that exceed the remaining difference. It was not investigated further. The
archive rows below were not remeasured. Superseded by the run at `df073f3`
above.

### 2026-10-12, at `d85b420`: the archive rows (superseded)

<!-- bench: superseded -->

Measured on 2026-10-12, 23:31–23:33 local (UTC-3), at commit `d85b420`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 3.10–5.00, by

    "$(scripts/upstream-python)" -B packages/petrus-execution/bench/compare.py WORKDIR 3

Three rounds, alternating which harness goes first; each figure is the median of the per-round medians, "lowest per round" is the worst round's ratio, and the last column counts the rounds Haskell won. On the GitHub-hosted Linux runner `archive/one-large/extract` comes out a few percent behind Python (58.7 ms against 56.6 ms, 0.96×, with 64 KiB or 128 KiB writes alike). The time there is the kernel's: a bare 256 MiB `write(2)` loop on that runner takes 58–67 ms, so `scripts/bench-gate` checks `archive/medium/extract` instead. The tables in the sections below are earlier measurements.

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | lowest per round | Haskell ahead |
|---|---:|---:|---:|---:|---:|
| archive/many-small/pack+sha256 | 499.764 | 184.277 | 2.71x | 2.66x | 3 of 3 |
| archive/many-small/validate | 91.018 | 29.994 | 3.03x | 2.99x | 3 of 3 |
| archive/many-small/extract | 1199.188 | 904.162 | 1.33x | 1.31x | 3 of 3 |
| archive/medium/pack+sha256 | 89.469 | 42.853 | 2.09x | 2.05x | 3 of 3 |
| archive/medium/validate | 9.239 | 2.840 | 3.25x | 2.53x | 3 of 3 |
| archive/medium/extract | 182.094 | 133.110 | 1.37x | 1.37x | 3 of 3 |
| archive/one-large/pack+sha256 | 198.565 | 105.138 | 1.89x | 1.79x | 3 of 3 |
| archive/one-large/validate | 0.079 | 0.009 | 8.76x | 2.63x | 3 of 3 |
| archive/one-large/extract | 202.839 | 169.896 | 1.19x | 0.93x | 2 of 3 |

`archive/one-large/extract` (one 256 MiB file) read 1.19× here, Haskell
ahead in 2 of 3 rounds.

### 2026-10-13: extraction writes, petrus-posix's safe write against the unsafe loop (A/B)

<!-- bench: superseded -->

An A/B record, not a headline result (the marker keeps its rows out of the
summary). Extraction used to write each file in 64 KiB `write(2)` calls made
through an `unsafe` foreign import of its own, said to save "~10%" of a 256
MiB extraction. It now calls petrus-posix's `writeAll` (one `safe` `write(2)`
per call over the whole buffer, looping on short writes), and `os.link` is
petrus-posix's `linkAt`. Both builds were the same source but for the write
(`clean` is the committed code; `unsafe` restored the old loop), measured on
2026-10-13 on the Apple M4 with Python's harness in the same rounds, each
round rotating which of the three runs first.

Seven rounds of every archive workload, 01:58–02:04 local (UTC-3), 1-minute
load average 1.99 → 2.96:

| benchmark | Python (ms) | clean (ms) | unsafe (ms) | Python / clean | Python / unsafe | clean ahead of unsafe |
|---|---:|---:|---:|---:|---:|---:|
| archive/many-small/extract | 1132.793 | 871.483 | 894.703 | 1.30x | 1.27x | 6 of 7 |
| archive/medium/extract | 174.161 | 143.073 | 125.431 | 1.22x | 1.39x | 3 of 7 |
| archive/one-large/extract | 266.406 | 116.861 | 145.897 | 2.28x | 1.83x | 4 of 7 |

The pack and validate rows do not write; they moved by noise (0.95–1.05
between the builds by the median of the rounds).

`archive/medium/extract` is the row `scripts/bench-gate` checks, so it got
twelve more rounds of its own (`PETRUS_BENCH_ONLY=medium`, 02:05–02:06,
load average 3.26):

| benchmark | Python (ms) | clean (ms) | unsafe (ms) | Python / clean | Python / unsafe | clean ahead of unsafe |
|---|---:|---:|---:|---:|---:|---:|
| archive/medium/extract | 149.555 | 133.654 | 130.241 | 1.12x | 1.15x | 5 of 12 |

Clean was ahead of Python in 9 of the 12 rounds (median of the per-round
ratios 1.11, lowest 0.90), unsafe in 10 (1.22, lowest 0.75). The two builds
are within each other's noise on every extract row (clean's time over
unsafe's, by the median of the rounds: 0.98 many-small, 1.19 and 1.06
medium, 0.82 one-large), and the safe write keeps extraction ahead of
Python on all three, so the unsafe loop was removed.

### 2026-10-12, at `d85b420`: the other rows (superseded)

<!-- bench: superseded -->

The same three rounds' other rows, superseded by the 2026-10-13 run above;
the Haskell side here still timed in whole microseconds:

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | lowest per round | Haskell ahead |
|---|---:|---:|---:|---:|---:|
| process/run-captured | 1.450 | 0.784 | 1.85x | 1.73x | 3 of 3 |
| local/execute | 4.748 | 3.258 | 1.46x | 1.25x | 3 of 3 |
| sidecar/handshake-round-trip | 0.028 | 0.031 | 0.91x | 0.83x | 1 of 3 |
| sidecar/execute-round-trip | 5.737 | 5.001 | 1.15x | 0.99x | 2 of 3 |

The two sidecar rows are the thin ones, as in every run before this one:
the sidecar is the shared Node process (below), and a handshake is one
Unix-socket exchange of about 30 µs on both sides. In the three rounds
above the handshake read 0.91× (Haskell ahead in 1 of 3) and the execute
round trip 1.15× (2 of 3). Both were under 1.15×, so they got two more
rounds of the rows without archive workloads (23:40, load average
4.13–4.31), by

    PETRUS_BENCH_ONLY=none "$(scripts/upstream-python)" -B packages/petrus-execution/bench/compare.py WORKDIR 2

which gave:

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | lowest per round | Haskell ahead |
|---|---:|---:|---:|---:|---:|
| process/run-captured | 1.347 | 0.789 | 1.71x | 1.62x | 2 of 2 |
| local/execute | 3.831 | 3.204 | 1.20x | 1.16x | 2 of 2 |
| sidecar/handshake-round-trip | 0.033 | 0.031 | 1.05x | 0.99x | 1 of 2 |
| sidecar/execute-round-trip | 4.960 | 5.179 | 0.96x | 0.92x | 0 of 2 |

Over the five rounds Haskell was ahead in 2 of 5 on each sidecar row: the
handshake reads 0.91× and 1.05× in the two runs, the execute round trip
1.15× and 0.96×. `compare.py` keeps only each run's medians, so the five
rounds are not pooled into one figure. These rows are level, as the
earlier runs below found (1.01× and 1.04× at `81bbdc5`, 1.02× and 1.00×
on a quiet machine on 2026-10-11); they were not investigated further.

## Results

`compare.py`, 5 interleaved rounds (archive rows):

<!-- bench: superseded -->

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell |
|---|---:|---:|---:|
| archive/many-small/pack+sha256 | 521.973 | 185.141 | 2.82x |
| archive/many-small/validate | 96.875 | 42.098 | 2.30x |
| archive/many-small/extract | 1209.079 | 948.332 | 1.27x |
| archive/medium/pack+sha256 | 81.898 | 42.829 | 1.91x |
| archive/medium/validate | 9.437 | 4.478 | 2.11x |
| archive/medium/extract | 155.494 | 123.061 | 1.26x |
| archive/one-large/pack+sha256 | 131.149 | 111.167 | 1.18x |
| archive/one-large/validate | 0.080 | 0.010 | 7.97x |
| archive/one-large/extract | 152.094 | 133.841 | 1.14x |
| process/run-captured | 1.276 | 0.759 | 1.68x |
| local/execute | 3.918 | 3.119 | 1.26x |
| sidecar/handshake-round-trip | 0.032 | 0.031 | 1.02x |
| sidecar/execute-round-trip | 4.862 | 4.841 | 1.00x |

The archive rows come from these five rounds (2026-10-10). The process and sidecar rows come from
the eleven alternating rounds on a quiet machine below (2026-10-11); in these five rounds they
read 1.85x, 1.00x and 0.98x. The `local/execute` row comes from its own eleven rounds
(2026-10-11 10:42, below).

### The Local execute row, 2026-10-11 10:42

`local/execute` times `LocalProcessEnvironment.execute` in an attached territory holding one
file: the containment checks on the territory and its working directory, the spawn of
`/bin/sh -c "/bin/cat input"` in it, and collecting its output and exit status. It was run for
11 rounds that alternate which harness goes first (`PETRUS_BENCH_ONLY=none`, with the fake
Gondolin SDK), with the 1-minute load average at 3.9–4.2:

<!-- bench: superseded -->

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | Lowest round | rounds Haskell won |
|---|---:|---:|---:|---:|---:|
| process/run-captured | 1.304 | 0.769 | 1.70x | 1.64x | 11/11 |
| local/execute | 3.918 | 3.119 | 1.26x | 1.18x | 11/11 |

Most of `local/execute` is the `sh` and `cat` child processes, which both sides pay alike. In
the same rounds, the two sidecar rows read 0.97x (handshake, 0.028 ms against 0.029 ms,
Haskell ahead in 4 of 11) and 1.07x (execute, 9 of 11) at the higher load; the headline
figures for those rows stay the quiet-machine run below.

### Sidecar rows alone, 2026-10-10

<!-- bench: superseded -->

The two sidecar rows were within noise, so they were run again on their own for 10 interleaved
rounds (`PETRUS_BENCH_ONLY=none`, which skips the archive workloads):

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | rounds Haskell won |
|---|---:|---:|---:|---:|
| process/run-captured | 1.529 | 0.846 | 1.81x | 10/10 |
| sidecar/handshake-round-trip | 0.033 | 0.033 | 1.01x | 7/10 |
| sidecar/execute-round-trip | 6.463 | 6.613 | 0.98x | 6/10 |

### Sidecar rows on a quiet machine, 2026-10-11 07:46

The rows without archive workloads (`PETRUS_BENCH_ONLY=none`) were rerun
for 11 rounds that alternate which harness goes first, at commit `fc77e8d`,
with the 1-minute load average at 2.18–2.33. Each harness reports its
median per round (50 executes, 1000 handshakes, 100 spawns); the table
gives the median of the rounds, the lowest round's ratio, and the rounds
Haskell won:

<!-- bench: superseded -->

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | Lowest round | rounds Haskell won |
|---|---:|---:|---:|---:|---:|
| process/run-captured | 1.276 | 0.759 | 1.68x | 1.67x | 11/11 |
| sidecar/handshake-round-trip | 0.032 | 0.031 | 1.02x | 0.80x | 6/11 |
| sidecar/execute-round-trip | 4.862 | 4.841 | 1.00x | 0.97x | 7/11 |

The execute row is level: 4.84 ms against 4.86 ms, Haskell ahead in seven
of eleven rounds, every round within 3%. Almost all of it is the shared
Node sidecar spawning `sh` (below), which neither client controls. The
handshake row's lowest round is one Python round at 0.025 ms; the other
rounds sat at 0.030–0.034 ms on both sides.

### Sidecar rows rerun, 2026-10-11 00:35–00:38

<!-- bench: superseded -->

The sidecar rows were rerun on 2026-10-11 00:35–00:38 local, at a 1-minute
load average of 5.6–6.2 (other agents' builds and benchmarks), to check
whether the 0.98× above had a cause in the client. First `compare.py` with
`PETRUS_BENCH_ONLY=none` for 10 rounds (Python first in every round), then
12 rounds that alternate which harness goes first, keeping every round's
medians:

| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | rounds Haskell won |
|---|---:|---:|---:|---:|
| process/run-captured (10 rounds) | 1.589 | 0.952 | 1.67x | |
| sidecar/handshake-round-trip (10 rounds) | 0.088 | 0.082 | 1.08x | |
| sidecar/execute-round-trip (10 rounds) | 6.461 | 6.455 | 1.00x | |
| process/run-captured (12 alternating rounds) | 1.519 | 0.905 | 1.68x | 12/12 |
| sidecar/handshake-round-trip (12 alternating rounds) | 0.079 | 0.068 | 1.16x | 7/12 |
| sidecar/execute-round-trip (12 alternating rounds) | 6.416 | 6.301 | 1.02x | 6/12 |

Nothing in these rows touches PostgreSQL. An execute is the same three steps
on both sides: read and check the registry, one handshake exchange, and the
execute exchange, in which the Node sidecar spawns `sh`. The client's own
share (the handshake row) is faster in Haskell. The execute exchange is the
shared Node process spawning `sh`, about 6 ms, and neither client controls
it; the two sides trade rounds (6 of 12 each). The execute row is at parity
within the noise of a 6 ms child-process spawn on a loaded machine, not
measurably slower.

### Reading the numbers

- **Archive codec.** Haskell is faster on every pack and validate. The output bytes are identical
  to Python's, as the differential fixtures prove. Validating the single 256 MiB member is a
  header walk.
- **Extraction** is dominated by file creation and the kernel write path. Each member's data
  goes to petrus-posix's `writeAll`, one `safe` `write(2)` over the whole buffer (looping on
  short writes); the unsafe 64 KiB loop it replaced measured no faster (the A/B above).
  `one-large/extract` is the most I/O-bound and noisiest row. Across other runs it ranged from
  0.90x to 1.14x. A dedicated 10-round interleaved run of that row alone gave medians of 74.4 ms
  for Python and 70.8 ms for Haskell.
- **Process spawning** is about 1.8x faster. It uses `posix_spawn` with close-on-exec-by-default,
  not the `process` package's `close_fds` loop; see DIVERGENCES.md. Before that change, a Haskell
  spawn cost about 118 ms, because the loop closes every descriptor up to the
  `RLIMIT_NOFILE` of 1 048 576.
- **Sidecar round trips** are at parity: the medians are equal or within 2%, and Haskell wins most
  rounds. Each handshake is one Unix-socket connect, send, `poll` and receive, about 33 µs on both
  sides. Each execute is a handshake plus an execute request, and Node spawning `sh` dominates
  it, which neither client controls. Two things made the Haskell client faster here:
  - the `poll()`-based wait (DIVERGENCES.md), which cut the handshake from 0.141 ms to 0.033 ms
  - `posix_spawn` for the sidecar process

## Rerunning

From the repository root (`scripts/bench petrus-execution` runs exactly this block; it sets
`BENCH_TMP` to a directory under the git-ignored `bench-results/tmp/`):

<!-- scripts/bench: rerun -->
```sh
cabal build -j2 petrus-execution:bench:petrus-execution-bench
# Everything, interleaved; the work directory receives about 330 MiB of workloads.
"$(scripts/upstream-python)" -B packages/petrus-execution/bench/compare.py "${BENCH_TMP:-bench-results/tmp/petrus-execution}/workloads" 5
rm -rf "${BENCH_TMP:-bench-results/tmp/petrus-execution}/workloads"
```

CI's smoke run on a `full` dispatch (`scripts/bench --smoke`, not a measurement): the
Haskell harness on the `medium` workload only (the only one it creates),
plus its process and local rows.

<!-- scripts/bench: smoke -->
```sh
"$(scripts/upstream-python)" -B -c 'import sys; sys.path.insert(0, "packages/petrus-execution/bench"); import make_workloads as m; m.WORKLOADS = {"medium": m.WORKLOADS["medium"]}; m.main()' "$BENCH_TMP/workloads"
cd packages/petrus-execution && PETRUS_BENCH_ONLY=medium "$BENCH_BIN" "$BENCH_TMP/workloads" +RTS -M2G -RTS
```

Both harnesses read the monotonic clock, so both sides are wall-clock time.

By hand:

```
cabal build petrus-execution:bench:petrus-execution-bench

# Everything, interleaved (WORKDIR receives about 330 MiB of workloads):
"$(scripts/upstream-python)" packages/petrus-execution/bench/compare.py WORKDIR 5

# Individual harnesses (one JSON line per benchmark):
python3 packages/petrus-execution/bench/make_workloads.py WORKDIR
"$(scripts/upstream-python)" packages/petrus-execution/bench/python_bench.py \
  WORKDIR packages/petrus-execution/test/fixtures/fake_gondolin.mjs
cabal run -v0 petrus-execution:bench:petrus-execution-bench -- \
  WORKDIR packages/petrus-execution/test/fixtures/fake_gondolin.mjs
```

`PETRUS_BENCH_ONLY=<workload>` restricts either harness to one archive workload. Any other value,
such as `none`, skips the archive workloads and keeps the process and sidecar benchmarks. Without
the fake SDK argument, the sidecar benchmarks are skipped. `compare.py` needs `cabal` on `PATH`
to locate the benchmark binary.
