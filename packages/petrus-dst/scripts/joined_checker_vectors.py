"""Record the reference's joined-world checker verdicts for the checker unit tests.

The pure checker tests of ``tests/dst/test_joined_*world.py`` (every
``test_*checker*`` function; none needs PostgreSQL) build observations by
hand and assert on one checker class's verdict. This script runs those same
test functions with every joined checker class's ``check`` wrapped by a
recorder, so each (observation, full verdict) pair the reference computes is
kept, and the Haskell checkers are compared on every ``detail`` field, not
only the asserted ones.

The close checkers (which the reference only exercises through the replayed
fixtures) also get one vector per recorded reset-checker observation,
translated into the close vocabulary.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/joined_checker_vectors.py \
        ../../packages/petrus-dst/test/data/joined-checkers.json
"""

from __future__ import annotations

import importlib
import inspect
import json
import sys
from copy import deepcopy
from pathlib import Path

from petrus.testing.dst import Observation

MODULES = [
    "tests.dst.test_joined_world",
    "tests.dst.test_joined_creation_world",
    "tests.dst.test_joined_registration_world",
    "tests.dst.test_joined_seal_world",
]
WORLDS = [
    "tests.dst.joined_world",
    "tests.dst.joined_creation_world",
    "tests.dst.joined_registration_world",
    "tests.dst.joined_seal_world",
]


def dump(observation: Observation) -> object:
    return observation.model_dump(mode="json")


def checker_classes():
    for world in WORLDS:
        module = importlib.import_module(world)
        for name, value in vars(module).items():
            if inspect.isclass(value) and name.endswith("AuthorityChecker") and value.__module__ == world:
                yield value


def main() -> None:
    out = Path(sys.argv[1])
    vectors: list[dict[str, object]] = []
    current = {"test": ""}
    counters: dict[str, int] = {}

    def recorder(cls, original):
        def check(self, observation):
            result = original(self, observation)
            test = current["test"]
            counters[test] = counters.get(test, 0) + 1
            vectors.append(
                {
                    "checker": cls.identity.name,
                    "name": f"{test}.{counters[test]}",
                    "observation": dump(observation),
                    "result": {"detail": deepcopy(result.detail), "passed": result.passed},
                }
            )
            return result

        return check

    classes = sorted(set(checker_classes()), key=lambda cls: cls.__name__)
    originals = {cls: cls.check for cls in classes}
    for cls in classes:
        cls.check = recorder(cls, originals[cls])
    try:
        for module_name in MODULES:
            module = importlib.import_module(module_name)
            for name, function in vars(module).items():
                if not (name.startswith("test_") and "checker" in name and inspect.isfunction(function)):
                    continue
                if inspect.signature(function).parameters:
                    continue
                current["test"] = f"{module_name.rsplit('.', 1)[1]}.{name}"
                function()
    finally:
        for cls, original in originals.items():
            cls.check = original

    world = importlib.import_module("tests.dst.joined_world")
    close_of = {
        world.JoinedResetRefusalAuthorityChecker.identity.name: world.JoinedCloseRefusalAuthorityChecker,
        world.JoinedAcceptedResetAuthorityChecker.identity.name: world.JoinedAcceptedCloseAuthorityChecker,
    }

    def as_close(value: dict[str, object]) -> dict[str, object]:
        changed = deepcopy(value)
        changed["record_types"] = ["ScopeClosed" if r == "ScopeReset" else r for r in changed["record_types"]]
        changed["lifecycle_attempts"] = [
            {
                **attempt,
                "phase": "scope_close" if attempt["phase"] == "scope_reset" else attempt["phase"],
                "record_types": ["ScopeClosed" if r == "ScopeReset" else r for r in attempt["record_types"]],
            }
            for attempt in changed["lifecycle_attempts"]
        ]
        changed["scope_closes"] = changed.pop("scope_resets")
        changed["close_refusals"] = changed.pop("reset_refusals")
        if "reset_ack_losses" in changed:
            changed["close_ack_losses"] = changed.pop("reset_ack_losses")
        return changed

    for vector in list(vectors):
        cls = close_of.get(vector["checker"])
        if cls is None:
            continue
        source = Observation.model_validate(vector["observation"])
        observation = source.model_copy(update={"value": as_close(source.value)})
        result = cls().check(observation)
        vectors.append(
            {
                "checker": cls.identity.name,
                "name": f"extra.close-from.{vector['name']}",
                "observation": dump(observation),
                "result": {"detail": result.detail, "passed": result.passed},
            }
        )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"vectors": vectors}, indent=1, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
