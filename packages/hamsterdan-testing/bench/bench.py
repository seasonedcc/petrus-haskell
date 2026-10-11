"""Python side of the hamsterdan-testing benchmarks (same inputs as Main.hs).

    "$(scripts/upstream-python hamsterdan)" -I -B \
        packages/hamsterdan-testing/bench/bench.py [PREFIX ...]

Reads test/corpus/oracle.jsonl next to this package and imports
differential/journeys_reference.py for the journeys' determinism seams and
differential/world_reference.py for the named World scenarios, so it can run
from any directory. With PREFIX arguments, only the rows whose names start
with one of them run (``journeys/``, ``oracle/``, ``world/``). Results and
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


def author_world(name: str, root: Path) -> bytes:
    """``world_reference.py author NAME ROOT``: the artifact's bytes."""
    scenario, seed, budget = world_reference.SCENARIOS[name]
    world = ReadinessWorld(root / "live", budget=budget, seed=seed)
    try:
        artifact = world.artifact(scenario(world))
    finally:
        world.close()
    return encode_artifact(artifact)


def world_author_case(name: str):
    """One World scenario from an empty directory to its artifact bytes."""

    def case() -> None:
        with tempfile.TemporaryDirectory(prefix="world") as directory:
            author_world(name, Path(directory).resolve())

    return case


def world_replay_case(name: str):
    """The scenario's artifact replayed from decoded bytes to the canonical
    replay-result bytes (``world_reference.py replay``). The artifact is
    authored once, on the first (untimed) call."""

    @functools.cache
    def artifact():
        with tempfile.TemporaryDirectory(prefix="world") as directory:
            return decode_artifact(author_world(name, Path(directory).resolve()))

    def case() -> None:
        authored = artifact()
        with tempfile.TemporaryDirectory(prefix="world") as directory:
            result = replay_readiness(authored, Path(directory).resolve())
            world_reference.canonical(result.model_dump(mode="json"))

    return case


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "differential"))
import journeys_reference  # noqa: E402
import world_reference  # noqa: E402
from hamsterdan.host.testing.readiness_world import ReadinessWorld, replay_readiness  # noqa: E402
from petrus.testing.dst import decode_artifact, encode_artifact  # noqa: E402

SCENARIOS = journeys_reference.scenarios_module()
journeys_reference.git_determinism()

# The same four scenarios as worldBenchmarks in Main.hs.
WORLD = ("coverage-duplicate-delivery", "authority-draft_resume", "timer-draft_resume", "git-after_acceptance")

CASES = {
    f"oracle/evaluate every admitted corpus document ({len(FACTS)})": evaluate_all,
    f"oracle/load and evaluate every admitted corpus document ({len(FACTS)})": load_and_evaluate_all,
    f"oracle/evaluate_liveness x12 over every expectation ({len(FACTS)})": liveness_all,
    **{f"journeys/{name}": journey_case(name) for name in journeys_reference.JOURNEYS},
    **{f"world/author {name}": world_author_case(name) for name in WORLD},
    **{f"world/replay {name}": world_replay_case(name) for name in WORLD},
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
