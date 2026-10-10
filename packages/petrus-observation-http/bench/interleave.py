#!/usr/bin/env python3
"""Interleave this package's Haskell and Python benchmarks and tabulate them.

    python3 packages/<package>/bench/interleave.py [REPETITIONS]

Run from anywhere. Each repetition runs ``cabal bench <package>`` (tasty-bench,
``--csv``, run with ``+RTS -M2G``) and ``bench/python_bench.py`` (in the
pinned upstream environment, ``upstream/petrus/.venv``) back to back,
alternating which goes first, and records the 1-minute load average around
every run. It prints a Markdown table of the median over repetitions of each
row (tasty-bench means for Haskell, scripts/bench_timing.py medians for
Python), with the per-repetition figures, and the load-average range. Raw
CSV files go to bench-results/tmp/ (ignored by git).
"""

from __future__ import annotations

import csv
import os
import statistics
import subprocess
import sys
from pathlib import Path

BENCH = Path(__file__).resolve().parent
PACKAGE = BENCH.parent.name
ROOT = BENCH.parent.parent.parent
TMP = ROOT / "bench-results" / "tmp"
UPSTREAM = ROOT / "upstream" / "petrus"


def environment() -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(Path.home() / ".ghcup" / "bin"), env.get("PATH", "")])
    return env


def load_average() -> float:
    return os.getloadavg()[0]


def haskell(repetition: int) -> dict[str, float]:
    output = TMP / f"{PACKAGE}.haskell.{repetition}.csv"
    if output.exists():
        output.unlink()
    options = f"--csv {output} --stdev 5 --timeout 300 +RTS -M2G -RTS"
    subprocess.run(
        ["cabal", "bench", PACKAGE, "-j2", "--benchmark-options", options],
        cwd=ROOT,
        env=environment(),
        check=True,
        stdout=subprocess.DEVNULL,
    )
    results = {}
    with output.open(newline="") as stream:
        for row in csv.DictReader(stream):
            name = row["Name"].removeprefix("All.")
            results[name] = float(row["Mean (ps)"]) / 1000.0
    return results


def python(repetition: int) -> dict[str, float]:
    completed = subprocess.run(
        [str(UPSTREAM / ".venv" / "bin" / "python"), "-I", str(BENCH / "python_bench.py")],
        cwd=UPSTREAM,
        env=environment(),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    (TMP / f"{PACKAGE}.python.{repetition}.csv").write_text(completed.stdout)
    results = {}
    for line in completed.stdout.splitlines():
        name, _, value = line.rpartition(",")
        if name:
            results[name] = float(value)
    return results


def human(ns: float | None) -> str:
    if ns is None:
        return "—"
    for unit, scale in (("s", 1e9), ("ms", 1e6), ("µs", 1e3)):
        if ns >= scale:
            return f"{ns / scale:.3g} {unit}"
    return f"{ns:.3g} ns"


def main() -> int:
    repetitions = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    TMP.mkdir(parents=True, exist_ok=True)
    runs: list[tuple[dict[str, float], dict[str, float]]] = []
    loads = []
    for repetition in range(1, repetitions + 1):
        loads.append(load_average())
        if repetition % 2:
            ours = haskell(repetition)
            loads.append(load_average())
            theirs = python(repetition)
        else:
            theirs = python(repetition)
            loads.append(load_average())
            ours = haskell(repetition)
        loads.append(load_average())
        runs.append((ours, theirs))
        print(f"repetition {repetition} done, load average {loads[-3]:.2f} / {loads[-2]:.2f} / {loads[-1]:.2f}", file=sys.stderr)
    print(f"Load average (1 min) during the runs: {min(loads):.2f} to {max(loads):.2f}.\n")
    print("| Benchmark | Haskell | Python | Python / Haskell | Haskell per repetition | Python per repetition |")
    print("|---|---:|---:|---:|---|---|")
    names = list(runs[0][0]) + [name for name in runs[0][1] if name not in runs[0][0]]
    for name in names:
        ours = [run[0][name] for run in runs if name in run[0]]
        theirs = [run[1][name] for run in runs if name in run[1]]
        h = statistics.median(ours) if ours else None
        p = statistics.median(theirs) if theirs else None
        ratio = f"{p / h:.2f}×" if h and p else "—"
        print(
            f"| `{name}` | {human(h)} | {human(p)} | {ratio} | "
            f"{', '.join(human(x) for x in ours)} | {', '.join(human(x) for x in theirs)} |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
