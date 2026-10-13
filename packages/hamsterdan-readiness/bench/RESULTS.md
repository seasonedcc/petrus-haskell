# hamsterdan-readiness benchmarks

<!-- scripts/bench: measured sources 72511e79975802b6 at 848eeba6a706 -->

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

Measured on 2026-10-12, 21:23–21:26 local (UTC-3), at commit `d0584bd`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.02–2.54:
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
| `folding.every corpus fold (3292 calls)` | 9.6 ms | 73.8 ms | 7.69× | 7.46× | 3 of 3 | 9.9 ms, 9.55 ms, 9.6 ms | 73.8 ms, 74 ms, 73 ms |
| `folding.ci folds (177 calls)` | 342 µs | 2.88 ms | 8.42× | 8.41× | 3 of 3 | 343 µs, 342 µs, 336 µs | 2.89 ms, 2.88 ms, 2.88 ms |
| `folding.conv folds (250 calls)` | 398 µs | 5.68 ms | 14.26× | 14.16× | 3 of 3 | 402 µs, 398 µs, 397 µs | 5.68 ms, 5.67 ms, 5.7 ms |
| `folding.dash folds (441 calls)` | 578 µs | 5.82 ms | 10.05× | 10.05× | 3 of 3 | 578 µs, 579 µs, 572 µs | 5.82 ms, 5.84 ms, 5.81 ms |
| `folding.esc folds (232 calls)` | 534 µs | 4.31 ms | 8.07× | 8.05× | 3 of 3 | 536 µs, 534 µs, 534 µs | 4.33 ms, 4.3 ms, 4.31 ms |
| `folding.life folds (341 calls)` | 873 µs | 7.06 ms | 8.09× | 8.07× | 3 of 3 | 873 µs, 854 µs, 875 µs | 7.08 ms, 7.06 ms, 7.06 ms |
| `folding.mut folds (246 calls)` | 545 µs | 4.61 ms | 8.45× | 8.43× | 3 of 3 | 544 µs, 545 µs, 546 µs | 4.62 ms, 4.61 ms, 4.6 ms |
| `folding.ready folds (813 calls)` | 3.25 ms | 18.1 ms | 5.58× | 5.53× | 3 of 3 | 3.28 ms, 3.23 ms, 3.25 ms | 18.1 ms, 18 ms, 18.2 ms |
| `folding.rem folds (298 calls)` | 1.15 ms | 10.9 ms | 9.47× | 9.30× | 3 of 3 | 1.17 ms, 1.13 ms, 1.15 ms | 10.9 ms, 10.8 ms, 10.9 ms |
| `folding.review folds (391 calls)` | 1.48 ms | 11.8 ms | 7.98× | 7.85× | 3 of 3 | 1.48 ms, 1.5 ms, 1.46 ms | 11.9 ms, 11.8 ms, 11.8 ms |
| `folding.startup folds (103 calls)` | 725 ns | 3 µs | 4.14× | 4.13× | 3 of 3 | 726 ns, 725 ns, 714 ns | 3 µs, 3 µs, 3 µs |
| `board.render_board over every corpus log (1569 logs)` | 16.3 ms | 60.7 ms | 3.73× | 3.69× | 3 of 3 | 16.5 ms, 16.3 ms, 16.3 ms | 60.7 ms, 60.6 ms, 60.7 ms |
| `board.gate_facts over every corpus log (1569 logs)` | 12.5 ms | 57.5 ms | 4.62× | 4.60× | 3 of 3 | 12.5 ms, 12.3 ms, 12.5 ms | 57.7 ms, 57.5 ms, 57.3 ms |

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
