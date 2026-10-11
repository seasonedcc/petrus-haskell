"""``bench.py``'s rows in the form scripts/bench-compare reads.

    scripts/bench-compare hamsterdan-host 5 --upstream hamsterdan

Runs the same cases as ``bench.py`` (same inputs, doubles and scratch
directory), timed by scripts/bench_timing.py (median of 10 batches of at
least 0.2 s each) instead of ``bench.py``'s best of 5 ``timeit`` repeats. It
prints one ``name,nanoseconds`` line per row, named like the tasty-bench rows
of ``bench/Main.hs`` (group and benchmark joined by a dot).
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent.parent.parent / "scripts"))

import bench  # noqa: E402
from bench_timing import report  # noqa: E402


def main() -> None:
    try:
        for name, case in bench.cases().items():
            group, _, row = name.partition("/")
            report(f"{group}.{row}", case)
    finally:
        shutil.rmtree(bench.SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    main()
