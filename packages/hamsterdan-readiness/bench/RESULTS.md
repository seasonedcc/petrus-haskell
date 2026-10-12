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
cabal bench hamsterdan-readiness -j2 --benchmark-options='+RTS -M2G -RTS'
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
