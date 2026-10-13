# Hands benchmark results (`agenticus-hands`)

<!-- scripts/bench: measured sources 58b8b899b48a81e2 at 13f7a84d2779 -->
<!-- scripts/bench: carried to 79b9a7598b6cb16d at c33829edc562: the petrus-json/posix/sqlite changes (loads refusal path, posix additions, SQLite bind length guard) are off the catalog, effect, hands and thread paths, which bind no SQLite -->
<!-- scripts/bench: carried to 625ff0185edc3f57 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: petrus-sqlite's checkBindLength names the either throwIO pure . bindLength that bindAll and bindTextParam already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to 640482d757e5ffdc at b4d1ccb669ad: since f87d05b, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only -->

Twins: `bench/Bench/Hands.hs` (Haskell, tasty-bench) and
`bench/python_hands.py` (upstream reference).

## Workload

Gateway overhead per call over an in-memory adapter that answers
immediately.  Each `gateway-*` row is one batch of 10 000 submissions with
unique call ids against a fresh `HandsGateway` (call ledger and grant budget
raised to 10 000), from one caller or from eight concurrent callers (Haskell:
`forConcurrently_` threads; Python: an 8-worker `ThreadPoolExecutor`).
`workspace_read` crosses precheck, grant consumption, the adapter and the
barrier-held postcheck; `workspace_write` additionally stages, re-checks under
the barrier and commits.  `parse-5-methods` times `parseToolRequest` /
`parse_tool_request` on one request of each method.  Divide a batch time by
10 000 for the per-call cost.

## Current figures

Measured on 2026-10-12, 22:18–22:26 local (UTC-3), at commit `424aa4e`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 1.80–2.65:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-agenticus-core 3 --python python_catalog.py --python python_effect.py --python python_hands.py --python python_thread.py

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The same three repetitions measured the other results files' rows (see [RESULTS.md](RESULTS.md)). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `hands.parse-5-methods` | 6.45 µs | 26.1 µs | 4.05× | 4.01× | 3 of 3 | 6.45 µs, 6.47 µs, 6.44 µs | 26.4 µs, 25.9 µs, 26.1 µs |
| `hands.gateway-read-10k-1-caller` | 28.8 ms | 99.2 ms | 3.45× | 3.42× | 3 of 3 | 29.1 ms, 28.8 ms, 28.8 ms | 99.3 ms, 98.9 ms, 99.2 ms |
| `hands.gateway-read-10k-8-callers` | 30.9 ms | 101 ms | 3.25× | 3.19× | 3 of 3 | 30.9 ms, 31 ms, 30.8 ms | 101 ms, 99 ms, 101 ms |
| `hands.gateway-write-10k-1-caller` | 68.6 ms | 131 ms | 1.91× | 1.88× | 3 of 3 | 68.1 ms, 68.6 ms, 69.8 ms | 134 ms, 130 ms, 131 ms |
| `hands.gateway-write-10k-8-callers` | 71.4 ms | 131 ms | 1.84× | 1.82× | 3 of 3 | 70.6 ms, 71.4 ms, 71.5 ms | 131 ms, 130 ms, 132 ms |

## Results

Times are per batch (per 5 parses for the first row); lower is better.
Haskell rows are tasty-bench means, Python rows the median of 7 batches after
one warm-up.

<!-- bench: superseded -->

| benchmark | Haskell `-N1` (default) | Haskell `-N8` | Python 3.14 | fastest Haskell vs Python |
|---|---:|---:|---:|---:|
| hands/parse-5-methods | 9.8 µs | 8.8 µs | 34.3 µs | 3.9× |
| hands/gateway-read-10k-1-caller | 45.8 ms | 36.9 ms | 130.9 ms | 3.5× |
| hands/gateway-read-10k-8-callers | 50.8 ms | 104 ms | 176.9 ms | 3.5× |
| hands/gateway-write-10k-1-caller | 91.1 ms | 94.2 ms | 170.9 ms | 1.9× |
| hands/gateway-write-10k-8-callers | 97.1 ms | 150 ms | 204.5 ms | 2.1× |

Haskell is faster than Python in every row and in both RTS configurations
(the `-N8` 8-caller rows by 1.7× and 1.4×).  Python runs under the GIL, so
its 8-caller rows measure serialised execution plus thread hand-offs; the
Haskell `-N8` 8-caller rows pay real cross-core coherence on the shared
ledger, grant and barrier, which is why `-N1` is faster for this
immediate-answer adapter.

## What was profiled and fixed

The first `-N8` measurement had Haskell *slower* than Python on the 8-caller
rows (read 219 ms vs 184 ms, write 547 ms vs 247 ms).  Three changes, each
measured in isolation:

1. **STM call ledger → `IORef` ledger with per-call `MVar` signals.**  The
   original ledger was one `TVar` holding the call map; exact duplicates
   waited with `retry`, so every publish woke every waiter (a thundering
   herd) and every claim conflicted with every publish.  Claims and
   publications are now compare-and-swap updates of an `IORef`; an exact
   in-flight duplicate blocks on that call's own `MVar ()`; `drain` waits on a
   `TVar` generation bumped only when the in-flight count returns to zero.
   Read 219 → 152 ms, write 547 → 236 ms.
2. **`atomicModifyIORef'` → evaluate-then-CAS (`Petrus.Agenticus.Internal.Atomic.modifyStrict`).**
   `atomicModifyIORef'` publishes an unevaluated thunk and forces it after the
   swap, so contending capabilities block on its blackhole.  The new state is
   now evaluated first and installed with `casMutVar#`.  Read 152 → 140 ms,
   write 236 → 226 ms.
3. **Bounded spin before parking on the barrier.**  The diagnostic runs
   showed the barrier was not the throughput limit (removing it made the run
   *slower*, 200 ms), but a parked `takeMVar` waiter is woken across
   capabilities, which costs far more than the microsecond hold.  `withBarrier`
   now retries `tryTakeMVar` up to 64 times, yielding between attempts, before
   parking.  Read 140 → 96–104 ms, write 226 → 150–162 ms.

Diagnostic baselines at `-N8` (temporary benches, not kept): `parseToolRequest`
alone on 10 000 reads took 17 ms from one caller and 33 ms from eight.
This M4 has 4 performance and 6 efficiency cores, so `-N8` schedules onto
efficiency cores.  Eight callers each with a *private* gateway took 65 ms,
which is the floor for this harness at `-N8`.

### The compare-and-swap, removed (2026-10-12)

Change 2 above was undone: the ledger and the grant state are updated with
`atomicModifyIORef'` again, since the rows stay well ahead of the reference
without the hand-written `casMutVar#` loop. Four interleaved repetitions of
each binary on the Apple M4, at a load average of 4–12 (other agents'
builds), medians of the tasty-bench means:

| Row | `-N1`, CAS | `-N1`, `atomicModifyIORef'` | `-N8`, CAS | `-N8`, `atomicModifyIORef'` | Python |
|---|---:|---:|---:|---:|---:|
| `gateway-read-10k-1-caller` | 38.1 ms | 35.7 ms | 28.1 ms | 28.3 ms | 100 ms |
| `gateway-read-10k-8-callers` | 41.2 ms | 40.5 ms | 15.4 ms | 75.6 ms | 102 ms |
| `gateway-write-10k-1-caller` | 77.6 ms | 73.8 ms | 66.8 ms | 68.0 ms | 130 ms |
| `gateway-write-10k-8-callers` | 83.6 ms | 78.5 ms | 23.8 ms | 59.0 ms | 131 ms |

(Python: the "Current figures" table.) With the default RTS, which the
benchmarks and `scripts/bench-gate` use, the two are level. At `-N8`, with
eight callers contending for one ledger, the compare-and-swap is 2.5–5×
faster, but `atomicModifyIORef'` still leads the reference by 1.35× (read)
and 2.2× (write), so by this repository's rule the plain update stays.
Should a deployment run the gateway at `-N8` and need that margin back, the
compare-and-swap is the change to make, with this table as its figure.

## Environment

- Apple M4 (4 performance + 6 efficiency cores, 10 total), macOS 26.3 (Darwin 25.3.0)
- GHC 9.10.3, `-O2 -threaded -rtsopts "-with-rtsopts=-A32m"`; measured with
  `+RTS -M2G` (the machine-wide memory cap during this run)
- Python 3.14.6 from the pinned upstream checkout's `.venv`
- Measured 2026-10-10 with other builds running on the machine, so expect
  ±10% noise between runs.

## Rerun

```sh
# Haskell, default RTS (-N1)
cabal -j2 bench petrus-agenticus-core --benchmark-options='-p hands +RTS -M2G -RTS'
# Haskell, eight capabilities
cabal -j2 bench petrus-agenticus-core --benchmark-options='-p hands +RTS -N8 -M2G -RTS'
# Python reference
cd upstream/petrus && .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_hands.py
```
