# petrus-agenticus-core benchmark results

Each layer has a twin workload: a tasty-bench group in `bench/Bench/*.hs` and
a Python script `bench/python_*.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2). The per-layer files cover the workloads, the
environment, profiling notes and the rerun commands.

All runs: Apple M4, macOS (Darwin 25.3), GHC 9.10.3 `-O2`, CPython 3.14.6.

| Layer | Results | Headline (Python / Haskell) |
| --- | --- | --- |
| Catalog | [results-catalog.md](results-catalog.md) | resolve 6.1×, `snapshot-to-json` 2.1×, `from_data` 1.8×, register+enable 3.9× (medians of five interleaved rounds) |
| Effect | [results-effect.md](results-effect.md) | digests 2.2× to 3.0×; gateway execute and replay 9.1× and 9.6× |
| Hands | [results-hands.md](results-hands.md) | parse 3.9×; gateway reads 3.5×; gateway writes 1.9× to 2.1× |
| Thread | [results-thread.md](results-thread.md) | build about 1,350× (the reference is quadratic); `to-json` 2.5×, `dumps` alone 1.8×, `from_data` 3.6× (medians of five interleaved rounds) |
| Connection custody | [results-custody.md](results-custody.md) | 2.7× to 4.7× on whole sessions (FULL and OFF sync, N = 100 to 5000) |

## Known slow path

JSON text encoding through `petrus-json` (`dumps` and `dumpsText`) trails
CPython's C-accelerated `json.dumps` on large documents. It shows up only in
the `*-to-json` rows. `petrus-json` is shared by every package, so this was
recorded and routed to its owner rather than special-cased here.

## Rerun

```sh
cabal bench petrus-agenticus-core-bench --benchmark-options='+RTS -M2G -RTS'
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus-core/bench/python_catalog.py
.venv/bin/python ../../packages/petrus-agenticus-core/bench/python_effect.py
.venv/bin/python ../../packages/petrus-agenticus-core/bench/python_hands.py
.venv/bin/python ../../packages/petrus-agenticus-core/bench/python_thread.py
.venv/bin/python ../../packages/petrus-agenticus-core/bench/python_custody.py
```

The custody workload is a stateful driver that runs outside tasty-bench and
takes the sync mode and the cycle counts as arguments:

```sh
cabal bench petrus-agenticus-core-bench --benchmark-options='custody FULL 100 1000 +RTS -M2G -RTS'
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_custody.py FULL 100 1000
```
