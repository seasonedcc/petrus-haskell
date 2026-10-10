# petrus-agenticus benchmark results

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

## Results

Environment:

- Apple M4, macOS (Darwin 25.3).
- GHC 9.10.3, `-O2`, run with `+RTS -A32m`.
- CPython 3.14.6.

Haskell times are tasty-bench means. Python times are medians of 7 batches.

| Benchmark | Haskell | Python | Python / Haskell |
| --- | ---: | ---: | ---: |
| run-4-phases-6-tools | 3.06 ms | 21.18 ms | 6.9× |
| loop-state-roundtrip-16 | 132 µs | 321 µs | 2.4× |
| retention decode-row-x1000 | 9.14 ms | 15.46 ms | 1.7× |
| retention ledger-lookup-x200 | 4.24 ms | 4.77 ms | 1.1× |
| retention ledger-recover-100 | 1.19 ms | 1.76 ms | 1.5× |

Most of the time in `lookup` and `recover` is spent inside SQLite, which
both implementations share, so the speed-up there is small.

## Rerun

```sh
cabal bench petrus-agenticus-bench
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus/bench/python_agent_net.py
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus/bench/python_retention.py
```
