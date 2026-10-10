"""Author the toy World stories with the pinned Python reference.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/world_stories.py \
        ../../packages/petrus-dst/test/data/world-stories.json

Every story mirrors one Engine-independent test of tests/dst/test_world.py
(plus a few extra toy stories that reach faults, seeds, crashes, and
run_until). The Haskell suite replays the same stories with its own toy
profiles (test/Toy.hs) and requires the exact artifact bytes, replay
results, and exception classes and messages recorded here.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from petrus.testing.dst import (
    ActionDisposition,
    ApplyResult,
    Budget,
    BudgetExhausted,
    BudgetV4,
    ChoiceAuthority,
    Command,
    Disposition,
    Fault,
    FaultDisposition,
    GenerationStart,
    InvariantViolation,
    ObservationRequest,
    ProfileIdentity,
    ResourceUsage,
    ScenarioArtifactV1,
    ScenarioContext,
    ScenarioRegistry,
    ScheduledCommand,
    World,
    digest_json,
    encode_artifact,
    replay,
)
from tests.dst.test_world import (
    PassingBadValueChecker,
    QueueProfile,
    RaisingReservedExceptionChecker,
    RaisingReservedExceptionProfile,
    RejectBadValueChecker,
    RejectingChecker,
    ResourceQueueProfile,
    resource_budget,
)

LEGACY_FIXTURE = Path("tests/dst/fixtures/projection-crash-recovery-world-v1.json")


def canonical(value) -> str:
    return json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True)


def dump(model) -> object:
    return model.model_dump(mode="json")


def budget(actions, queued, timer, logical, reloads, polls, artifact_bytes=65_536) -> Budget:
    return Budget(
        actions=actions,
        queued_commands=queued,
        timer_advances=timer,
        logical_instant=logical,
        reloads=reloads,
        predicate_polls=polls,
        artifact_bytes=artifact_bytes,
    )


def error(call) -> dict | None:
    try:
        call()
    except Exception as caught:  # noqa: BLE001 - the class and message are the vector
        return {"type": type(caught).__name__, "message": str(caught)}
    return None


def replayed(artifact, profiles, checkers=()) -> dict:
    registry = ScenarioRegistry()
    for profile in profiles:
        registry.register_profile(profile)
    for checker in checkers:
        registry.register_checker(checker)
    try:
        result = replay(artifact, registry)
    except Exception as caught:  # noqa: BLE001
        return {"error": {"type": type(caught).__name__, "message": str(caught)}}
    return {"result": canonical(dump(result))}


def finished(world: World, scenario_id: str) -> str:
    return encode_artifact(world.artifact(scenario_id)).decode()


class IncompleteResourceProfile(ResourceQueueProfile):
    def resource_usage(self, generation):
        del generation
        return ResourceUsage(values={"retained.other": 0})


class FaultQueueProfile(QueueProfile):
    """A queue toy that accepts faults on its apply cut and reads the clock."""

    identity = ProfileIdentity(
        name="petrus.testing.fault-queue-proof",
        version=1,
        digest=digest_json({"command": "queue.record", "fault": "queue.apply", "observation": "queue.state"}),
    )

    def validate_fault(self, fault: Fault) -> Fault:
        if fault.target != "queue.apply":
            raise ValueError("fault queue proof faults only target queue.apply")
        return fault

    def apply(self, generation, command: Command, context: ScenarioContext) -> ApplyResult:
        identifier = command.payload["id"]
        matched = context.faults("queue.apply")
        if any(fault.disposition == "refuse" for fault in matched):
            return ApplyResult(
                disposition=ActionDisposition.REFUSED_EXPECTED.value,
                value={"refused": identifier, "at": context.now()},
                scheduled=[],
            )
        generation.append(identifier)
        scheduled = []
        if any(fault.disposition == "duplicate" for fault in matched):
            scheduled.append(
                ScheduledCommand(
                    instant=context.now() + 1,
                    command=Command(profile=self.identity, name="queue.record", payload={"id": identifier + "-again"}),
                )
            )
        return ApplyResult(
            disposition=ActionDisposition.APPLIED.value,
            value={"values": list(generation), "at": context.now()},
            scheduled=scheduled,
        )


def stable_order() -> dict:
    world = World(QueueProfile(), budget(4, 2, 1, 5, 0, 1))
    timeline = world.timeline()
    first = world.step()
    second = world.step()
    observation = timeline.observe("queue.state")
    timeline.finish(Disposition.QUIESCENT)
    artifact = world.artifact("stable-order-v1")
    world.close()
    return {
        "steps": [dump(first), dump(second)],
        "observation": dump(observation),
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()]),
    }


def resource_v4() -> dict:
    world = World(ResourceQueueProfile(), resource_budget(2))
    timeline = world.timeline()
    try:
        world.step()
        world.step()
        timeline.observe("queue.state")
        timeline.finish(Disposition.QUIESCENT)
        artifact = world.artifact("resource-bounded-queue-v4")
    finally:
        world.close()
    return {
        "resources": [entry.name for entry in world.journal if entry.kind == "resource"],
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [ResourceQueueProfile()]),
    }


def resource_exhaustion_v4() -> dict:
    world = World(ResourceQueueProfile(), resource_budget(1))
    try:
        world.step()
        refused = error(world.step)
        artifact = world.artifact("resource-budget-exhaustion-v4")
    finally:
        world.close()
    return {
        "error": refused,
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [ResourceQueueProfile()]),
    }


def resource_keyset() -> dict:
    return {"error": error(lambda: World(IncompleteResourceProfile(), resource_budget(2)))}


def constructor_checker_refusal() -> dict:
    profile = QueueProfile()
    refused = error(lambda: World(profile, budget(8, 2, 1, 5, 0, 1), checkers=(RejectingChecker(),)))
    return {"error": refused, "closes": profile.closes}


def finish_pending() -> dict:
    out = {}
    for disposition in [Disposition.CONVERGED, Disposition.QUIESCENT, Disposition.EXTERNAL_WAIT, Disposition.QUARANTINED]:
        world = World(QueueProfile(), budget(2, 2, 1, 5, 0, 1))
        try:
            out[disposition.value] = error(lambda: world.timeline().finish(disposition))
        finally:
            world.close()
    return out


def fair_phase() -> dict:
    world = World(QueueProfile(), budget(8, 2, 1, 5, 0, 1))
    timeline = world.timeline()
    try:
        world.step()
        world.step()
        timeline.begin_fair()
        errors = [
            error(lambda: timeline.command("queue.record", {"id": "late"})),
            error(lambda: timeline.activate_fault("late", "cut")),
            error(lambda: timeline.crash("cut")),
            error(timeline.begin_fair),
            error(lambda: timeline.finish(Disposition.EXTERNAL_WAIT)),
        ]
        timeline.finish(Disposition.QUIESCENT)
        artifact = world.artifact("fair-phase-v3")
    finally:
        world.close()
    return {
        "errors": errors,
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()]),
    }


def fault_validation() -> dict:
    world = World(QueueProfile(), budget(2, 2, 1, 5, 0, 1))
    try:
        refused = error(lambda: world.timeline().activate_fault("unsupported", "cut"))
        kinds = [operation.kind for operation in world.operations]
    finally:
        world.close()
    return {"error": refused, "kinds": kinds}


def action_timer_logical() -> dict:
    action_world = World(QueueProfile(), budget(1, 2, 1, 5, 0, 1))
    try:
        action_world.step()
        action = error(action_world.step)
        artifact = action_world.artifact("budget-exhaustion")
    finally:
        action_world.close()
    timer_world = World(QueueProfile(), budget(1, 2, 0, 5, 0, 1))
    try:
        timer = error(timer_world.step)
    finally:
        timer_world.close()
    profile = QueueProfile()
    logical = error(lambda: World(profile, budget(1, 2, 1, 4, 0, 1)))
    return {
        "action": action,
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()]),
        "timer": timer,
        "logical": logical,
        "logical_closes": profile.closes,
    }


def queue_reload_bytes() -> dict:
    profile = QueueProfile()
    queued = error(lambda: World(profile, budget(1, 1, 1, 5, 0, 1)))
    reload_world = World(QueueProfile(), budget(2, 2, 1, 5, 0, 1))
    reload_world.timeline().crash("cut")
    reloads = error(reload_world.restart)
    reload_world.close()
    value = json.loads(LEGACY_FIXTURE.read_bytes())
    value["budget"]["artifact_bytes"] = 1
    artifact = ScenarioArtifactV1.model_validate(value, strict=True)
    return {
        "queued": queued,
        "queued_closes": profile.closes,
        "reloads": reloads,
        "artifact_bytes": error(lambda: encode_artifact(artifact)),
    }


def authored_checker_failure() -> dict:
    world = World(QueueProfile(), budget(4, 2, 1, 5, 0, 1), checkers=(RejectBadValueChecker(),))
    timeline = world.timeline()
    try:
        world.step()
        world.step()
        refused = error(lambda: timeline.command("queue.record", {"id": "bad"}))
        artifact = world.artifact("authored-checker-failure")
    finally:
        world.close()
    replay_profile = QueueProfile()
    passing = replayed(artifact, [replay_profile], [PassingBadValueChecker()])
    return {
        "error": refused,
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()], [RejectBadValueChecker()]),
        "passing_replay": passing,
        "passing_values": replay_profile.values,
    }


def not_reclassified() -> dict:
    b = budget(4, 2, 1, 5, 0, 1)
    profile_world = World(RaisingReservedExceptionProfile(), b)
    try:
        profile_error = error(profile_world.step)
        profile_state = [
            None if profile_world.disposition is None else profile_world.disposition.value,
            [operation.kind for operation in profile_world.operations],
            [entry.kind for entry in profile_world.journal],
        ]
    finally:
        profile_world.close()
    checker_world = World(QueueProfile(), b, checkers=(RaisingReservedExceptionChecker(),))
    try:
        checker_error = error(checker_world.step)
        checker_state = [
            None if checker_world.disposition is None else checker_world.disposition.value,
            [operation.kind for operation in checker_world.operations],
            [entry.kind for entry in checker_world.journal],
        ]
    finally:
        checker_world.close()
    return {
        "profile_error": profile_error,
        "profile_state": profile_state,
        "checker_error": checker_error,
        "checker_state": checker_state,
    }


def no_choices() -> dict:
    world = World(QueueProfile(), budget(2, 2, 1, 5, 0, 1))
    try:
        return {"error": error(lambda: world.choices)}
    finally:
        world.close()


def seeded_v3() -> dict:
    world = World(QueueProfile(), budget(8, 3, 1, 5, 1, 2), seed=1729)
    timeline = world.timeline()
    try:
        index = world.choices.index(ChoiceAuthority.WORKLOAD, 10)
        identifier = world.choices.identifier("queue")
        applied = timeline.command("queue.record", {"id": identifier, "n": index})
        world.step()
        world.step()
        timeline.crash("cut")
        stale = error(lambda: timeline.command("queue.record", {"id": "stale"}))
        generation = world.restart()
        fresh = world.timeline()
        observation = fresh.observe("queue.state")
        fresh.finish(Disposition.QUIESCENT)
        artifact = world.artifact("seeded-queue-v3")
    finally:
        world.close()
    return {
        "index": index,
        "identifier": identifier,
        "applied": dump(applied),
        "stale": stale,
        "generation": generation,
        "observation": dump(observation),
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()]),
    }


def seeded_v4() -> dict:
    polled = BudgetV4(
        actions=8,
        queued_commands=2,
        timer_advances=1,
        logical_instant=5,
        reloads=0,
        predicate_polls=4,
        artifact_bytes=65_536,
        profile_resources={"retained.values": 3},
    )
    world = World(ResourceQueueProfile(), polled, seed=7)
    timeline = world.timeline()
    try:
        order = world.choices.index(ChoiceAuthority.EVENT_ORDER, 3)
        fault_pick = world.choices.index(ChoiceAuthority.FAULT, 5)
        observation = timeline.run_until(
            "queue.state", lambda o: len(o.value["values"]) == 2, payload={"order": order, "fault": fault_pick}
        )
        timeline.finish(Disposition.CONVERGED)
        artifact = world.artifact("seeded-queue-v4")
    finally:
        world.close()
    return {
        "observation": dump(observation),
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [ResourceQueueProfile()]),
    }


def run_until_failed() -> dict:
    world = World(QueueProfile(), budget(8, 2, 1, 5, 0, 4))
    timeline = world.timeline()
    try:
        refused = error(lambda: timeline.run_until("queue.state", lambda o: False))
        disposition = None if world.disposition is None else world.disposition.value
        timeline.finish(Disposition.EXTERNAL_WAIT)
        artifact = world.artifact("run-until-external-wait")
    finally:
        world.close()
    return {
        "error": refused,
        "disposition": disposition,
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()]),
    }


def poll_budget() -> dict:
    world = World(QueueProfile(), budget(8, 2, 1, 5, 0, 1))
    timeline = world.timeline()
    try:
        refused = error(lambda: timeline.run_until("queue.state", lambda o: False))
        disposition = None if world.disposition is None else world.disposition.value
        artifact = world.artifact("poll-budget-exhaustion")
    finally:
        world.close()
    return {
        "error": refused,
        "disposition": disposition,
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()]),
    }


def fault_story() -> dict:
    world = World(FaultQueueProfile(), budget(8, 3, 2, 6, 0, 1))
    timeline = world.timeline()
    try:
        timeline.activate_fault("refuse-second", "queue.apply", occurrence=2, disposition=FaultDisposition.REFUSE)
        timeline.activate_fault(
            "duplicate-first", "queue.apply", occurrence=1, disposition=FaultDisposition.DUPLICATE, payload={"n": 1}
        )
        wrong = error(lambda: timeline.activate_fault("elsewhere", "queue.other"))
        steps = [dump(world.step()) for _ in range(3)]
        observation = timeline.observe("queue.state")
        timeline.finish(Disposition.QUIESCENT)
        artifact = world.artifact("fault-queue-v3")
    finally:
        world.close()
    return {
        "wrong": wrong,
        "steps": steps,
        "observation": dump(observation),
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [FaultQueueProfile()]),
    }


def refusals() -> dict:
    world = World(QueueProfile(), budget(4, 2, 1, 5, 0, 1))
    timeline = world.timeline()
    try:
        unknown = error(lambda: timeline.observe("nope"))
        invalid = error(lambda: timeline.command("other", {}))
        early = error(lambda: world.artifact("too-early"))
        restart_live = error(world.restart)
        world.step()
        world.step()
        timeline.finish(Disposition.QUIESCENT)
        late = error(lambda: timeline.command("queue.record", {"id": "late"}))
        twice = error(lambda: timeline.finish(Disposition.QUIESCENT))
        artifact = world.artifact("refusals-v3")
    finally:
        world.close()
    registry = ScenarioRegistry()
    registry.register_profile(QueueProfile())
    registry.register_checker(RejectingChecker())
    return {
        "unknown": unknown,
        "invalid": invalid,
        "early": early,
        "restart_live": restart_live,
        "late": late,
        "twice": twice,
        "artifact": encode_artifact(artifact).decode(),
        "replay": replayed(artifact, [QueueProfile()]),
        "missing_profile": replayed(artifact, []),
        "duplicate_profile": error(lambda: registry.register_profile(QueueProfile())),
        "duplicate_checker": error(lambda: registry.register_checker(RejectingChecker())),
        "duplicate_world_checkers": error(
            lambda: World(QueueProfile(), budget(4, 2, 1, 5, 0, 1), checkers=(RejectingChecker(), RejectingChecker()))
        ),
    }


def foreign_profile() -> dict:
    # The Engine-independent half of test_registry_fails_closed_on_profile_or_checker_identity_mismatch:
    # a command or fault for another profile identity is refused.
    other = ProfileIdentity(name=QueueProfile.identity.name, version=2, digest=QueueProfile.identity.digest)
    world = World(QueueProfile(), budget(8, 2, 1, 5, 0, 1))
    try:
        generation = world.timeline().generation
        command = error(
            lambda: world.submit(Command(profile=other, name="queue.record", payload={"id": "x"}), generation=generation)
        )
        fault = error(
            lambda: world.activate_fault(
                Fault(profile=other, name="f", target="queue.apply", occurrence=1, disposition="refuse", payload=None),
                generation=generation,
            )
        )
        operations = len(world.operations)
    finally:
        world.close()
    return {"command": command, "fault": fault, "operations": operations}


def failure_after_end() -> dict:
    # Found by the Haskell port's generated-story property: a budget
    # refusal after the World already ended records a second failure
    # operation, and the World then refuses to produce its artifact.
    world = World(QueueProfile(), budget(8, 2, 0, 5, 0, 3))
    try:
        errors = [
            error(lambda: world.timeline().command("queue.record", {"id": "b"})),
            error(lambda: world.timeline().command("queue.record", {"id": "a"})),
        ]
        disposition = None if world.disposition is None else world.disposition.value
        operations = [dump(operation) for operation in world.operations]
        refused = error(lambda: world.artifact("failure-after-end"))
    finally:
        world.close()
    return {"errors": errors, "disposition": disposition, "operations": operations, "artifact_error": refused}


def nested(depth: int) -> object:
    value: object = 0
    for _ in range(depth):
        value = [value]
    return value


class DeepObservationProfile(QueueProfile):
    """A queue toy whose ``queue.deep`` observation nests a leaf in as many lists as asked."""

    def observe(self, generation, request: ObservationRequest, context: ScenarioContext):
        if request.name == "queue.deep":
            return nested(request.payload["depth"])
        return super().observe(generation, request, context)


def nesting() -> dict:
    # pydantic's recursion guard: 255 entries per validation, one per
    # JsonValue value. A command payload or observation value is refused
    # when its own model is built or, a few containers deeper, when the
    # World builds the journal entry that embeds it.
    world = World(DeepObservationProfile(), budget(16, 4, 1, 10, 0, 4))
    timeline = world.timeline()
    try:
        out = {
            "command_refused": error(lambda: timeline.command("queue.record", {"id": "a", "deep": nested(254)})),
            "command_journal_refused": error(
                lambda: timeline.command("queue.record", {"id": "b", "deep": nested(252)})
            ),
            "command_accepted": error(lambda: timeline.command("queue.record", {"id": "c", "deep": nested(251)})),
            "observation_refused": error(lambda: timeline.observe("queue.deep", {"depth": 255})),
            "observation_journal_refused": error(lambda: timeline.observe("queue.deep", {"depth": 253})),
            "observation_accepted": error(lambda: timeline.observe("queue.deep", {"depth": 252})),
            "request_refused": error(lambda: timeline.observe("queue.deep", {"depth": 0, "deep": nested(254)})),
        }
        world.step()
        world.step()
        timeline.finish(Disposition.QUIESCENT)
        out["operations"] = len(world.operations)
        out["journal"] = len(world.journal)
        try:
            artifact = world.artifact("nesting-v3")
        except Exception as caught:  # noqa: BLE001 - the class and message are the vector
            out["artifact"] = None
            out["artifact_error"] = {"type": type(caught).__name__, "message": str(caught)}
            return out
    finally:
        world.close()
    out["artifact"] = encode_artifact(artifact).decode()
    out["artifact_error"] = None
    out["replay"] = replayed(artifact, [DeepObservationProfile()])
    return out


STORIES = {
    "nesting": nesting,
    "stable-order": stable_order,
    "resource-v4": resource_v4,
    "resource-exhaustion-v4": resource_exhaustion_v4,
    "resource-keyset": resource_keyset,
    "constructor-checker-refusal": constructor_checker_refusal,
    "finish-pending": finish_pending,
    "fair-phase": fair_phase,
    "fault-validation": fault_validation,
    "action-timer-logical": action_timer_logical,
    "queue-reload-bytes": queue_reload_bytes,
    "authored-checker-failure": authored_checker_failure,
    "not-reclassified": not_reclassified,
    "no-choices": no_choices,
    "seeded-v3": seeded_v3,
    "seeded-v4": seeded_v4,
    "run-until-failed": run_until_failed,
    "poll-budget": poll_budget,
    "fault-story": fault_story,
    "refusals": refusals,
    "failure-after-end": failure_after_end,
    "foreign-profile": foreign_profile,
}


def main() -> int:
    out = {name: story() for name, story in STORIES.items()}
    Path(sys.argv[1]).write_text(json.dumps(out, indent=1, sort_keys=True, ensure_ascii=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
