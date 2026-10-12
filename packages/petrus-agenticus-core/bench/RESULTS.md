# petrus-agenticus-core benchmark results

<!-- scripts/bench: measured sources 479d741849778ff1 at 9126e1be67f7 -->

Each layer has a twin workload: a tasty-bench group in `bench/Bench/*.hs` and
a Python script `bench/python_*.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2). The per-layer files cover the workloads, the
environment, profiling notes and the rerun commands.

All runs: Apple M4, macOS (Darwin 25.3), GHC 9.10.3 `-O2`, CPython 3.14.6.

| Layer | Results | Headline (Python / Haskell) |
| --- | --- | --- |
| Catalog | [results-catalog.md](results-catalog.md) | resolve 6.1×, `snapshot-to-json` 2.1×, `from_data` 1.9×, register+enable 4.1× (medians of three interleaved repetitions, 2026-10-12) |
| Effect | [results-effect.md](results-effect.md) | digests 3.3× to 4.4×; gateway execute and replay 12.6× and 12.5× (2026-10-12) |
| Hands | [results-hands.md](results-hands.md) | parse 3.6×; gateway reads 2.8× to 3.1×; gateway writes 1.8× (2026-10-12, default RTS) |
| Thread | [results-thread.md](results-thread.md) | build about 1,400× (the reference is quadratic); `to-json` 2.6×, `dumps` alone 1.8×, `from_data` 3.7× (medians of three interleaved repetitions, 2026-10-12) |
| Connection custody | [results-custody.md](results-custody.md) | 2.7× to 4.7× on whole sessions (FULL and OFF sync, N = 100 to 5000) |

## Known slow path

JSON text encoding through `petrus-json` (`dumps` and `dumpsText`) trails
CPython's C-accelerated `json.dumps` on large documents. It shows up only in
the `*-to-json` rows. `petrus-json` is shared by every package, so this was
recorded and routed to its owner rather than special-cased here.

## Rerun

From the repository root (`scripts/bench petrus-agenticus-core` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-agenticus-core +RTS -M2G -RTS
scripts/bench-run petrus-agenticus-core custody FULL 100 1000 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-core/bench/python_catalog.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-core/bench/python_effect.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-core/bench/python_hands.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-core/bench/python_thread.py)
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-core/bench/python_custody.py FULL 100 1000)
```

Every Haskell figure is wall-clock time, like Python's `time.perf_counter`: the custody driver
reads the monotonic clock, and `bench/Main.hs` sets `localOption WallTime` for the tasty-bench
groups. The catalog, effect, hands and thread tables were taken before that switch, in
tasty-bench's default CPU time. Those workloads are in memory and do no I/O; CPU and wall time
agree for the single-threaded rows, and for the `-N8` hands rows CPU time, which adds up every
core, is if anything the larger of the two
(see [CPU and wall-clock time](../../../docs/reproducing.md#cpu-and-wall-clock-time)).

The custody workload is a stateful driver that runs outside tasty-bench and
takes the sync mode and the cycle counts as arguments:

```sh
scripts/bench-run petrus-agenticus-core custody FULL 100 1000 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-agenticus-core/bench/python_custody.py FULL 100 1000)
```
