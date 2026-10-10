"""Differential corpus: generated toy scripts authored by the Python reference.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/generated_stories.py \
        ../../packages/petrus-dst/test/data/generated-stories.json

Each script is a seeded random sequence of authored actions (commands,
including checker-violating ones, observations, faults, crash and restart,
the fair phase, steps) over the queue toys under a small random budget,
followed by a settle loop (step while work is pending, otherwise finish
quiescent). The vector keeps every action's refusal (class and message),
the final disposition, the artifact bytes (or the refusal to produce one),
and the replay result of the artifact through fresh toys. The Haskell
suite runs the same scripts (test/Spec/Generated.hs) and must match all of
it exactly.
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

from world_stories import FaultQueueProfile, budget, replayed

from petrus.testing.dst import Disposition, FaultDisposition, World, encode_artifact
from tests.dst.test_world import QueueProfile, RejectBadValueChecker

SCRIPTS = 400
SETTLE = 64


def generate(rng: random.Random) -> dict:
    actions = []
    for _ in range(rng.randint(0, 14)):
        roll = rng.randrange(15)
        if roll < 5:
            actions.append(["step"])
        elif roll < 9:
            actions.append(["record", rng.choice(["a", "b", "c", "bad"])])
        elif roll < 11:
            actions.append(["observe"])
        elif roll < 13:
            actions.append(["fault", rng.choice(["refuse", "duplicate"]), rng.randint(1, 2)])
        elif roll < 14:
            actions.append(["crash"])
        else:
            actions.append(["fair"])
    return {
        "faulty": rng.random() < 0.5,
        "checked": rng.random() < 0.5,
        "limits": [
            rng.randint(2, 16),
            rng.randint(2, 6),
            rng.randint(0, 2),
            rng.randint(5, 12),
            rng.randint(0, 2),
            rng.randint(1, 3),
        ],
        "actions": actions,
    }


def error_of(call) -> dict | None:
    try:
        call()
    except Exception as caught:  # noqa: BLE001 - the class and message are the vector
        return {"type": type(caught).__name__, "message": str(caught)}
    return None


def perform(world: World, action: list) -> None:
    kind = action[0]
    if kind == "step":
        world.step()
    elif kind == "record":
        world.timeline().command("queue.record", {"id": action[1]})
    elif kind == "observe":
        world.timeline().observe("queue.state")
    elif kind == "fault":
        world.timeline().activate_fault(
            "f", "queue.apply", occurrence=action[2], disposition=FaultDisposition(action[1])
        )
    elif kind == "crash":
        world.timeline().crash("cut")
        world.restart()
    elif kind == "fair":
        world.timeline().begin_fair()
    else:
        raise AssertionError(kind)


def settle(world: World) -> None:
    if world.pending():
        world.step()
    else:
        world.timeline().finish(Disposition.QUIESCENT)


def author(script: dict) -> dict:
    def profile():
        return FaultQueueProfile() if script["faulty"] else QueueProfile()

    def checkers():
        return (RejectBadValueChecker(),) if script["checked"] else ()

    world = World(profile(), budget(*script["limits"]), checkers=checkers())
    try:
        errors = [error_of(lambda action=action: perform(world, action)) for action in script["actions"]]
        settling = []
        for _ in range(SETTLE):
            if world.disposition is not None:
                break
            settling.append(error_of(lambda: settle(world)))
        disposition = None if world.disposition is None else world.disposition.value
        try:
            artifact = world.artifact("generated-story")
        except Exception as caught:  # noqa: BLE001
            artifact = None
            refused = {"type": type(caught).__name__, "message": str(caught)}
    finally:
        world.close()
    out = {"script": script, "errors": errors, "settling": settling, "disposition": disposition}
    if artifact is None:
        out["artifact_error"] = refused
    else:
        out["artifact"] = encode_artifact(artifact).decode()
        out["replay"] = replayed(artifact, [profile()], checkers())
    return out


def main() -> int:
    stories = [author(generate(random.Random(seed))) for seed in range(SCRIPTS)]
    Path(sys.argv[1]).write_text(json.dumps({"stories": stories}, sort_keys=True, ensure_ascii=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
