"""Record the reference's Engine checker verdicts for the checker unit tests.

Each ``test_*_checker_*`` of the non-joined ``tests/dst/test_*_world.py``
files (and ``test_world.py``'s commit-authority test) builds one
Observation by hand and checks it with one Engine checker class. This
script runs the same observations through the same classes and records the
full verdict (``passed`` and ``detail``), so the Haskell checkers are
compared on every detail field, not only the asserted ones.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/engine_checker_vectors.py \
        ../../packages/petrus-dst/test/data/engine-checkers.json
"""

from __future__ import annotations

import json
import sys
import tempfile
from copy import deepcopy
from pathlib import Path

from petrus.testing.dst import Observation
from tests.dst.delayed_world import DelayedAuthorityChecker
from tests.dst.delivery_world import DeliveryAuthorityChecker
from tests.dst.engine_world import (
    AcceptedCommitAuthorityChecker,
    CommitAuthorityChecker,
    DispatchAuthorityChecker,
    EngineHistoryChecker,
    TerminalRefusalChecker,
)
from tests.dst.generated_runtime_world import (
    SCOPE_NAME,
    GeneratedRuntimeAuthorityChecker,
    execute_generated_runtime_story,
)
from tests.dst.lifecycle_world import CancellationAuthorityChecker, LifecycleAuthorityChecker
from tests.dst.retry_world import (
    RETRY_AVAILABLE_INSTANT,
    DelayedRetryAuthorityChecker,
    RetryAuthorityChecker,
    TerminalAuthorityChecker,
)
from tests.dst.timer_world import MATURATION_INSTANT, TimerAuthorityChecker



def observation(name, value, *, instant=0, generation=1, sequence=0):
    return Observation(name=name, value=value, instant=instant, generation=generation, sequence=sequence)


CANCELLATION_ATTEMPTS = [
    {
        "accepted": False,
        "activity": "calculate",
        "correlation": "occurrence-2",
        "disposition": None,
        "history_position": 9,
        "idempotency": "occurrence-2",
        "input": 3,
        "occurrence": 2,
        "policy": {},
    },
    {
        "accepted": True,
        "activity": "different",
        "correlation": "occurrence-2",
        "disposition": "tombstoned",
        "history_position": 9,
        "idempotency": "occurrence-2",
        "input": 3,
        "occurrence": 2,
        "policy": {},
    },
]

CASES = [
    (
        "test_world.test_commit_authority_checker_refuses_a_terminal_above_external_acceptance",
        CommitAuthorityChecker(),
        observation(
            "engine.commit-authority",
            {"record_types": ["ActivityCompleted", "FiringCompleted"], "terminal_deliveries": 1, "terminal_refusals": 1},
        ),
    ),
    (
        "test_history_ack_loss_world.test_accepted_commit_checker_refuses_missing_durable_terminal",
        AcceptedCommitAuthorityChecker(),
        observation(
            "engine.accepted-commit-authority",
            {"record_types": ["ActivityRequested"], "terminal_ack_losses": 1, "terminal_deliveries": 1},
        ),
    ),
    (
        "test_delivery_world.test_delivery_checker_refuses_duplicate_canonical_identity",
        DeliveryAuthorityChecker(),
        observation(
            "engine.delivery-authority",
            {
                "canonical_deliveries": [
                    {"identity": "event-3", "occurrence": 1, "value": 3},
                    {"identity": "event-3", "occurrence": 2, "value": 3},
                ],
                "delivery_attempts": [
                    {"disposition": "applied", "identity": "event-3", "value": 3},
                    {"disposition": "idempotent", "identity": "event-3", "value": 3},
                ],
                "firing_completed": 2,
                "marking_values": [3, 3],
            },
            generation=2,
        ),
    ),
    (
        "test_lifecycle_cancellation_world.test_cancellation_checker_refuses_a_changed_repair_instruction",
        CancellationAuthorityChecker(),
        observation(
            "engine.cancellation-authority",
            {
                "active_scopes": {"draft": 2},
                "authored_scope_generation": 2,
                "authored_scope_opens": 1,
                "authored_scope_resets": 1,
                "authored_source_deliveries": 1,
                "authored_terminal_deliveries": 0,
                "cancellation_attempts": CANCELLATION_ATTEMPTS,
                "record_types": ["ScopeOpened", "FiringCompleted", "ActivityRequested", "ScopeReset"],
            },
            generation=2,
        ),
    ),
    (
        "test_lifecycle_cancellation_world.test_cancellation_checker_keeps_reset_as_late_terminal_authority",
        CancellationAuthorityChecker(),
        observation(
            "engine.cancellation-authority",
            {
                "active_scopes": {"draft": 2},
                "authored_scope_generation": 2,
                "authored_scope_opens": 1,
                "authored_scope_resets": 1,
                "authored_source_deliveries": 1,
                "authored_terminal_deliveries": 1,
                "cancellation_attempts": [],
                "record_types": [
                    "ScopeOpened",
                    "FiringCompleted",
                    "ActivityRequested",
                    "ScopeReset",
                    "ActivityTerminalQuarantined",
                ],
            },
            generation=2,
        ),
    ),
    (
        "test_delayed_world.test_delayed_checker_refuses_terminal_before_authored_instant",
        DelayedAuthorityChecker(),
        observation(
            "engine.delayed-authority",
            {
                "record_types": ["ActivityRequested", "ActivityCompleted", "FiringCompleted"],
                "scheduled_terminal": {"instant": 5, "occurrence": 1, "result": {"value": 3}},
                "terminal_deliveries": 1,
            },
            instant=4,
            generation=2,
        ),
    ),
    (
        "test_timer_world.test_timer_checker_refuses_early_maturation",
        TimerAuthorityChecker(),
        observation(
            "engine.timer-authority",
            {
                "authored_maturation_instant": MATURATION_INSTANT,
                "current_instant": MATURATION_INSTANT - 1,
                "record_types": ["InstanceCreated", "TokensInitialized", "TimerMatured"],
                "timer_maturations": [{"instant": MATURATION_INSTANT - 1, "maturation_instant": MATURATION_INSTANT}],
            },
            instant=MATURATION_INSTANT - 1,
        ),
    ),
    (
        "test_dispatch_refusal_world.test_dispatch_checker_refuses_repreparation_or_changed_redispatch",
        DispatchAuthorityChecker(),
        observation(
            "engine.dispatch-authority",
            {
                "dispatch_attempts": [
                    {k: v for k, v in attempt.items() if k not in {"disposition", "history_position"}}
                    | {"correlation": "occurrence-1", "idempotency": "occurrence-1", "occurrence": 1}
                    for attempt in CANCELLATION_ATTEMPTS
                ],
                "prepare_calls": 2,
                "record_types": ["ActivityRequested", "ActivityCompleted", "FiringCompleted"],
            },
            generation=2,
        ),
    ),
    (
        "test_lifecycle_world.test_lifecycle_checker_refuses_projection_of_cancelled_work",
        LifecycleAuthorityChecker(),
        observation(
            "engine.lifecycle-authority",
            {
                "active_scopes": {"draft": 2},
                "authored_scope_generation": 2,
                "authored_scope_opens": 1,
                "authored_scope_resets": 1,
                "authored_source_deliveries": 1,
                "authored_terminal_deliveries": 1,
                "record_types": ["ScopeOpened", "FiringCompleted", "ScopeReset", "ActivityCompleted", "FiringCompleted"],
            },
            generation=2,
        ),
    ),
    (
        "extra.history-order-terminal-after-projection",
        EngineHistoryChecker(),
        observation("engine.safety", {"record_types": ["ActivityRequested", "FiringCompleted", "ActivityCompleted"]}),
    ),
    (
        "extra.history-order-passes",
        EngineHistoryChecker(),
        observation("engine.safety", {"record_types": ["ActivityRequested", "ActivityCompleted", "FiringCompleted"]}),
    ),
    (
        "extra.terminal-refusal",
        TerminalRefusalChecker(),
        observation("engine.safety", {"record_types": ["FiringCompleted"]}),
    ),
]


RETRY_ATTEMPT = {
    "activity": "work",
    "correlation": "occurrence-1",
    "idempotency": "occurrence-1",
    "input": 3,
    "instance": "dst-world-retry-recovery",
    "policy": {"initial_interval": RETRY_AVAILABLE_INSTANT},
    "queue": "default",
}

CASES += [
    (
        "test_retry_world.test_retry_checker_refuses_terminal_before_exhaustion",
        RetryAuthorityChecker(),
        observation(
            "engine.retry-authority",
            {
                "attempts": [
                    {
                        "activity": "work",
                        "correlation": "occurrence-1",
                        "epoch": 1,
                        "idempotency": "occurrence-1",
                        "input": 3,
                        "instance": "dst-world-retry-recovery",
                        "policy": {},
                        "queue": "default",
                    }
                ],
                "failures_delivered": 1,
                "record_types": ["InstanceCreated", "ActivityRequested", "ActivityFailed", "FiringFailed"],
            },
        ),
    ),
    (
        "test_retry_world.test_delayed_retry_checker_refuses_an_early_second_claim",
        DelayedRetryAuthorityChecker(),
        observation(
            "engine.delayed-retry-authority",
            {
                "attempts": [{**RETRY_ATTEMPT, "epoch": 1}, {**RETRY_ATTEMPT, "epoch": 2}],
                "claim_checks": [
                    {"available": True, "epoch": 1, "instant": 0},
                    {"available": True, "epoch": 2, "instant": RETRY_AVAILABLE_INSTANT - 1},
                ],
                "current_instant": RETRY_AVAILABLE_INSTANT - 1,
                "failures_delivered": 1,
                "record_types": ["InstanceCreated", "ActivityRequested"],
            },
            instant=RETRY_AVAILABLE_INSTANT - 1,
            generation=2,
        ),
    ),
    (
        "extra.delayed-retry-exact-prefix-passes",
        DelayedRetryAuthorityChecker(),
        observation(
            "engine.delayed-retry-authority",
            {
                "attempts": [{**RETRY_ATTEMPT, "epoch": 1}, {**RETRY_ATTEMPT, "epoch": 2}],
                "claim_checks": [
                    {"available": True, "epoch": 1, "instant": 0},
                    {"available": False, "epoch": None, "instant": RETRY_AVAILABLE_INSTANT - 1},
                    {"available": True, "epoch": 2, "instant": RETRY_AVAILABLE_INSTANT},
                ],
                "current_instant": RETRY_AVAILABLE_INSTANT,
                "failures_delivered": 2,
                "record_types": ["InstanceCreated", "ActivityRequested", "ActivityFailed", "FiringFailed"],
            },
            instant=RETRY_AVAILABLE_INSTANT,
            generation=2,
        ),
    ),
    (
        "test_local_terminal_world.test_local_terminal_checker_refuses_conflicting_projection",
        TerminalAuthorityChecker(),
        observation(
            "engine.local-terminal-authority",
            {
                "accepted_results": [{"value": 6}],
                "attempts": [{"epoch": 1}],
                "bridge": {"prepared": 0, "projected": 1},
                "marking": [{"place": "done", "tokens": [{"color": "Done", "data": {"value": 7}}]}],
                "record_types": ["InstanceCreated", "ActivityRequested", "ActivityCompleted", "FiringCompleted"],
                "status": "completed",
                "terminal_reports": [
                    {"disposition": "applied", "result": {"value": 6}},
                    {"disposition": "idempotent", "result": {"value": 6}},
                    {"disposition": "refused_expected", "result": {"value": 7}},
                ],
            },
            generation=2,
        ),
    ),
]


def generated_runtime_cases() -> list[tuple[str, object, Observation, list[Observation]]]:
    """test_generated_runtime_world.test_cross_layer_checker_rejects_independent_authority_divergence."""

    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        world, _ = execute_generated_runtime_story(
            directory / "runtime-checker.jsonl", directory / "runtime-checker.db", finish=False
        )
        try:
            base = world.timeline().observe("generated-runtime-state")
        finally:
            world.close()
    value = base.value
    mutations = {
        "replay_exact": lambda changed: changed.update(live_marking=[]),
        "in_flight_exact": lambda changed: changed.update(
            live_in_flight=[{"occurrence": 99, "phase": "activity_pending"}]
        ),
        "history_writer_valid": lambda changed: changed["record_occurrences"].append(
            {"kind": "Phantom", "occurrence": 99}
        ),
        "invocation_stable": lambda changed: changed["dispatch_attempts"][0].update(idempotency="changed-invocation"),
        "delivery_acknowledgements": lambda changed: changed["delivery_attempts"][1].update(disposition="applied"),
        "lifecycle_exact": lambda changed: changed.update(live_scopes={SCOPE_NAME: 99}),
        "projection_exact": lambda changed: changed["projection_attempts"].append(
            {"accepted": True, "record_types": ["FiringCompleted"]}
        ),
        "timer_exact": lambda changed: changed.update(timer_maturations=[]),
    }
    prefix = "test_generated_runtime_world.test_cross_layer_checker_rejects_independent_authority_divergence"
    cases = [(f"{prefix}.passes", GeneratedRuntimeAuthorityChecker(), base, [])]
    for property_name, mutate in mutations.items():
        changed = deepcopy(value)
        mutate(changed)
        cases.append(
            (
                f"{prefix}.{property_name}",
                GeneratedRuntimeAuthorityChecker(),
                base.model_copy(update={"value": changed}),
                [],
            )
        )
    changed = deepcopy(value)
    first_occurrence = changed["completed_occurrences"][0]
    attempts = changed["worker_attempts"]
    attempts.append(deepcopy(next(attempt for attempt in attempts if attempt["occurrence"] == first_occurrence)))
    cases.append(
        (
            f"{prefix}.frozen_execution",
            GeneratedRuntimeAuthorityChecker(),
            base.model_copy(update={"value": changed}),
            [base],
        )
    )
    return cases


def dump(value) -> object:
    return value.model_dump(mode="json") if hasattr(value, "model_dump") else value.__dict__


def main() -> None:
    out = Path(sys.argv[1])
    vectors = []
    for name, checker, value, prior in [(n, c, v, []) for n, c, v in CASES] + generated_runtime_cases():
        for earlier in prior:
            checker.check(earlier)
        result = checker.check(value)
        vector = {
            "checker": checker.identity.name,
            "name": name,
            "observation": dump(value),
            "result": {"detail": result.detail, "passed": result.passed},
        }
        if prior:
            vector["prior"] = [dump(earlier) for earlier in prior]
        vectors.append(vector)
    out.write_text(json.dumps({"vectors": vectors}, indent=1, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
