"""Python side of the hamsterdan-testing benchmarks (same inputs as Main.hs).

    PYTHONDONTWRITEBYTECODE=1 upstream/hamsterdan/.venv/bin/python -I \
        packages/hamsterdan-testing/bench/bench.py

Reads test/corpus/oracle.jsonl next to this package, so it can run from any
directory. Results and the Haskell side are in RESULTS.md.

Prints the time per pass (best of 5 timeit repeats; each repeat runs the
pass enough times to take about half a second).
"""

from __future__ import annotations

import json
import timeit
from pathlib import Path

from hamsterdan.testing.readiness import FairEnvironment, ReadinessFacts, ReadinessModel, evaluate_liveness

CORPUS = Path(__file__).resolve().parents[1] / "test" / "corpus" / "oracle.jsonl"

with CORPUS.open(encoding="utf-8") as handle:
    ROWS = [json.loads(line) for line in handle if line.strip()]
INPUTS = [row["input"] for row in ROWS if "expectation" in row]
FACTS = [ReadinessFacts.load(text) for text in INPUTS]
MODEL = ReadinessModel()
EXPECTATIONS = [MODEL.evaluate(facts) for facts in FACTS]
ENVIRONMENTS = [FairEnvironment(*(index != off for index in range(5))) for off in range(-1, 5)]


def evaluate_all() -> None:
    model = ReadinessModel()
    for facts in FACTS:
        model.evaluate(facts)


def load_and_evaluate_all() -> None:
    model = ReadinessModel()
    for text in INPUTS:
        model.evaluate(ReadinessFacts.load(text))


def liveness_all() -> None:
    for expectation in EXPECTATIONS:
        for environment in ENVIRONMENTS:
            for budget in (False, True):
                evaluate_liveness(expectation, environment, budget_exhausted=budget)


CASES = {
    f"oracle/evaluate every admitted corpus document ({len(FACTS)})": evaluate_all,
    f"oracle/load and evaluate every admitted corpus document ({len(FACTS)})": load_and_evaluate_all,
    f"oracle/evaluate_liveness x12 over every expectation ({len(FACTS)})": liveness_all,
}


def main() -> None:
    for name, case in CASES.items():
        trial = timeit.timeit(case, number=1)
        number = max(1, int(0.5 / max(trial, 1e-9)))
        best = min(timeit.repeat(case, number=number, repeat=5)) / number
        print(f"{name:72s} {best * 1e3:10.3f} ms")


if __name__ == "__main__":
    main()
