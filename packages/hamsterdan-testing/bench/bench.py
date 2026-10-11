"""Python side of the hamsterdan-testing benchmarks (same inputs as Main.hs).

    "$(scripts/upstream-python hamsterdan)" -I -B \
        packages/hamsterdan-testing/bench/bench.py [PREFIX ...]

Reads test/corpus/oracle.jsonl next to this package and imports
differential/journeys_reference.py for the journeys' determinism seams, so
it can run from any directory. With PREFIX arguments, only the rows whose
names start with one of them run (``journeys/``, ``oracle/``). Results and
the Haskell side are in RESULTS.md.

Prints the time per pass: the best of 5 timeit repeats (3 for a pass over
50 ms), each repeat running the pass enough times to take about half a
second, and at least once.
"""

from __future__ import annotations

import contextlib
import functools
import json
import os
import sys
import tempfile
import timeit
from pathlib import Path
from types import SimpleNamespace

import pytest

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


def journey_case(name: str):
    """One journey from an empty directory to its ``JourneyResult``.

    The upstream ``run_<name>`` runs unchanged, under the same determinism
    seams ``differential/journeys_reference.py`` applies (counted delivery
    ids, the fixed host clock, fixed Git dates, source-order intents).
    """

    def case() -> None:
        uuid4, _ = journeys_reference.counted_uuid4()
        with tempfile.TemporaryDirectory(prefix="journey") as directory, pytest.MonkeyPatch.context() as monkeypatch:
            monkeypatch.setattr(SCENARIOS, "uuid", SimpleNamespace(uuid4=uuid4))
            monkeypatch.setattr(
                SCENARIOS,
                "HostService",
                functools.partial(journeys_reference.HostService, clock=lambda: journeys_reference.CLOCK),
            )
            journeys_reference.intent_order(monkeypatch)
            getattr(SCENARIOS, f"run_{name}")(Path(directory).resolve(), monkeypatch)

    return case


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "differential"))
import journeys_reference  # noqa: E402

SCENARIOS = journeys_reference.scenarios_module()
journeys_reference.git_determinism()

CASES = {
    f"oracle/evaluate every admitted corpus document ({len(FACTS)})": evaluate_all,
    f"oracle/load and evaluate every admitted corpus document ({len(FACTS)})": load_and_evaluate_all,
    f"oracle/evaluate_liveness x12 over every expectation ({len(FACTS)})": liveness_all,
    **{f"journeys/{name}": journey_case(name) for name in journeys_reference.JOURNEYS},
}


def main() -> None:
    selected = sys.argv[1:]
    for name, case in CASES.items():
        if selected and not any(name.startswith(prefix) for prefix in selected):
            continue
        # The journeys print the Worker's event lines; keep them off the table.
        with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink):
            trial = timeit.timeit(case, number=1)
            number = max(1, int(0.5 / max(trial, 1e-9)))
            repeat = 5 if trial < 0.05 else 3
            best = min(timeit.repeat(case, number=number, repeat=repeat)) / number
        print(f"{name:72s} {best * 1e3:10.3f} ms", flush=True)


if __name__ == "__main__":
    main()
