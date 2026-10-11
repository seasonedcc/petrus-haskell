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

- Apple M4, macOS (Darwin 25.3), APFS.
- GHC 9.10.3, `-O2`, run with `+RTS -A32m -M2G`.
- CPython 3.14.6.

Haskell times are tasty-bench means; Python times are medians of 7 batches
(`time.perf_counter`).

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| runner-3-phases-3-reads | 6.02 ms | 11.17 ms | 1.86× |
| projection-roundtrip | 81.8 µs | 116.1 µs | 1.4× |

`runner-3-phases-3-reads` does file IO with fsyncs inside the timed region,
so it was rerun in wall-clock time (`--time-mode wall`, as the rerun block
below passes) against Python, interleaved: Haskell 5.75 and 6.29 ms, Python
10.95 and 11.38 ms (2026-10-10, 21:39–21:40 local, commit `74e6b1e`, load
average 5.4–5.6); the row shows the medians. In tasty-bench's default CPU
time it had read 5.86 ms. `projection-roundtrip` is in memory and keeps its
CPU-time figure, for which the two clocks agree.

The full run is dominated by file-system work (temporary-file creation,
fsync, rename and History appends), which costs the same in both languages.
The round trip is dominated by JSON text encoding. `petrus-json`'s
`dumpsText` is known to trail CPython's C encoder on large documents.

## Rerun

From the repository root (`scripts/bench petrus-agenticus-runtime` runs exactly this block, for
this file's rows and [results-pi.md](results-pi.md)'s; `scripts/upstream-python` provisions the
pinned reference). `--time-mode wall` makes tasty-bench measure wall-clock time, like the
Python side's `time.perf_counter`:

<!-- scripts/bench: rerun -->
```sh
cabal bench -j2 petrus-agenticus-runtime --benchmark-options='--time-mode wall +RTS -M2G -RTS'
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_runner.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-runtime/bench/python_pi_a2.py)
```
