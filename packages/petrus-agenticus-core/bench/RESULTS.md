# petrus-agenticus-core benchmark results

<!-- scripts/bench: measured sources 79b9a7598b6cb16d at df073f3106e5 -->
<!-- scripts/bench: carried to 625ff0185edc3f57 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: petrus-sqlite's checkBindLength names the either throwIO pure . bindLength that bindAll and bindTextParam already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to 640482d757e5ffdc at b4d1ccb669ad: since f87d05b, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only -->

Each layer has a twin workload: a tasty-bench group in `bench/Bench/*.hs` and
a Python script `bench/python_*.py`, which runs the pinned reference
(`upstream/petrus` @ 3f85fc2). The per-layer files cover the workloads, the
environment, profiling notes and the rerun commands.

All runs: Apple M4, macOS (Darwin 25.3), GHC 9.10.3 `-O2`, CPython 3.14.6.

| Layer | Results | Headline (Python / Haskell) |
| --- | --- | --- |
| Catalog | [results-catalog.md](results-catalog.md) | resolve 6.1×, `snapshot-to-json` 2.6×, `from_data` 2.3×, register+enable 4.2× (medians of three interleaved repetitions, 2026-10-12) |
| Effect | [results-effect.md](results-effect.md) | digests 2.5× to 5.4×; gateway execute and replay 15.4× and 15.6× (medians of three interleaved repetitions, 2026-10-12) |
| Hands | [results-hands.md](results-hands.md) | parse 4.0×; gateway reads 3.3× to 3.5×; gateway writes 1.8× to 1.9× (medians of three interleaved repetitions, 2026-10-12, default RTS) |
| Thread | [results-thread.md](results-thread.md) | build about 1,600× (the reference is quadratic); `to-json` 2.1×, `dumps` alone 2.0×, `from_data` 4.3× (medians of three interleaved repetitions, 2026-10-12) |
| Connection custody | [results-custody.md](results-custody.md) | 5.30× and 7.30× on whole FULL-sync sessions at N = 100 and 1000 (medians of three alternating rounds, 2026-10-13); 2.7× at N = 5000 earlier |

## Known slow path

JSON text encoding through `petrus-json` (`dumps` and `dumpsText`) trailed
CPython's C-accelerated `json.dumps` on large documents, in the `*-to-json`
rows only. It no longer does: `thread.dumps-only-1000x4` reads 2.0× in the
current figures. `petrus-json` is shared by every package, so this was
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
