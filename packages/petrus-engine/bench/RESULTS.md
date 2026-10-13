# Engine benchmarks: Haskell vs the Python reference

<!-- scripts/bench: measured sources 42d6d5c8600effbe at 0bf22350b52f -->
<!-- scripts/bench: carried to 31f9601329428f10 at c33829edc562: in-memory and JSONL history; no SQLite bind or other changed code on the measured path -->
<!-- scripts/bench: carried to 43adbf481a9b4134 at f87d05b6f42b: since 50635f0, no behavior or representation change on the measured paths: petrus-history-store's floatEqualsInteger calls pyNumberEq, the same exact test, reached only for a REAL position or a float occurrence, which the store never writes; petrus-impetus's literalInt float branch and petrus-motus's local-dispatch sqlite3 int-against-float == call pyNumberEq, the same exact test they spelled out; petrus-sqlite's checkBindLength names the either throwIO pure . bindLength its bind loop already ran; petrus-json's Json == compiles to the same optimized Core as at 50635f0 (-ddump-simpl compared; numericEq/intFloatEq moved as pyNumberEq/exactFloatEq into Petrus.Json.Value and inlined there), PyObject's pyEq likewise, pythonTruthy added; petrus-posix gains additions only (DirectFd, directFd, writeDirect) and docs -->
<!-- scripts/bench: carried to 28ee27862957f13d at 60f3c54dbf18: the fingerprint now also counts the test directories the benchmark stanza compiles (its test/ and ../petrus-impetus/test); neither has changed since the measurement at 0bf2235 (git diff 0bf2235 of both is empty), so no measured source changed -->
<!-- scripts/bench: carried to 1425f31440a3d334 at b4d1ccb669ad: since 60f3c54, no measured code changed: petrus-json gains additions only (Petrus.Json.Value exports jsonNumber and adds pyNumberCompare, Python's numeric <, NaN unordered, INLINE, beside pyNumberEq; Petrus.Json.Python.Object re-exports it), and every binding Petrus.Json.Value had before, Json's == (pythonEq), pyNumberEq and exactFloatEq among them, compiles to the same optimized Core (-O2 -ddump-simpl compared, generated constant names aside); petrus-posix's writeDirect gains a haddock sentence only. This also amends the c33829e carry, which left out petrus-cel's Tz change (59b0a85) in this package's closure: Tz uses the shared normpath only to validate a time-zone key, and no row evaluates one -->

`bench/Main.hs` (tasty-bench) and `bench/python_bench.py` drive the same
workloads end to end through the public Engine: `create`/`load`, `deliver`,
and one-action `advance` turns until the Engine is at rest, then `records`
and `close`. Each Python line prints a result size (the History length). The
Haskell bench prints the same sizes on start-up (`sizes: orders-small 66,
orders-large 4203, chain 5002`), which shows the two sides do identical work.

The workloads:

- **orders.** The interop scenario (`test/Petrus/Engine/Scenario.hs`, the twin
  of `test/interop/engine_interop.py`):
  - identified deliveries into a source transition;
  - a pure `validate` handler;
  - an ActivityBound `charge` (prepare → inline `charge_card` → project);
  - a `Delay 5` `settle`, matured by the default driving policy's
    `AdvanceTime`.

  `orders-small` delivers 3 orders and `orders-large` 200, both over the
  in-memory store. `orders-large-jsonl` runs the 200 orders over a fresh JSONL
  file, with one durable append per commit point. Each append is open, write
  and close: the reference's crash-durable posture, with no fsync. The JSONL
  History is byte-identical
  to the reference's; the interop suite checks this.
- **chain.** 50 tokens pumped through 20 passthrough transitions with no
  handlers, over `InMemoryDispatch`. That is 1 000 firings.
- **load-jsonl.** `Engine.load` of the finished 200-order JSONL History,
  which covers decode, replay and reconcile, then one `advance`.

## Current figures

Measured on 2026-10-12, 22:59–23:00 local (UTC-3), at commit `43c9546`, on
the Apple M4 (Darwin arm64) with a 1-minute load average of 3.88–4.77:
three interleaved repetitions, alternating which side goes first, of

    scripts/bench-compare petrus-engine 3

Haskell figures are tasty-bench means in wall-clock time (`--stdev 5`,
`+RTS -M2G`), the benchmark executable run directly in the package
directory; Python figures are the twin's own timing (CPython 3.14.6). Each
figure is the median over the repetitions, and the ratio is Python ÷
Haskell (above 1 means Haskell is faster). The
tables in the sections below are earlier measurements, kept with the
analysis that came with them.

| Benchmark | Haskell | Python | Python / Haskell | Lowest per repetition | Haskell ahead | Haskell per repetition | Python per repetition |
|---|---:|---:|---:|---:|---:|---|---|
| `engine.orders-small` | 183 µs | 2.54 ms | 13.87× | 12.92× | 3 of 3 | 193 µs, 181 µs, 183 µs | 2.5 ms, 2.71 ms, 2.54 ms |
| `engine.orders-large` | 84.6 ms | 782 ms | 9.24× | 9.18× | 3 of 3 | 84.6 ms, 80.8 ms, 85.2 ms | 781 ms, 787 ms, 782 ms |
| `engine.orders-large-jsonl` | 145 ms | 882 ms | 6.10× | 6.08× | 3 of 3 | 145 ms, 143 ms, 145 ms | 882 ms, 876 ms, 894 ms |
| `engine.chain` | 40.8 ms | 420 ms | 10.28× | 10.01× | 3 of 3 | 40.8 ms, 41.5 ms, 40 ms | 420 ms, 415 ms, 421 ms |
| `engine.load-jsonl` | 11.4 ms | 117 ms | 10.18× | 9.98× | 3 of 3 | 11.1 ms, 11.7 ms, 11.4 ms | 116 ms, 117 ms, 117 ms |

## How to rerun

From the repository root (`scripts/bench petrus-engine` runs exactly this block;
`scripts/upstream-python` provisions the pinned reference):

<!-- scripts/bench: rerun -->
```sh
scripts/bench-run petrus-engine --stdev 5 +RTS -M2G -RTS
(cd upstream/petrus && "$(../../scripts/upstream-python)" -B ../../packages/petrus-engine/bench/python_bench.py)
```

Haskell numbers are tasty-bench means in wall-clock time (`localOption
WallTime` in `bench/Main.hs`), `--stdev 5`, `+RTS -M2G`. Python numbers are the
median of 3–20 runs after one warm-up (`time.perf_counter`). The two sides ran
interleaved (Haskell, Python, then Python, Haskell) on 2026-10-10,
21:31–21:33 local (UTC-3), at commit `74e6b1e` with the switch to wall-clock
time, on an Apple M4 with 24 GB of memory, using GHC 9.10.3 (`-O2`, `-A32m`)
and CPython 3.14.6. The reference was pinned at `upstream/petrus` 3f85fc2.
The machine was shared with other agents (load average 4.3–5.8).

## Results

Each cell is the median of the two repetitions.

<!-- bench: superseded -->

| workload | size (records) | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: |
| orders-small (3 orders, in-memory) | 66 | 2.59 ms | 0.189 ms | 13.7× |
| orders-large (200 orders, in-memory) | 4 203 | 830 ms | 98.8 ms | 8.4× |
| orders-large-jsonl (200 orders, JSONL) | 4 203 | 904 ms | 180 ms | 5.0× |
| chain (20 transitions × 50 tokens, InMemoryDispatch) | 5 002 | 430 ms | 49.6 ms | 8.7× |
| load-jsonl (load 200-order History + one advance) | 4 203 | 117 ms | 13.9 ms | 8.4× |

The individual repetitions, Python / Haskell: orders-small 2.63 / 0.184 and
2.54 / 0.193 ms; orders-large 844 / 97.5 and 817 / 100 ms; orders-large-jsonl
895 / 171 and 913 / 188 ms; chain 424 / 47.7 and 437 / 51.4 ms; load-jsonl
115.9 / 14.3 and 117.9 / 13.5 ms.

The figures committed before these were tasty-bench's default CPU time. The
JSONL rows are the ones with file IO in the timed region (open, write, close
per commit point, no fsync), and the only ones where the clocks could differ
much; `orders-large-jsonl` read 202 ms in CPU time then and 180 ms in
wall-clock time now. The in-memory rows got faster by about as much
(`orders-large` 115 ms then, 99 ms now), so that difference is most likely
library work merged since, not the clock.

The History store's own benchmarks (JSONL append, load and resume; in-memory
append and reads) are in `packages/petrus-history-store/bench/RESULTS.md`.

## Notes

- **The Engine follows the reference turn by turn.** Each `advance` is
  `reconcile` (first turn only), then observe, then one policy-chosen
  action, then apply. The Haskell Coordinator makes the same calls into the
  kernel Instance and writes the same records at the same commit points. The
  speed-up comes from the kernel (persistent queues, incremental candidates,
  one `IORef` write per door), not from doing less work.
- **The JSONL rows are bound by file IO.** `orders-large-jsonl` performs
  one durable append (open, write, close) per commit point, which is several
  per order. Most of the gap between it and `orders-large` is those system
  calls, on both sides.
