"""Time the format CLI as a process: ``petrus-format-json`` against
``python -m petrus.cli.format_json``, start to exit.

``bench/Main.hs`` and ``bench/python_bench.py`` time the library calls; this
times what a user (or a pre-commit hook) runs: process start, argument
parsing, reading, formatting, writing, exit. Run from the repository root
with the pinned reference's virtual environment:

    "$(scripts/upstream-python petrus-engine)" -B packages/petrus-engine-file/bench/process_bench.py \\
        "$(cabal list-bin -v0 petrus-engine-file:exe:petrus-format-json)" [ROUNDS]

Scenarios (the inputs are ``python_bench.chain_text``, the same texts the
library benchmarks use):

- ``--infile/--outfile chain-N``: one file in, one file out;
- ``in place, 100 x chain-10``: 100 files named on the command line,
  rewritten in place (the inputs are restored before every run, outside the
  timed region, so every run does the same work).

Each round runs both sides once per scenario, back to back, alternating
which goes first; each side's run is timed with ``time.perf_counter`` around
``subprocess.run``. One warm-up round runs first and is not counted. The
table gives each side's median and the ratio of the medians (Python time /
Haskell time), plus the lowest ratio of a single round. Both sides' outputs
are compared byte for byte after every run.
"""

from __future__ import annotations

import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from python_bench import chain_text  # noqa: E402


def load_average() -> str:
    try:
        return " ".join(f"{x:.2f}" for x in os.getloadavg())
    except OSError:
        return "?"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    haskell = sys.argv[1]
    rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 21
    python = [sys.executable, "-m", "petrus.cli.format_json"]
    sides = {"haskell": [haskell], "python": python}

    with tempfile.TemporaryDirectory(prefix="petrus-format-json-bench-") as tmp:
        work = Path(tmp)
        inputs = {}
        for n in (10, 1000, 10000):
            path = work / f"chain-{n}.json"
            path.write_text(chain_text(n), encoding="utf-8")
            inputs[n] = path
        many = work / "many-src"
        many.mkdir()
        for i in range(100):
            (many / f"net-{i:03}.json").write_text(chain_text(10, name=f"net{i}"), encoding="utf-8")

        def stream(n: int):
            def prepare(side: str) -> list:
                out = work / f"out-{side}-{n}.json"
                return ["--infile", str(inputs[n]), "--outfile", str(out)]

            def output(side: str) -> bytes:
                return (work / f"out-{side}-{n}.json").read_bytes()

            return prepare, output

        def in_place():
            def prepare(side: str) -> list:
                target = work / f"many-{side}"
                shutil.rmtree(target, ignore_errors=True)
                shutil.copytree(many, target)
                return [str(p) for p in sorted(target.iterdir())]

            def output(side: str) -> bytes:
                return b"".join(p.read_bytes() for p in sorted((work / f"many-{side}").iterdir()))

            return prepare, output

        scenarios = [
            ("--infile/--outfile chain-10", *stream(10)),
            ("--infile/--outfile chain-1000", *stream(1000)),
            ("--infile/--outfile chain-10000", *stream(10000)),
            ("in place, 100 x chain-10", *in_place()),
        ]

        start_load = load_average()
        times = {name: {side: [] for side in sides} for name, _, _ in scenarios}
        for round_ in range(rounds + 1):
            for name, prepare, output in scenarios:
                order = list(sides) if round_ % 2 == 0 else list(reversed(list(sides)))
                for side in order:
                    argv = sides[side] + prepare(side)
                    t0 = time.perf_counter()
                    done = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    elapsed = time.perf_counter() - t0
                    if done.returncode != 0:
                        print(f"{side} failed on {name}: {done.stderr.decode()}", file=sys.stderr)
                        return 1
                    if round_ > 0:
                        times[name][side].append(elapsed)
                if output("haskell") != output("python"):
                    print(f"outputs differ on {name}", file=sys.stderr)
                    return 1
        end_load = load_average()

    print(f"{platform.machine()} {platform.system()} {platform.release()}, Python {platform.python_version()}, "
          f"{rounds} rounds, load average {start_load} at start, {end_load} at end")
    print()
    print("| scenario | Python | Haskell | speed-up | lowest round |")
    print("| --- | ---: | ---: | ---: | ---: |")
    for name, _, _ in scenarios:
        py = times[name]["python"]
        hs = times[name]["haskell"]
        per_round = [p / h for p, h in zip(py, hs)]
        ratio = statistics.median(py) / statistics.median(hs)
        print(f"| {name} | {statistics.median(py) * 1000:.1f} ms | {statistics.median(hs) * 1000:.1f} ms | "
              f"{ratio:.2f}× | {min(per_round):.2f}× |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
