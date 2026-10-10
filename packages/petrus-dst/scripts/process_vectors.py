"""Process-runner vectors from the pinned Python reference.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/process_vectors.py \
        ../../packages/petrus-dst/test/data/process-vectors.json

Two corpora:

* ``children``: the reference child (``_process_child_main``) runs toy
  entrypoints defined below; the vector keeps the exact progress file
  bytes, the exit status, and ``_process_result`` over that file. The
  Haskell child must write the same bytes for the same toy scenarios.
* ``folds``: hand-made progress files (missing, overflowing, partial,
  malformed, out of order, misplaced, mismatched) and ``_process_result``
  over each.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

from petrus.testing.dst import (
    Budget,
    BudgetV4,
    Disposition,
    ProcessBudget,
    ProcessRunSpec,
    _process_child_main,
    _process_result,
    run_process_scenario,
)
from tests.dst.test_world import QueueProfile, RejectBadValueChecker, ResourceQueueProfile

BUDGET = Budget(
    actions=8,
    queued_commands=2,
    timer_advances=1,
    logical_instant=5,
    reloads=1,
    predicate_polls=2,
    artifact_bytes=65_536,
)

RESOURCE_BUDGET = BudgetV4(
    actions=8,
    queued_commands=2,
    timer_advances=1,
    logical_instant=5,
    reloads=1,
    predicate_polls=4,
    artifact_bytes=65_536,
    profile_resources={"retained.values": 2},
)


def queue_story(session, payload):
    world = session.world(QueueProfile(), BUDGET, checkers=(RejectBadValueChecker(),))
    timeline = world.timeline()
    world.step()
    world.step()
    timeline.observe("queue.state")
    timeline.finish(Disposition.QUIESCENT)
    return world.artifact(payload["scenario_id"])


def resource_story(session, payload):
    world = session.world(ResourceQueueProfile(), RESOURCE_BUDGET, seed=7)
    timeline = world.timeline()
    timeline.run_until("queue.state", lambda observation: len(observation.value["values"]) == 2)
    timeline.crash("cut")
    world.restart()
    world.timeline().finish(Disposition.CONVERGED)
    return world.artifact(payload["scenario_id"])


def checker_failure_story(session, payload):
    world = session.world(QueueProfile(), BUDGET, checkers=(RejectBadValueChecker(),))
    timeline = world.timeline()
    world.step()
    world.step()
    try:
        timeline.command("queue.record", {"id": "bad"})
    except Exception:  # noqa: BLE001 - the invariant failure is the story
        pass
    return world.artifact(payload["scenario_id"])


def failing_story(session, payload):
    world = session.world(QueueProfile(), BUDGET)
    world.step()
    raise RuntimeError("the scenario gave up")


def wrong_identity_story(session, payload):
    world = session.world(QueueProfile(), BUDGET)
    world.step()
    world.step()
    world.timeline().finish(Disposition.QUIESCENT)
    return world.artifact("some-other-scenario")


def two_worlds_story(session, payload):
    session.world(QueueProfile(), BUDGET)
    session.world(QueueProfile(), BUDGET)
    raise AssertionError("unreachable")


def tiny_progress_story(session, payload):
    world = session.world(QueueProfile(), BUDGET)
    world.step()
    world.step()
    world.timeline().finish(Disposition.QUIESCENT)
    return world.artifact(payload["scenario_id"])


CHILDREN = [
    ("queue-story", "process_vectors:queue_story", 4_194_304),
    ("resource-story", "process_vectors:resource_story", 4_194_304),
    ("checker-failure-story", "process_vectors:checker_failure_story", 4_194_304),
    ("failing-story", "process_vectors:failing_story", 4_194_304),
    ("wrong-identity-story", "process_vectors:wrong_identity_story", 4_194_304),
    ("two-worlds-story", "process_vectors:two_worlds_story", 4_194_304),
    ("tiny-progress-story", "process_vectors:tiny_progress_story", 900),
    ("missing-entrypoint", "process_vectors:no_such_story", 4_194_304),
]


def spec_for(scenario_id: str, entrypoint: str, progress_bytes: int) -> ProcessRunSpec:
    return ProcessRunSpec(
        scenario_id=scenario_id,
        entrypoint=entrypoint,
        payload={"scenario_id": scenario_id},
        budget=ProcessBudget(
            wall_clock_ms=5_000,
            termination_grace_ms=100,
            input_bytes=64_000,
            progress_bytes=progress_bytes,
        ),
    )


def canonical(model) -> str:
    return json.dumps(model.model_dump(mode="json"), allow_nan=False, separators=(",", ":"), sort_keys=True)


def children(root: Path) -> list:
    out = []
    for scenario_id, entrypoint, progress_bytes in CHILDREN:
        spec = spec_for(scenario_id, entrypoint, progress_bytes)
        directory = root / scenario_id
        directory.mkdir()
        spec_path = directory / "spec.json"
        progress_path = directory / "progress.jsonl"
        spec_path.write_bytes(canonical(spec).encode())
        status = _process_child_main(spec_path, progress_path)
        result = _process_result(spec, status, "exited", False, progress_path)
        out.append(
            {
                "scenario_id": scenario_id,
                "spec": canonical(spec),
                "status": status,
                "progress": progress_path.read_bytes().decode(),
                "result": canonical(result),
            }
        )
    return out


def folds(root: Path, complete_progress: str, failed_progress: str) -> list:
    lines = complete_progress.splitlines(keepends=True)
    started, world, attempt, boundary = lines[0], lines[1], lines[2], lines[3]

    def frame(line: str, **changes) -> str:
        value = json.loads(line)
        value.update(changes)
        return json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n"

    def shifted(line: str) -> str:
        value = json.loads(line)
        value["journal"][0]["position"] = 1
        return json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n"

    complete_line = lines[-1]
    cases = [
        ("missing", None, 0, False),
        ("empty", "", 0, False),
        ("complete", complete_progress, 0, False),
        ("complete-nonzero", complete_progress, 3, False),
        ("complete-timed-out", complete_progress, -9, True),
        ("failed", failed_progress, 70, False),
        ("overflow", complete_progress, 0, False),
        ("partial", complete_progress + '{"kind":', 0, False),
        ("partial-timed-out", "".join(lines[:4]) + '{"kind":', -15, True),
        ("partial-only-timed-out", '{"kind":', -15, True),
        ("prefix-timed-out", "".join(lines[:5]), -9, True),
        ("unterminated", "".join(lines[:4]), 0, False),
        ("malformed", started + "not json\n", 0, False),
        ("non-object", started + "[1]\n", 0, False),
        ("unknown-kind", started + '{"kind":"other","sequence":1}\n', 0, False),
        ("invalid-frame", started + frame(world, sequence=-1), 0, False),
        ("extra-field", started + frame(world, extra=True), 0, False),
        ("blank-line", started + "\n" + world, 0, False),
        ("crlf", started.replace("\n", "\r\n") + world, 0, False),
        ("cr-only", started.replace("\n", "\r") + world, 0, False),
        ("sequence-gap", started + frame(world, sequence=2), 0, False),
        ("started-twice", started + frame(started, sequence=1), 0, False),
        ("wrong-scenario", frame(started, scenario_id="other-scenario"), 0, False),
        ("world-first", frame(world, sequence=0), 0, False),
        ("attempt-before-world", started + frame(attempt, sequence=1), 0, False),
        ("world-twice", started + world + frame(world, sequence=2), 0, False),
        ("boundary-without-attempt", started + world + frame(boundary, sequence=2), 0, False),
        ("attempt-twice", started + world + attempt + frame(attempt, sequence=3), 0, False),
        ("prefix-position", started + world + attempt + shifted(boundary), 0, False),
        ("complete-with-attempt", started + world + attempt + frame(complete_line, sequence=3), 0, False),
        ("complete-early", started + frame(complete_line, sequence=1), 0, False),
        ("complete-mismatch", started + world + attempt + boundary + frame(complete_line, sequence=4), 0, False),
        ("after-terminal", complete_progress + frame(complete_line, sequence=len(lines)), 0, False),
        ("failed-without-start", '{"code":"scenario-failed","kind":"failed","sequence":0}\n', 70, False),
        ("terminal-missing", "".join(lines[:-1]), 0, False),
        ("bad-failed-code", started + '{"code":"","kind":"failed","sequence":1}\n', 70, False),
    ]
    out = []
    for name, payload, returncode, timed_out in cases:
        scenario_id = "failing-story" if name == "failed" else "queue-story"
        limit = 1_000 if name == "overflow" else 4_194_304
        spec = spec_for(scenario_id, "process_vectors:" + scenario_id.replace("-", "_"), limit)
        path = root / f"fold-{name}.jsonl"
        if payload is not None:
            path.write_bytes(payload.encode())
        termination = "exited" if not timed_out else ("killed" if returncode == -9 else "terminated")
        result = _process_result(spec, returncode, termination, timed_out, path)
        out.append(
            {
                "name": name,
                "spec": canonical(spec),
                "progress": payload,
                "returncode": returncode,
                "termination": termination,
                "timed_out": timed_out,
                "result": canonical(result),
            }
        )
    return out


def refusal() -> dict:
    # test_process_input_budget_refuses_a_scenario_before_launch
    spec = ProcessRunSpec(
        scenario_id="process-watchdog-hang-v1",
        entrypoint="tests.dst.process_world:hang_during_command",
        payload=None,
        budget=ProcessBudget(wall_clock_ms=2_000, termination_grace_ms=100, input_bytes=1, progress_bytes=4_194_304),
    )
    try:
        run_process_scenario(spec)
    except ValueError as caught:
        return {"spec": canonical(spec), "type": type(caught).__name__, "message": str(caught)}
    raise AssertionError("the input budget did not refuse")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="petrus-dst-vectors-") as directory:
        root = Path(directory)
        child = children(root)
        complete = next(c for c in child if c["scenario_id"] == "queue-story")["progress"]
        failed = next(c for c in child if c["scenario_id"] == "failing-story")["progress"]
        out = {"children": child, "folds": folds(root, complete, failed), "refusal": refusal()}
    Path(sys.argv[1]).write_text(json.dumps(out, sort_keys=True, indent=1, ensure_ascii=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
