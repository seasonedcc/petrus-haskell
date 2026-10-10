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
from tests.dst.lifecycle_world import CancellationAuthorityChecker, LifecycleAuthorityChecker
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


def main() -> None:
    out = Path(sys.argv[1])
    vectors = []
    for name, checker, value in CASES:
        result = checker.check(value)
        vectors.append(
            {
                "checker": checker.identity.name,
                "name": name,
                "observation": value.model_dump(mode="json") if hasattr(value, "model_dump") else value.__dict__,
                "result": {"detail": result.detail, "passed": result.passed},
            }
        )
    out.write_text(json.dumps({"vectors": vectors}, indent=1, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
