# Engine benchmarks: Haskell vs the Python reference

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

## How to rerun

From the repository root:

    cabal bench petrus-engine

Python, from the pinned reference checkout with its virtual environment:

    cd upstream/petrus
    uv sync    # once
    .venv/bin/python ../../packages/petrus-engine/bench/python_bench.py

Haskell numbers are tasty-bench means (± 2σ). Python numbers are the median of
3–20 runs after one warm-up. Both sides were run back to back on 2026-10-10 on
an Apple M4 with 24 GB of memory, using GHC 9.10.3 (`-O2`, `-A32m`) and
CPython 3.14.6. The reference was pinned at `upstream/petrus` 3f85fc2. The
machine was shared and under load (load average 3–5).

## Results

| workload | size (records) | Python | Haskell | speed-up |
| --- | ---: | ---: | ---: | ---: |
| orders-small (3 orders, in-memory) | 66 | 2.52 ms | 0.183 ms | 13.8× |
| orders-large (200 orders, in-memory) | 4 203 | 850 ms | 115 ms | 7.4× |
| orders-large-jsonl (200 orders, JSONL) | 4 203 | 913 ms | 202 ms | 4.5× |
| chain (20 transitions × 50 tokens, InMemoryDispatch) | 5 002 | 431 ms | 57.5 ms | 7.5× |
| load-jsonl (load 200-order History + one advance) | 4 203 | 120 ms | 27.7 ms | 4.3× |

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
