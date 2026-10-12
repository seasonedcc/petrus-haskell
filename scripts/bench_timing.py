"""Timing helper shared by the packages' bench/python_bench.py scripts.

``report(name, fn)`` times ``fn()`` the way scripts/bench-compare expects:
the batch size is grown until one batch takes at least
``PETRUS_BENCH_BATCH_SECONDS`` (default 0.2 s), then ``PETRUS_BENCH_BATCHES``
(default 10) batches are timed with ``time.perf_counter_ns`` (wall-clock time,
like the Haskell side's ``localOption WallTime``) and the median per-call time
is printed as a ``name,nanoseconds`` CSV line on stdout. Names match the
Haskell tasty-bench names with the group separator written as a dot.

Why 0.2 s per batch: the batches time the same workload over and over, and
many workloads are stateful (a History that grows with every append, a
database table that fills, a server connection that warms up). With the
earlier 0.05 s default a fast row ran for half a second in all, far less than
tasty-bench spends on the Haskell twin, so the two sides measured different
amounts of accumulated state, and server-bound rows were dominated by a
handful of slow round trips. At 0.2 s a row runs for about 2 s, comparable
to tasty-bench at ``--stdev 5``. Garbage collection stays enabled, since the
Haskell figures include the RTS's collections too.
"""

import os
import re
import statistics
import sys
import time
from typing import Optional

BATCH_SECONDS = float(os.environ.get("PETRUS_BENCH_BATCH_SECONDS", "0.2"))
BATCHES = int(os.environ.get("PETRUS_BENCH_BATCHES", "10"))


def _batch(fn, number: int) -> int:
    start = time.perf_counter_ns()
    for _ in range(number):
        fn()
    return time.perf_counter_ns() - start


def measure(fn, number: Optional[int] = None) -> float:
    """Median nanoseconds per call of ``fn()``. With ``number``, every batch
    is exactly that many calls (no calibration)."""
    fn()
    if number is None:
        number = 1
        while True:
            elapsed = _batch(fn, number)
            if elapsed >= BATCH_SECONDS * 1e9 or number >= 1 << 30:
                break
            number *= 2 if elapsed == 0 else max(2, min(10, int(BATCH_SECONDS * 1e9 / max(elapsed, 1)) + 1))
    samples = [_batch(fn, number) / number for _ in range(BATCHES)]
    return statistics.median(samples)


ONLY = os.environ.get("PETRUS_BENCH_ONLY")


def selected(name: str) -> bool:
    """Whether to time the row: every row, or with ``PETRUS_BENCH_ONLY`` set
    (scripts/bench-compare --python-only, scripts/bench-gate) only the rows
    whose dotted name (``group.row``) the regular expression matches."""
    return not ONLY or re.search(ONLY, name.replace("/", ".")) is not None


def report(name: str, fn, number: Optional[int] = None) -> None:
    """Print ``name,nanoseconds``. Pass ``number`` for a stateful or
    fsync-bound row whose Haskell twin is timed with the same protocol and
    the same fixed batch (petrus-test-support's Petrus.TestSupport.BenchTwin),
    so both sides make exactly the same calls."""
    if not selected(name):
        return
    print(f"{name},{measure(fn, number):.1f}", flush=True)
    print(f"  {name}", file=sys.stderr, flush=True)
