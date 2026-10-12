"""Interleave the Python and Haskell benchmark harnesses and tabulate them.

From the repository root (after ``cabal build petrus-execution:bench:petrus-execution-bench``):

    upstream/petrus/.venv/bin/python packages/petrus-execution/bench/compare.py WORKDIR [ROUNDS]

WORKDIR receives the deterministic workloads (``make_workloads.py``,
about 330 MiB).  Each round runs both harnesses back to back on the same
machine state, alternating which goes first (odd rounds Python first, even
rounds Haskell first), so a warm cache or a thermal swing does not always
favour the same side. The table reports, per benchmark, the median across
rounds of each round's median, the Python/Haskell ratio (> 1 means Haskell
is faster), the lowest per-round ratio, and in how many rounds Haskell was
ahead.
"""

from __future__ import annotations

import json
import statistics
import subprocess
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
REPOSITORY = PACKAGE.parents[1]
FAKE_SDK = PACKAGE / "test/fixtures/fake_gondolin.mjs"


def run(command: list[str]) -> dict[str, float]:
    output = subprocess.run(command, check=True, capture_output=True, text=True, cwd=REPOSITORY).stdout
    return {row["name"]: row["median_ms"] for row in map(json.loads, output.splitlines())}


def main() -> None:
    workdir = Path(sys.argv[1]).resolve()
    rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    subprocess.run([sys.executable, str(PACKAGE / "bench/make_workloads.py"), str(workdir)], check=True)
    binary = subprocess.run(
        ["cabal", "list-bin", "-v0", "petrus-execution:bench:petrus-execution-bench"],
        check=True,
        capture_output=True,
        text=True,
        cwd=REPOSITORY,
    ).stdout.strip()
    python_rows: dict[str, list[float]] = {}
    haskell_rows: dict[str, list[float]] = {}
    python_command = [sys.executable, str(PACKAGE / "bench/python_bench.py"), str(workdir), str(FAKE_SDK)]
    haskell_command = [binary, str(workdir), str(FAKE_SDK)]
    for index in range(rounds):
        python_first = index % 2 == 0
        print(f"round {index + 1}/{rounds} ({'Python' if python_first else 'Haskell'} first)", file=sys.stderr, flush=True)
        sides = [(python_command, python_rows), (haskell_command, haskell_rows)]
        for command, rows in sides if python_first else reversed(sides):
            for name, value in run(command).items():
                rows.setdefault(name, []).append(value)
    print("| benchmark | Python (ms) | Haskell (ms) | Python / Haskell | lowest per round | Haskell ahead |")
    print("|---|---:|---:|---:|---:|---:|")
    for name, samples in python_rows.items():
        python = statistics.median(samples)
        haskell = statistics.median(haskell_rows[name])
        paired = [p / h for p, h in zip(samples, haskell_rows[name])]
        ahead = sum(1 for ratio in paired if ratio > 1)
        print(f"| {name} | {python:.3f} | {haskell:.3f} | {python / haskell:.2f}x | {min(paired):.2f}x | {ahead} of {len(paired)} |")


if __name__ == "__main__":
    main()
