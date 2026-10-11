# petrus-agenticus-runtime benchmark results

The Pi benchmarks (frame codec, session validation, fingerprints, the
operation ledger and a scripted A2 turn) are in [results-pi.md](results-pi.md).
This file covers the Local Agent-as-a-Net runner.

These are twin workloads: `bench/Main.hs` (tasty-bench) and
`bench/python_runner.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2).

- `runner-3-phases-3-reads` builds an Episode Attachment with its grant,
  creates a runner in a fresh temporary directory and drains it to the
  terminal.
  - Model phase 1 proposes two `workspace_read` calls, phase 2 proposes one,
    and phase 3 stops.
  - Every projection is saved through the atomic JSON repository, with two
    fsyncs per save, and every History record is appended to
    `history.jsonl`.
- `projection-roundtrip` runs `AgentNetThreadProjection.from_data(json.loads(text))`
  and dumps the result back to compact sorted JSON. The input is that run's
  final `thread.json`.

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), APFS, 2026-10-10.
- GHC 9.10.3, `-O2`, run with `+RTS -A32m -M2G`.
- CPython 3.14.6.

Method: five interleaved rounds, together with the Pi rows of
[results-pi.md](results-pi.md). Each round ran the Haskell bench, then the
Python scripts. A Haskell value is a tasty-bench mean (`--stdev 3`); a
Python value is the script's median of 7 batches. The table gives the median
of the five rounds. The machine was shared with other work (load average 3.7
to 5.8).

| Benchmark | Haskell | Python | Python / Haskell | Slowest round |
| --- | ---: | ---: | ---: | ---: |
| runner-3-phases-3-reads | 6.02 ms | 11.17 ms | 1.86× | 1.8× |
| projection-roundtrip | 42.0 µs | 110 µs | 2.6× | 2.4× |

The five rounds timed Haskell in tasty-bench's default CPU time.
`runner-3-phases-3-reads` does file IO with fsyncs inside the timed region,
where CPU time leaves out the waits, so its row comes from a separate
wall-clock rerun (`--time-mode wall`, as the rerun block below passes)
interleaved with Python: Haskell 5.75 and 6.29 ms, Python 10.95 and
11.38 ms (2026-10-10, 21:39–21:40 local, commit `74e6b1e`, load average
5.4–5.6); the row shows the medians, and the slowest-round column the worse
of the two pairs. In CPU time the five rounds had read 5.41 ms against
10.2 ms (1.9×). `projection-roundtrip` is in memory and keeps its CPU-time
figure, for which the two clocks agree.

The full run is dominated by file-system work (temporary-file creation,
fsync, rename and History appends), which costs the same in both languages.
The round trip is mostly JSON text encoding. It was 1.4× (81.8 µs) before
petrus-json's encoder was rewritten to write in one pass.

## Rerun

From the repository root (`scripts/bench petrus-agenticus-runtime` runs exactly this block, for
this file's rows, [results-pi.md](results-pi.md)'s and [results-hosts.md](results-hosts.md)'s; `scripts/upstream-python` provisions the
pinned reference). `--time-mode wall` makes tasty-bench measure wall-clock time, like the
Python side's `time.perf_counter`:

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-agenticus-runtime --benchmark-options='--time-mode wall +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_runner.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi_a2.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_hosts.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_bench.py)
```

`bench/python_bench.py` holds the whole-Turn twins (`codex-turn`,
`codex-a3-service-turn`, `claude-turn`, `amp-turn`; see
[results-hosts.md](results-hosts.md); `pi-native-turn`, `pi-a5-turn`,
`pi-model-phase-turn`; see [results-pi.md](results-pi.md)), so
`scripts/bench-compare petrus-agenticus-runtime N` interleaves those rows.
