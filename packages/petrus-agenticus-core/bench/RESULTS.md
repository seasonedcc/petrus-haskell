# petrus-agenticus-core benchmark results

Each layer has a twin workload: a tasty-bench group in `bench/Bench/*.hs` and
a Python script `bench/python_*.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2). The per-layer files cover the workloads, the
environment, profiling notes and the rerun commands.

All runs: Apple M4, macOS (Darwin 25.3), GHC 9.10.3 `-O2`, CPython 3.14.6.

| Layer | Results | Headline (Python / Haskell) |
| --- | --- | --- |
| Catalog | [results-catalog.md](results-catalog.md) | resolve 6.3×, `from_data` 1.6×, register+enable 3.6×. `snapshot-to-json` is 0.69×, because it is bound by the `petrus-json` encoder. |
| Effect | [results-effect.md](results-effect.md) | digests 2.2× to 3.0×; gateway execute and replay 9.1× and 9.6× |
| Hands | [results-hands.md](results-hands.md) | parse 3.9×; gateway reads 3.5×; gateway writes 1.9× to 2.1× |
| Thread | [results-thread.md](results-thread.md) | build about 2,800× (the reference is quadratic); `from_data` about 4.6×. `to-json` is 0.66× and `dumps` alone is 0.42×, bound by the `petrus-json` encoder. |
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
