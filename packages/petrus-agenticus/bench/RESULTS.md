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

## Rerun

```sh
cabal bench petrus-agenticus-bench
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus/bench/python_agent_net.py
```
