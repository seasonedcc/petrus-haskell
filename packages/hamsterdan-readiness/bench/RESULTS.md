# hamsterdan-readiness benchmarks

<!-- scripts/bench: measured sources 608791b225a01979 at 9b33242c3393 -->

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

Measured on 2026-10-12, 03:42–03:44 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.21–2.58:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare hamsterdan-readiness 3 --twin '"$(scripts/upstream-python hamsterdan)" -I -B packages/hamsterdan-readiness/bench/bench.py'

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `folding.every corpus fold (3292 calls)` | 9.59 ms | 72.5 ms | 7.56× | 7.50× | 9.59 ms, 9.66 ms, 9.57 ms | 72.9 ms, 72.4 ms, 72.5 ms |
| `folding.ci folds (177 calls)` | 335 µs | 2.85 ms | 8.51× | 8.51× | 337 µs, 333 µs, 335 µs | 2.88 ms, 2.85 ms, 2.85 ms |
| `folding.conv folds (250 calls)` | 399 µs | 5.63 ms | 14.12× | 14.12× | 399 µs, 398 µs, 399 µs | 5.66 ms, 5.63 ms, 5.63 ms |
| `folding.dash folds (441 calls)` | 563 µs | 5.74 ms | 10.18× | 10.17× | 563 µs, 564 µs, 555 µs | 5.78 ms, 5.73 ms, 5.74 ms |
| `folding.esc folds (232 calls)` | 532 µs | 4.28 ms | 8.04× | 8.02× | 533 µs, 532 µs, 529 µs | 4.28 ms, 4.27 ms, 4.3 ms |
| `folding.life folds (341 calls)` | 869 µs | 7.04 ms | 8.10× | 8.08× | 873 µs, 869 µs, 865 µs | 7.05 ms, 7.04 ms, 7.03 ms |
| `folding.mut folds (246 calls)` | 543 µs | 4.58 ms | 8.43× | 8.42× | 543 µs, 543 µs, 535 µs | 4.58 ms, 4.57 ms, 4.58 ms |
| `folding.ready folds (813 calls)` | 3.27 ms | 18.2 ms | 5.56× | 5.48× | 3.27 ms, 3.31 ms, 3.21 ms | 18.2 ms, 18.1 ms, 18.2 ms |
| `folding.rem folds (298 calls)` | 1.14 ms | 10.7 ms | 9.41× | 9.18× | 1.16 ms, 1.14 ms, 1.13 ms | 10.7 ms, 10.8 ms, 10.7 ms |
| `folding.review folds (391 calls)` | 1.47 ms | 11.7 ms | 8.00× | 7.96× | 1.48 ms, 1.47 ms, 1.46 ms | 11.8 ms, 11.7 ms, 11.6 ms |
| `folding.startup folds (103 calls)` | 719 ns | 3 µs | 4.17× | 4.16× | 720 ns, 719 ns, 712 ns | 3 µs, 3 µs, 3 µs |
| `board.render_board over every corpus log (1569 logs)` | 16.4 ms | 60.5 ms | 3.69× | 3.68× | 16.4 ms, 16.3 ms, 16.4 ms | 60.5 ms, 60.5 ms, 60.3 ms |
| `board.gate_facts over every corpus log (1569 logs)` | 12.6 ms | 57.2 ms | 4.55× | 4.55× | 12.6 ms, 12.6 ms, 12.4 ms | 57.2 ms, 57.3 ms, 57.1 ms |

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
