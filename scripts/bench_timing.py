"""Timing helper shared by the packages' bench/python_bench.py scripts.

``report(name, fn)`` times ``fn()`` the way scripts/bench expects: the batch
size is grown until one batch takes at least ``PETRUS_BENCH_BATCH_SECONDS``
(default 0.05 s), then ``PETRUS_BENCH_BATCHES`` (default 10) batches are timed
with ``time.perf_counter_ns`` and the median per-call time is printed as a
``name,nanoseconds`` CSV line on stdout. Names match the Haskell tasty-bench
names with the group separator written as a dot.
"""

import gc
import os
import statistics
import sys
import time

BATCH_SECONDS = float(os.environ.get("PETRUS_BENCH_BATCH_SECONDS", "0.05"))
BATCHES = int(os.environ.get("PETRUS_BENCH_BATCHES", "10"))


def _batch(fn, number: int) -> int:
    start = time.perf_counter_ns()
    for _ in range(number):
        fn()
    return time.perf_counter_ns() - start


def measure(fn) -> float:
    """Median nanoseconds per call of ``fn()``."""
    fn()
    number = 1
    while True:
        elapsed = _batch(fn, number)
        if elapsed >= BATCH_SECONDS * 1e9 or number >= 1 << 30:
            break
        number *= 2 if elapsed == 0 else max(2, min(10, int(BATCH_SECONDS * 1e9 / max(elapsed, 1)) + 1))
    enabled = gc.isenabled()
    samples = []
    try:
        for _ in range(BATCHES):
            samples.append(_batch(fn, number) / number)
    finally:
        if enabled:
            gc.enable()
    return statistics.median(samples)


def report(name: str, fn) -> None:
    print(f"{name},{measure(fn):.1f}", flush=True)
    print(f"  {name}", file=sys.stderr, flush=True)
