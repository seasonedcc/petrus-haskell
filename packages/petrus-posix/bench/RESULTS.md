# petrus-posix benchmarks

<!-- scripts/bench: measured sources 956a5562bc09bd47 at 5a73d7a7f019 -->

Python figures time the upstream code path named in `bench/python_bench.py`;
Haskell figures are tasty-bench means of `bench/Main.hs`, which uses the same
names and values. Both are wall-clock time, and both sides work in a fresh
directory under the same `TMPDIR`. Ratios above 1 mean Haskell is faster.
**Every row is level or faster.** `flock.open-tryLock-close` is level, at
1.00× (13.4 µs on both sides; the repetitions' ratios 0.999, 1.000, 0.997,
0.994 and 0.974×, so the median repetition is 0.997×, 0.3% behind): both
sides spend it in the kernel's `open`, below, and it read 1.003× over nine
repetitions in the table before this one.

- Date: 2026-10-12 01:22–01:24 local (UTC-3), at commit `81bbdc5`
- Machine: Darwin arm64, Apple M4; 1-minute load average 2.06–2.37 around
  the runs
- Haskell: GHC 9.10.3 (-O2), tasty-bench mean in wall-clock time,
  `--stdev 5`, `+RTS -M2G -RTS`, the benchmark executable run directly
  (below)
- Python: CPython 3.14.6 (upstream venv), median of 10 timed batches of 0.2 s
  (scripts/bench_timing.py)
- Interleaved by `scripts/bench-compare petrus-posix 5`, alternating which
  side goes first. The figures are the medians of the five repetitions; the
  last two columns give each repetition.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `flock.tryLock-unlock` | 454 ns | 587 ns | 1.29× | 1.28× | 453 ns, 463 ns, 454 ns, 455 ns, 453 ns | 599 ns, 602 ns, 587 ns, 582 ns, 585 ns |
| `flock.open-tryLock-close` | 13.4 µs | 13.4 µs | 1.00× | 0.97× | 13.4 µs, 13.4 µs, 13.4 µs, 13.4 µs, 13.7 µs | 13.4 µs, 13.4 µs, 13.4 µs, 13.4 µs, 13.3 µs |
| `path.resolve-symlinked` | 8.79 µs | 16 µs | 1.82× | 1.80× | 8.68 µs, 8.85 µs, 8.84 µs, 8.75 µs, 8.79 µs | 16 µs, 16 µs, 15.9 µs, 15.9 µs, 16 µs |
| `path.expanduser-resolve` | 10.8 µs | 16.1 µs | 1.49× | 1.48× | 10.6 µs, 10.8 µs, 10.8 µs, 10.7 µs, 10.9 µs | 16.1 µs, 16 µs, 16 µs, 16.1 µs, 16.1 µs |
| `at.stat-nofollow` | 746 ns | 894 ns | 1.20× | 1.19× | 744 ns, 746 ns, 762 ns, 749 ns, 739 ns | 883 ns, 913 ns, 915 ns, 894 ns, 881 ns |
| `atomic.write-1KiB-fsync` | 128 µs | 133 µs | 1.04× | 0.94× | 127 µs, 141 µs, 128 µs, 131 µs, 127 µs | 133 µs, 132 µs, 134 µs, 134 µs, 131 µs |
| `resource.max_rss_mb` | 192 ns | 432 ns | 2.25× | 2.10× | 194 ns, 192 ns, 194 ns, 186 ns, 188 ns | 409 ns, 432 ns, 437 ns, 435 ns, 430 ns |

`atomic.write-1KiB-fsync` is fsync-bound: 1.049, 0.938, 1.046, 1.028 and
1.033× by repetition; the 0.94× is the one repetition where the Haskell
side read 141 µs.

The table before this one (2026-10-11 06:32–06:38, at `573e8d6`, load
2.28–2.77, nine repetitions) read 1.29×, 1.00×, 1.81×, 1.48×, 1.13×, 1.04×
and 2.27×, in the order of the rows above.

## The `flock` constants were foreign calls

A `foreign import capi "sys/file.h value LOCK_EX"` constant is a call to a
C function that GHC generates, and the call is safe unless the import says
`unsafe`. GHC inlined each one at every use, so `tryLock` made two safe
foreign calls (for `LOCK_EX` and `LOCK_NB`) besides `flock` itself, and
`unlock` one more (`LOCK_UN`). A safe call releases and reacquires the
capability, about 25 ns here against 2 ns for an unsafe one (a `getpid`
probe), and more under the benchmark. The Core of `Petrus.Posix.Flock`
(`-ddump-simpl`) showed them. Each constant is now an unsafe import read
once into a top-level value that is never inlined, and the flags are
combined once (`LOCK_EX | LOCK_NB`, `O_RDWR | O_CREAT`). The only safe
calls left are the intended ones: `open`, which can block on a slow file
system as CPython releases the GIL around it, and the blocking `flock`
(interruptible). `flock.tryLock-unlock` went from 1.01–1.05× to 1.29×.

## `flock.open-tryLock-close` is the kernel's `open`

Both sides make the same three system calls: `open(path, O_RDWR | O_CREAT
| O_CLOEXEC, 0600)`, `flock(fd, LOCK_EX | LOCK_NB)` and `close`. CPython's
`os.open` adds `O_CLOEXEC` and calls `open` with the GIL released (it
checks once per process that `O_CLOEXEC` works); `fcntl.flock` and
`os.close` release the GIL too. Neither side uses `openat`. Measured
outside tasty-bench, in fixed loops:

- **`open` is almost all of it.** In this `TMPDIR` (and in the worktree),
  one `open` of an existing file took 11.5–13 µs; in `/private/tmp`, 1.35
  µs. The difference is the file system's watchers (`fseventsd` ran at
  100% CPU during these runs), and both sides pay it. `O_CREAT` costs
  nothing extra on an existing file. `O_RDONLY` would be cheaper (8.2 µs)
  but would not be the reference's call.
- **The client code is within noise of C.** A C loop of the three calls
  took about 12.3 µs, the Haskell library's `openLockFile`, `tryLock` and
  `closeFd` 12.6–13.1 µs, and Python's loop 13.0–13.5 µs, alternated.

So the row moves with the kernel, not with either client: at 1.00× here
(0.997× by repetition) and in the table before, 0.97–0.99× in the earlier
tables, where the Haskell side also ran under `cabal bench` (below).

## How bench-compare runs the Haskell side

`scripts/bench-compare` used to run `cabal bench petrus-posix` in each
repetition, so the benchmark ran with cabal as its parent process. In
alternated checks on 2026-10-11, the same executable measured this row
about 150–250 ns (1–2%) slower under `cabal bench` than when started
directly. The Python twin is started directly. bench-compare now builds the
benchmark once and runs its executable directly, in the package directory
and with the environment variables `cabal bench` sets
(`HASKELL_DIST_DIR`, `petrus_posix_datadir`).

## Path marshalling

Every call that takes a path marshals a Haskell `String` to a C string. That
used to cost three passes over the path (a NUL check, an ASCII check, then
`withCAString`), about 1.2 µs for a 134-character path. Now:

- An ASCII path is copied in one pass (about 0.23 µs for the same path).
- The most recent path and its bytes are remembered. A caller that passes
  the same `String` value again skips the copy, as a lock file's or a
  database's fixed path does. The check is pointer equality on the
  immutable value, so it can only miss, never confuse two paths.
- A path with a NUL byte is still refused like Python's `ValueError:
  embedded null byte`. Non-ASCII paths still go through the file-system
  encoder.

The paths and their results are unchanged: `test/Main.hs` checks NUL
refusal, non-ASCII and over-long names, and alternating path values. This
lifted the `path.*` rows (1.31× before) and `at.stat-nofollow`, and it
narrowed `flock.open-tryLock-close` from 0.93× to 0.97×.

The bench builds its paths once, fully evaluated, as the Python twin
binds them once.

## Earlier tables

### 2026-10-11, 00:54–00:59

<!-- bench: superseded -->

At commit `3f31d2e` plus the path marshalling above and the bench's paths
built once, before the constants change, through `cabal bench`; load
average 4.4–7.4; `scripts/bench-compare petrus-posix 7`.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `flock.tryLock-unlock` | 590 ns | 617 ns | 1.05× | 0.99× | 590 ns, 575 ns, 588 ns, 629 ns, 586 ns, 590 ns, 611 ns | 617 ns, 674 ns, 668 ns, 787 ns, 606 ns, 611 ns, 603 ns |
| `flock.open-tryLock-close` | 15.1 µs | 14.6 µs | 0.97× | 0.93× | 15.8 µs, 15.1 µs, 15.3 µs, 16.7 µs, 14.2 µs, 14.4 µs, 14.6 µs | 14.6 µs, 14.8 µs, 15 µs, 16.3 µs, 13.7 µs, 14 µs, 13.7 µs |
| `path.resolve-symlinked` | 9.88 µs | 18.1 µs | 1.84× | 1.68× | 9.64 µs, 9.93 µs, 10.7 µs, 11.9 µs, 9.44 µs, 9.7 µs, 9.88 µs | 19.2 µs, 18.1 µs, 19.8 µs, 20.8 µs, 16.6 µs, 16.6 µs, 16.6 µs |
| `path.expanduser-resolve` | 12.5 µs | 18.6 µs | 1.48× | 1.33× | 12.2 µs, 12.5 µs, 13.4 µs, 14.3 µs, 12.5 µs, 11.7 µs, 12.6 µs | 19.6 µs, 18.6 µs, 19 µs, 19.2 µs, 16.7 µs, 16.9 µs, 16.7 µs |
| `at.stat-nofollow` | 901 ns | 1.01 µs | 1.12× | 0.97× | 855 ns, 901 ns, 914 ns, 901 ns, 850 ns, 856 ns, 959 ns | 1.01 µs, 1.05 µs, 1.02 µs, 1.05 µs, 956 ns, 960 ns, 932 ns |
| `atomic.write-1KiB-fsync` | 147 µs | 156 µs | 1.06× | 1.04× | 156 µs, 161 µs, 149 µs, 144 µs, 145 µs, 143 µs, 147 µs | 185 µs, 179 µs, 156 µs, 185 µs, 150 µs, 151 µs, 154 µs |
| `resource.max_rss_mb` | 206 ns | 451 ns | 2.18× | 2.13× | 204 ns, 205 ns, 209 ns, 208 ns, 201 ns, 208 ns, 206 ns | 474 ns, 507 ns, 451 ns, 518 ns, 448 ns, 447 ns, 439 ns |

Later the same day, after the constants change and still through `cabal
bench` (load 2.36–3.05, seven repetitions), the open row read 0.97×
(lowest 0.97×) and `flock.tryLock-unlock` 1.29×; with the executable run
directly (load 2.00–5.31), 0.99× and 1.28×.

### 2026-10-10, and the CPU-time table before it

<!-- bench: superseded -->

The table before the one above (2026-10-10, two repetitions, commit `74e6b1e`)
read 0.93× for `flock.open-tryLock-close`, 0.99× for `flock.tryLock-unlock`,
1.00× for `atomic.write-1KiB-fsync`, 1.31× for both `path.*` rows and 1.09×
for `at.stat-nofollow`. That table replaced one generated by the old `scripts/bench`, which timed Haskell
in tasty-bench's default CPU time against Python's wall-clock time. For these
rows the two clocks agree: every Haskell figure is within the run-to-run
spread of the old one (`atomic.write-1KiB-fsync` 133 µs then, 132–158 µs in that table),
because none of them waits on anything but the system calls themselves.

## What each row measures

In a scratch directory:

- **`flock.tryLock-unlock`**: a nonblocking exclusive `flock` and its release,
  on a file descriptor held open.
- **`flock.open-tryLock-close`**: open (creating) a lock file, take the
  nonblocking exclusive `flock`, close.
- **`path.resolve-symlinked`**, **`path.expanduser-resolve`**:
  `Path.resolve()` (and `expanduser()` first) over a path through a symlink
  and a `..`.
- **`at.stat-nofollow`**: `stat` relative to a directory descriptor, without
  following the final symlink.
- **`atomic.write-1KiB-fsync`**: the artifact store's atomic write: a
  temporary file in the target directory, 1 KiB written and fsynced, then
  `rename` over the target.
- **`resource.max_rss_mb`**: `getrusage` and the reference's
  `max_rss_mb` conversion.

## Rerun

From the repository root (`scripts/bench petrus-posix` runs exactly this block, once;
`scripts/bench-compare petrus-posix 5` interleaves the two sides and prints the table above).

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-posix --stdev 5 --timeout 300 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-posix/bench/python_bench.py)
```
