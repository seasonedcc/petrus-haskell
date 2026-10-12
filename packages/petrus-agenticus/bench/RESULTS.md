# petrus-agenticus benchmark results

<!-- scripts/bench: measured sources f21f0285c01a357d at 5a73d7a7f019 -->

These are twin workloads: `bench/Bench/AgentNet.hs` (tasty-bench) and
`bench/python_agent_net.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2).

- `run-4-phases-6-tools` creates an Engine over Agent-as-a-Net with an
  in-memory History and inline dispatch, then drives it until the `done`
  token appears.
  - Model phases 1 to 3 each propose two `workspace_read` calls, and every
    call succeeds. Phase 4 stops.
  - That is 4 model Activities and 6 Hands Activities.
  - Both twins assert that the run ends with exactly 122 History records
    before they time anything, so the workloads cannot drift apart.
- `loop-state-roundtrip-16` runs `LoopState.from_data(json.loads(json.dumps(state.to_data())))`
  on a state that carries 16 results.

`bench/Bench/Retention.hs` and `bench/python_retention.py` are twins over a
territory custody ledger that holds 100 retained rows, each with a 4 KiB
archive:

- `decode-row-x1000` decodes one row (including the archive digest check)
  1,000 times.
- `ledger-lookup-x200` runs 200 `lookup` calls.
- `ledger-recover-100` runs `recover` over the 100 rows: one write
  transaction that decodes every record.

## Current figures

Measured on 2026-10-12, 03:06–03:07 local (UTC-3), at commit `81bbdc5`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 2.31–2.73:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus 3 --python python_agent_net.py --python python_retention.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---|---|
| `agent-net.run-4-phases-6-tools` | 1.88 ms | 7.65 ms | 4.07× | 4.02× | 1.86 ms, 1.9 ms, 1.88 ms | 7.68 ms, 7.65 ms, 7.63 ms |
| `agent-net.loop-state-roundtrip-16` | 41.7 µs | 128 µs | 3.08× | 3.04× | 41.8 µs, 41.6 µs, 41.7 µs | 127 µs, 128 µs, 129 µs |
| `retention.decode-row-x1000` | 5.08 ms | 14.7 ms | 2.90× | 2.85× | 5.08 ms, 5.17 ms, 5.08 ms | 14.6 ms, 14.7 ms, 14.9 ms |
| `retention.ledger-lookup-x200` | 2.42 ms | 4.53 ms | 1.87× | 1.87× | 2.42 ms, 2.41 ms, 2.42 ms | 4.52 ms, 4.59 ms, 4.53 ms |
| `retention.ledger-recover-100` | 741 µs | 1.65 ms | 2.23× | 2.21× | 739 µs, 742 µs, 741 µs | 1.63 ms, 1.67 ms, 1.65 ms |

## Results

Environment:

- Apple M4, macOS (Darwin 25.3), shared with other agents (load average
  4.9–5.6); 2026-10-10, 21:38–21:40 local (UTC-3), commit `74e6b1e` with the
  switch to wall-clock time in `bench/Main.hs`.
- GHC 9.10.3, `-O2`, run with `+RTS -A32m -M2G`.
- CPython 3.14.6.

Haskell times are tasty-bench means in wall-clock time (`localOption
WallTime`); Python times are medians of 7 batches (`time.perf_counter`). Two
repetitions ran interleaved (Haskell, Python, then Python, Haskell); each
figure is the median of the two.

<!-- bench: superseded -->

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| run-4-phases-6-tools | 1.44 ms | 7.96 ms | 5.5× |
| loop-state-roundtrip-16 | 47.5 µs | 128 µs | 2.7× |
| retention decode-row-x1000 | 7.50 ms | 15.1 ms | 2.0× |
| retention ledger-lookup-x200 | 3.80 ms | 4.67 ms | 1.23× |
| retention ledger-recover-100 | 1.02 ms | 1.67 ms | 1.63× |

The repetitions, Haskell / Python: run-4-phases-6-tools 1.38 / 7.84 and
1.50 / 8.08 ms; loop-state-roundtrip-16 45.2 / 128 and 49.8 / 128 µs;
decode-row-x1000 7.23 / 15.1 and 7.77 / 15.1 ms; ledger-lookup-x200
3.74 / 4.69 and 3.85 / 4.64 ms; ledger-recover-100 0.98 / 1.68 and
1.06 / 1.66 ms.

The figures committed before these were tasty-bench's default CPU time. The
retention rows read and write a SQLite ledger, the only IO here; in
wall-clock time they are no slower than they were in CPU time (lookup 4.24 ms
then, 3.80 ms now), so the earlier ratios did not hide a wait.

Most of the time in `lookup` and `recover` is spent inside SQLite, which
both implementations share, so the speed-up there is small.

## Rerun

From the repository root (`scripts/bench petrus-agenticus` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-agenticus +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus/bench/python_agent_net.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus/bench/python_retention.py)
```
