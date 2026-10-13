# petrus-agenticus benchmark results

<!-- scripts/bench: measured sources 5654849fcc483089 at c0cb6cb59655 -->

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

Measured on 2026-10-13, 01:05–01:06 local (UTC-3), at commit `c0cb6cb`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.95–2.48:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus 3 --python python_agent_net.py --python python_retention.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `agent-net.run-4-phases-6-tools` | 1.77 ms | 7.69 ms | 4.34× | 4.26× | 3 of 3 | 1.76 ms, 1.8 ms, 1.77 ms | 7.68 ms, 7.69 ms, 7.69 ms |
| `agent-net.loop-state-roundtrip-16` | 32.7 µs | 127 µs | 3.90× | 3.86× | 3 of 3 | 32.6 µs, 32.7 µs, 32.7 µs | 127 µs, 126 µs, 128 µs |
| `retention.decode-row-x1000` | 4.44 ms | 14.8 ms | 3.33× | 3.30× | 3 of 3 | 4.44 ms, 4.47 ms, 4.43 ms | 14.8 ms, 14.7 ms, 14.8 ms |
| `retention.ledger-lookup-x200` | 2.39 ms | 4.59 ms | 1.92× | 1.90× | 3 of 3 | 2.36 ms, 2.4 ms, 2.39 ms | 4.59 ms, 4.55 ms, 4.64 ms |
| `retention.ledger-recover-100` | 662 µs | 1.66 ms | 2.50× | 2.47× | 3 of 3 | 660 µs, 669 µs, 662 µs | 1.66 ms, 1.65 ms, 1.67 ms |

Every row is at 1.90× or more in every repetition.

### 2026-10-12, at `561723e` (superseded)

<!-- bench: superseded -->

Measured on 2026-10-12, 22:16–22:18 local (UTC-3), with a 1-minute load
average of 1.87–2.01: three interleaved repetitions of the command above.
Superseded by the run at `c0cb6cb` above.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `agent-net.run-4-phases-6-tools` | 1.75 ms | 7.52 ms | 4.29× | 4.23× | 3 of 3 | 1.78 ms, 1.75 ms, 1.74 ms | 7.51 ms, 7.55 ms, 7.52 ms |
| `agent-net.loop-state-roundtrip-16` | 32.2 µs | 126 µs | 3.92× | 3.87× | 3 of 3 | 32.6 µs, 31.9 µs, 32.2 µs | 126 µs, 126 µs, 126 µs |
| `retention.decode-row-x1000` | 4.29 ms | 14.8 ms | 3.45× | 3.38× | 3 of 3 | 4.28 ms, 4.29 ms, 4.37 ms | 14.8 ms, 14.8 ms, 14.7 ms |
| `retention.ledger-lookup-x200` | 2.34 ms | 4.63 ms | 1.97× | 1.93× | 3 of 3 | 2.39 ms, 2.34 ms, 2.34 ms | 4.63 ms, 4.69 ms, 4.6 ms |
| `retention.ledger-recover-100` | 659 µs | 1.69 ms | 2.56× | 2.53× | 3 of 3 | 665 µs, 651 µs, 659 µs | 1.69 ms, 1.7 ms, 1.67 ms |

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
