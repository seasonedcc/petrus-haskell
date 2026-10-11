"""Author and replay the reference's readiness World artifacts, for byte comparison.

Usage:

    python -I -B world_reference.py author NAME ROOT
    python -I -B world_reference.py replay ROOT < artifact.json
    python -I -B world_reference.py coverage ROOT < artifact.json
    python -I -B world_reference.py names

``author`` drives one named scenario through the upstream ``ReadinessWorld``
(``hamsterdan.host.testing.readiness_world``) and prints the artifact's
``encode_artifact`` bytes. The scenarios are the Timeline call sequences of
``tests/integration/testing/test_readiness_world.py``,
``test_readiness_campaign.py`` (each campaign's ``@example`` cases) and
``test_readiness_coverage.py``, with their assertions left out; a scenario
that ends in a refusal keeps the artifact the World retained for it.

``replay`` replays an artifact (from stdin) through ``replay_readiness`` and
prints the replay result as canonical JSON (sorted keys, compact, ASCII).

``coverage`` replays an artifact the same way and prints
``encode_readiness_coverage`` of ``collect_readiness_coverage`` over that
one run (``hamsterdan.host.testing.readiness_coverage``).

``WorldInteropSpec`` authors the same scenarios through the Haskell World
and compares the bytes both ways: each language's artifact is identical,
and each replays in the other language with identical result bytes.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Callable
from pathlib import Path

from petrus.testing.dst import (
    BudgetExhausted,
    InvariantViolation,
    decode_artifact,
    encode_artifact,
)

from hamsterdan.host.testing.readiness_coverage import (
    CoverageRun,
    collect_readiness_coverage,
    encode_readiness_coverage,
)
from hamsterdan.host.testing.readiness_world import (
    BASE,
    DEFAULT_BUDGET,
    HEAD,
    READINESS_POLICY_DIGEST,
    REMINDER_DELAY,
    ReadinessTimeline,
    ReadinessWorld,
    replay_readiness,
)

MOVED = "c" * 40


def set_pr(timeline: ReadinessTimeline, head: str = HEAD, lifecycle: str = "active") -> None:
    timeline.set_pull_request(
        head=head,
        base=BASE,
        policy=READINESS_POLICY_DIGEST,
        lifecycle=lifecycle,
        strict_base=True,
        base_current=True,
        mergeable=True,
    )


def green(timeline: ReadinessTimeline, head: str) -> None:
    timeline.set_ci(head=head, required_checks=("build",), checks={"build": "success"})
    timeline.set_review(head=head, status="clear")


def clean_green(timeline: ReadinessTimeline, *, response_lost: bool) -> str:
    set_pr(timeline)
    green(timeline, HEAD)
    delivery = timeline.emit_webhook("pull_request", action="synchronize")
    if response_lost:
        timeline.lose_effect_response("readiness")
    timeline.deliver_webhook(delivery)
    return delivery


def drain(timeline: ReadinessTimeline) -> None:
    while timeline.pending():
        timeline.step()


Scenario = Callable[[ReadinessWorld], str]


def readiness_ambiguity(world: ReadinessWorld) -> str:
    timeline = world.timeline()
    clean_green(timeline, response_lost=True)
    timeline.run_until("accepted", lambda state: state["provider"]["response_losses"] == ["readiness"])
    timeline.crash("after_readiness_terminal_before_projection")
    world.restart().converge()
    return "hamsterdan-readiness-ambiguity-restart-v1"


def reminder_ambiguity(world: ReadinessWorld) -> str:
    timeline = world.timeline()
    clean_green(timeline, response_lost=False)
    drain(timeline)
    timeline.observe()
    timeline.lose_effect_response("reminder")
    timeline.advance_time(REMINDER_DELAY)
    timeline.run_until("accepted", lambda state: state["provider"]["response_losses"] == ["reminder"])
    timeline.crash("after_reminder_acceptance_before_projection")
    world.restart().converge()
    return "hamsterdan-readiness-reminder-ambiguity-restart-v1"


def git_ambiguity(world: ReadinessWorld) -> str:
    timeline = world.timeline()
    clean_green(timeline, response_lost=False)
    drain(timeline)
    comment = 501
    timeline.set_human_comment(comment=comment, fixture="change")
    delivery = timeline.emit_webhook("issue_comment", action="created")
    timeline.set_agent_terminal(
        operation=f"conversation:owner/repo:pr:7:delivery:{delivery}", fixture="conversation_change", status="changed"
    )
    publication = f"push:comment:{comment}:{HEAD}:i1"
    timeline.set_agent_terminal(operation=f"mutation:owner/repo:pr:7:{publication}", fixture="coding", status="changed")
    timeline.fault_git_publication(publication, "ref_cas")
    timeline.deliver_webhook(delivery)
    accepted = timeline.run_until("accepted", lambda state: len(state["provider"].get("git_publications", [])) == 1)
    new_head = accepted.value["provider"]["git_publications"][0]["result_head"]
    timeline.crash("after_git_ref_acceptance_before_recovery")
    timeline = world.restart()
    drain(timeline)
    green(timeline, new_head)
    timeline.deliver_webhook(timeline.emit_webhook("pull_request", action="synchronize"))
    drain(timeline)
    timeline.set_human_comment(comment=502, fixture=f"recover:{publication}")
    recovery = timeline.emit_webhook("issue_comment", action="created")
    timeline.set_agent_terminal(
        operation=f"conversation:owner/repo:pr:7:delivery:{recovery}", fixture="conversation_recover", status="clear"
    )
    timeline.deliver_webhook(recovery)
    timeline.converge()
    return "hamsterdan-v5-git-ambiguity-restart-v1"


def disposed_custody(world: ReadinessWorld) -> str:
    timeline = world.timeline()
    clean_green(timeline, response_lost=False)
    while world.world.pending():
        world.world.step()
    timeline.deliver_webhook(timeline.emit_webhook("issue_comment", action="created"))
    try:
        world.world.step()
    except InvariantViolation:
        pass
    return "disposed-custody-invariant-v3"


def resource_exhaustion(world: ReadinessWorld) -> str:
    try:
        set_pr(world.timeline(), MOVED)
    except BudgetExhausted:
        pass
    return "readiness-profile-resource-exhaustion-v4"


def dropped_generation_exhaustion(world: ReadinessWorld) -> str:
    try:
        world.timeline().crash("dropped-generation-resource-bound")
    except BudgetExhausted:
        pass
    return "readiness-dropped-generation-resource-exhaustion-v4"


def duplicate_delivery(world: ReadinessWorld) -> str:
    timeline = world.timeline()
    timeline.advance_time(7)
    delivery = clean_green(timeline, response_lost=False)
    while world.world.pending():
        world.world.step()
    timeline.deliver_webhook(delivery)
    timeline.converge()
    return "readiness-duplicate-delivery-v1"


def coverage_duplicate_delivery(world: ReadinessWorld) -> str:
    timeline = world.timeline()
    delivery = clean_green(timeline, response_lost=False)
    drain(timeline)
    timeline.deliver_webhook(delivery)
    timeline.converge()
    return "coverage-duplicate-delivery-v1"


def authority(path: str) -> Scenario:
    def run(world: ReadinessWorld) -> str:
        timeline = world.timeline()
        clean_green(timeline, response_lost=False)
        drain(timeline)
        timeline.observe()
        set_pr(timeline, MOVED, "draft" if path == "draft_resume" else path)
        green(timeline, MOVED)
        current = timeline.emit_webhook("pull_request", action="closed" if path == "closed" else "synchronize")
        timeline.deliver_webhook(current)
        drain(timeline)
        timeline.observe()
        if path == "draft_resume":
            set_pr(timeline, MOVED)
            timeline.deliver_webhook(timeline.emit_webhook("pull_request", action="ready_for_review"))
        timeline.converge()
        return f"readiness-authority-lifecycle-{path}-v2"

    return run


def timer(path: str, crash_cut: str, response_lost: bool, redeliver: bool) -> Scenario:
    def run(world: ReadinessWorld) -> str:
        timeline = world.timeline()
        initial = clean_green(timeline, response_lost=False)
        drain(timeline)
        if path == "new_head":
            set_pr(timeline, MOVED)
            green(timeline, MOVED)
            timeline.deliver_webhook(timeline.emit_webhook("pull_request", action="synchronize"))
            drain(timeline)
        elif path == "draft_resume":
            set_pr(timeline, HEAD, "draft")
            timeline.deliver_webhook(timeline.emit_webhook("pull_request", action="converted_to_draft"))
            drain(timeline)
            set_pr(timeline, HEAD)
            timeline.deliver_webhook(timeline.emit_webhook("pull_request", action="ready_for_review"))
            drain(timeline)
        elif path == "closed":
            set_pr(timeline, HEAD, "closed")
            timeline.deliver_webhook(timeline.emit_webhook("pull_request", action="closed"))
            drain(timeline)
        if redeliver:
            timeline.deliver_webhook(initial)
        if response_lost:
            timeline.lose_effect_response("reminder")
        if crash_cut == "before_due":
            timeline.crash("generated_timer_before_due")
            timeline = world.restart()
            drain(timeline)
        timeline.advance_time(REMINDER_DELAY)
        if crash_cut == "after_due":
            timeline.crash("generated_timer_after_due")
            timeline = world.restart()
        if path != "closed":
            timeline.run_until(
                "accepted", lambda state: state["provider"].get("accepted_by_kind", {}).get("reminder", 0) == 1
            )
            if crash_cut == "after_acceptance":
                timeline.crash("generated_timer_after_acceptance")
                timeline = world.restart()
        timeline.converge()
        return f"readiness-reminder-timer-{path}-v1"

    return run


def git(response_lost: bool, crash_cut: str, redeliver: bool) -> Scenario:
    def run(world: ReadinessWorld) -> str:
        timeline = world.timeline()
        clean_green(timeline, response_lost=False)
        drain(timeline)
        comment = 501
        timeline.set_human_comment(comment=comment, fixture="change")
        delivery = timeline.emit_webhook("issue_comment", action="created")
        publication = f"push:comment:{comment}:{HEAD}:i1"
        timeline.set_agent_terminal(
            operation=f"conversation:owner/repo:pr:7:delivery:{delivery}",
            fixture="conversation_change",
            status="changed",
        )
        timeline.set_agent_terminal(
            operation=f"mutation:owner/repo:pr:7:{publication}", fixture="coding", status="changed"
        )
        if response_lost:
            timeline.fault_git_publication(publication, "ref_cas")
        if crash_cut == "before_delivery":
            timeline.crash("generated_git_before_delivery")
            timeline = world.restart()
            drain(timeline)
        timeline.deliver_webhook(delivery)
        accepted = timeline.run_until(
            "accepted", lambda state: len(state["provider"].get("git_publications", [])) == 1
        )
        new_head = accepted.value["provider"]["git_publications"][0]["result_head"]
        if crash_cut == "after_acceptance":
            timeline.crash("generated_git_after_acceptance")
            timeline = world.restart()
        drain(timeline)
        green(timeline, new_head)
        timeline.deliver_webhook(timeline.emit_webhook("pull_request", action="synchronize"))
        drain(timeline)
        if redeliver:
            timeline.deliver_webhook(delivery)
        if crash_cut == "after_head":
            timeline.crash("generated_git_after_head")
            timeline = world.restart()
            drain(timeline)
        if response_lost:
            timeline.set_human_comment(comment=502, fixture=f"recover:{publication}")
            recovery = timeline.emit_webhook("issue_comment", action="created")
            timeline.set_agent_terminal(
                operation=f"conversation:owner/repo:pr:7:delivery:{recovery}",
                fixture="conversation_recover",
                status="clear",
            )
            timeline.deliver_webhook(recovery)
        timeline.converge()
        return f"readiness-v5-git-publication-{crash_cut}-v1"

    return run


def git_unrecovered_after_acceptance(world: ReadinessWorld) -> str:
    # A crash right after the Git ref is accepted, with no response fault:
    # upstream's World refuses this schedule (the independent model fails
    # the boundary after the moved head's CI is set). The campaign's five
    # Hypothesis examples never draw it.
    try:
        git(False, "after_acceptance", False)(world)
    except InvariantViolation:
        pass
    return "readiness-v5-git-publication-after_acceptance-v1"


def limited(name: str, value: int):
    limits = dict(DEFAULT_BUDGET.profile_resources)
    limits[name] = value
    return DEFAULT_BUDGET.model_copy(update={"profile_resources": limits})


# name -> (scenario, seed, budget)
SCENARIOS: dict[str, tuple[Scenario, int | None, object]] = {
    "readiness-ambiguity": (readiness_ambiguity, None, DEFAULT_BUDGET),
    "reminder-ambiguity": (reminder_ambiguity, None, DEFAULT_BUDGET),
    "git-ambiguity": (git_ambiguity, None, DEFAULT_BUDGET),
    "disposed-custody": (disposed_custody, None, DEFAULT_BUDGET),
    "resource-exhaustion": (resource_exhaustion, None, limited("retained.provider.authorities", 1)),
    "dropped-generation-exhaustion": (
        dropped_generation_exhaustion,
        None,
        limited("retained.profile.dropped_generations", 0),
    ),
    "duplicate-delivery": (duplicate_delivery, None, DEFAULT_BUDGET),
    "coverage-duplicate-delivery": (coverage_duplicate_delivery, None, DEFAULT_BUDGET),
    "authority-active": (authority("active"), 0, DEFAULT_BUDGET),
    "authority-draft_resume": (authority("draft_resume"), 0, DEFAULT_BUDGET),
    "authority-closed": (authority("closed"), 0, DEFAULT_BUDGET),
    "timer-stable": (timer("stable", "before_due", False, False), 0, DEFAULT_BUDGET),
    "timer-new_head": (timer("new_head", "after_due", False, True), 1, DEFAULT_BUDGET),
    "timer-draft_resume": (timer("draft_resume", "after_acceptance", True, True), 2, DEFAULT_BUDGET),
    "timer-closed": (timer("closed", "after_due", False, True), 3, DEFAULT_BUDGET),
    "git-before_delivery": (git(False, "before_delivery", False), 0, DEFAULT_BUDGET),
    "git-after_acceptance": (git(True, "after_acceptance", True), 1, DEFAULT_BUDGET),
    "git-after_head": (git(True, "after_head", False), 2, DEFAULT_BUDGET),
    "git-none": (git(False, "none", True), 3, DEFAULT_BUDGET),
    "git-after_acceptance-unrecovered": (git_unrecovered_after_acceptance, 0, DEFAULT_BUDGET),
}


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()


def main(argv: list[str]) -> int:
    # The host's Worker logs one line per processed Activity on stdout;
    # only the artifact or replay result goes there.
    out = sys.stdout.buffer
    sys.stdout = sys.stderr
    if argv[:1] == ["names"]:
        out.write(("\n".join(SCENARIOS) + "\n").encode())
        return 0
    if len(argv) == 3 and argv[0] == "author":
        scenario, seed, budget = SCENARIOS[argv[1]]
        world = ReadinessWorld(Path(argv[2]).resolve() / "live", budget=budget, seed=seed)
        try:
            scenario_id = scenario(world)
            artifact = world.artifact(scenario_id)
        finally:
            world.close()
        out.write(encode_artifact(artifact))
        return 0
    if len(argv) == 2 and argv[0] == "replay":
        artifact = decode_artifact(sys.stdin.buffer.read())
        result = replay_readiness(artifact, Path(argv[1]).resolve())
        out.write(canonical(result.model_dump(mode="json")))
        return 0
    if len(argv) == 2 and argv[0] == "coverage":
        artifact = decode_artifact(sys.stdin.buffer.read())
        result = replay_readiness(artifact, Path(argv[1]).resolve())
        out.write(encode_readiness_coverage(collect_readiness_coverage((CoverageRun(artifact, result),))))
        return 0
    sys.stderr.write(__doc__ or "")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
