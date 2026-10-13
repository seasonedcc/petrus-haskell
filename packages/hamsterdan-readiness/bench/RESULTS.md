# hamsterdan-readiness benchmarks

<!-- scripts/bench: measured sources 724a639f32b052d5 at b4d1ccb669ad -->

These are the paths the V5 net runs on every firing and every dashboard
publication:

- **Folding:** every pure loop fold recorded in `test/corpus/folds.jsonl`
  (3292 calls: the upstream suite's observed bindings plus perturbed ones,
  refusals included), each fed to the handler wired for its transition with
  its output arcs. The table shows one pass over all of them, then one pass
  per loop.
- **Board rendering:** `render_board` and `gate_facts` over every entry log in
  `test/corpus/board.jsonl` (1569 logs, refusals included), in one pass.

Both sides run the same calls on the same inputs. Each side parses the
inputs before timing starts.

## Current figures

Measured on 2026-10-13, 06:54–06:58 local (UTC-3), at commit `b4d1ccb`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.65–3.28:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare hamsterdan-readiness 3 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-readiness/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `folding.every corpus fold (3292 calls)` | 10.2 ms | 73.3 ms | 7.20× | 6.84× | 3 of 3 | 9.62 ms, 10.7 ms, 10.2 ms | 73.8 ms, 73.1 ms, 73.3 ms |
| `folding.ci folds (177 calls)` | 355 µs | 2.9 ms | 8.18× | 8.08× | 3 of 3 | 334 µs, 355 µs, 360 µs | 2.89 ms, 2.91 ms, 2.9 ms |
| `folding.conv folds (250 calls)` | 407 µs | 5.7 ms | 14.01× | 13.59× | 3 of 3 | 394 µs, 407 µs, 417 µs | 5.76 ms, 5.7 ms, 5.67 ms |
| `folding.dash folds (441 calls)` | 592 µs | 5.95 ms | 10.05× | 9.86× | 3 of 3 | 578 µs, 596 µs, 592 µs | 5.95 ms, 5.87 ms, 5.98 ms |
| `folding.esc folds (232 calls)` | 561 µs | 4.34 ms | 7.74× | 7.63× | 3 of 3 | 539 µs, 561 µs, 584 µs | 4.34 ms, 4.34 ms, 4.45 ms |
| `folding.life folds (341 calls)` | 879 µs | 7.11 ms | 8.10× | 8.03× | 3 of 3 | 879 µs, 872 µs, 886 µs | 7.19 ms, 7.1 ms, 7.11 ms |
| `folding.mut folds (246 calls)` | 576 µs | 4.65 ms | 8.06× | 7.92× | 3 of 3 | 561 µs, 576 µs, 577 µs | 4.65 ms, 4.68 ms, 4.57 ms |
| `folding.ready folds (813 calls)` | 3.35 ms | 18.4 ms | 5.50× | 5.26× | 3 of 3 | 3.5 ms, 3.22 ms, 3.35 ms | 18.4 ms, 18.9 ms, 18.4 ms |
| `folding.rem folds (298 calls)` | 1.2 ms | 10.8 ms | 8.99× | 8.91× | 3 of 3 | 1.13 ms, 1.2 ms, 1.21 ms | 10.7 ms, 10.8 ms, 10.8 ms |
| `folding.review folds (391 calls)` | 1.56 ms | 11.9 ms | 7.62× | 7.53× | 3 of 3 | 1.56 ms, 1.56 ms, 1.57 ms | 11.9 ms, 11.7 ms, 11.9 ms |
| `folding.startup folds (103 calls)` | 729 ns | 3 µs | 4.11× | 4.09× | 3 of 3 | 694 ns, 734 ns, 729 ns | 3 µs, 3 µs, 3 µs |
| `board.render_board over every corpus log (1569 logs)` | 16.8 ms | 60.7 ms | 3.62× | 3.58× | 3 of 3 | 17 ms, 16.8 ms, 16.6 ms | 60.7 ms, 61.1 ms, 60.5 ms |
| `board.gate_facts over every corpus log (1569 logs)` | 12.7 ms | 57.3 ms | 4.52× | 4.46× | 3 of 3 | 12.7 ms, 12.3 ms, 13 ms | 57.3 ms, 57.1 ms, 58.1 ms |

At `b4d1ccb` the folds' Python `<`-family comparisons of two numbers
(`compareValues`, reached through `tupleCompare` and `pyMax2` by the esc
folds) go through petrus-json's `pyNumberCompare` instead of a local copy.
Every row reads within 5% of its `df073f3` figure (the esc folds 7.74×
against 7.86×; the board rows, which compare no numbers, 3.62× and 4.52×
against 3.72× and 4.62×).

## Results

The machine was an Apple M4 (10 cores), macOS 26.3.1, shared with other
work. The load average was 1.9–5.0 during these runs (`uptime` before and
after each run).

- **Haskell:** GHC 9.10.3 with `-O2`, `tasty-bench`, run with `+RTS -M2G`.
  Each cell is that benchmark's mean.
- **Python:** CPython 3.14.6 with pydantic 2.13.4. Each cell is the best of 5
  `timeit` repeats, each about half a second of passes.
- **Interleaving:** two rounds, run as Haskell, Python, then Python, Haskell.
  The table shows each side's better round.

<!-- bench: superseded -->

| Operation (one pass) | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| every corpus fold (3292 calls) | 12.2 ms | 73.7 ms | 6.0× |
| `ci` folds (177 calls) | 396 µs | 2.90 ms | 7.3× |
| `conv` folds (250 calls) | 521 µs | 5.75 ms | 11.0× |
| `dash` folds (441 calls) | 595 µs | 5.85 ms | 9.8× |
| `esc` folds (232 calls) | 606 µs | 4.36 ms | 7.2× |
| `life` folds (341 calls) | 1.06 ms | 7.15 ms | 6.7× |
| `mut` folds (246 calls) | 614 µs | 4.66 ms | 7.6× |
| `ready` folds (813 calls) | 4.57 ms | 18.5 ms | 4.0× |
| `rem` folds (298 calls) | 1.73 ms | 10.9 ms | 6.3× |
| `review` folds (391 calls) | 1.91 ms | 11.8 ms | 6.2× |
| `startup` folds (103 calls) | 0.75 µs | 3 µs | 4.0× |
| `render_board` (1569 logs) | 16.5 ms | 61.4 ms | 3.7× |
| `gate_facts` (1569 logs) | 12.3 ms | 57.8 ms | 4.7× |

Haskell is faster on every row.

The two rounds agreed within 25% on every row. On the Haskell side, the
"every corpus fold" row moved the most (14.8 ms in the first round, under
higher load). The `startup` folds return no tokens for these bindings, so
that row measures call overhead only.

## Rerun

From the repository root, alternating the two sides:

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run hamsterdan-readiness +RTS -M2G -RTS
"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-readiness/bench/bench.py
```

`scripts/bench hamsterdan-readiness` runs exactly this block once;
`scripts/upstream-python hamsterdan` provisions the pinned Hamsterdan.

Haskell times are wall-clock time (`localOption WallTime` in `bench/Main.hs`),
like the Python side's `time.perf_counter`. The table above was taken before
that switch, in tasty-bench's default CPU time; this workload is
single-threaded and does no I/O inside the timed region, so the two agree
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

`cabal bench` runs in the package directory. `bench.py` finds the corpora
relative to itself. Note `uptime` before and after each run.
