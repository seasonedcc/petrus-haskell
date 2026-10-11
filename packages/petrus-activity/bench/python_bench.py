"""The pinned ``petrus.motus.activity`` value doors, the twins of bench/Main.hs.

Run by scripts/bench and scripts/bench-compare with the pinned interpreter
(``scripts/upstream-python``), from ``upstream/petrus``. Prints one
``name,nanoseconds`` line per benchmark, named like ``bench/Main.hs``'s.
Every row runs a door over 100 distinct inputs.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

from petrus.motus.activity import (  # noqa: E402
    ActivityFailure,
    ActivityInvocation,
    ExecutionPolicy,
    JsonPayloadConverter,
    RetryPolicy,
    activity,
    snapshot_heartbeat_details,
)

INDICES = range(100)


def policy_fields(k: int) -> dict:
    return dict(
        attempts=1 + k % 10,
        heartbeat_timeout=30 + k,
        initial_interval=0.5,
        coefficient=2,
        max_interval=60,
        jitter=0,
        start_to_close=10 + k,
        schedule_to_close=3600,
    )


def order(k: int) -> dict:
    return {
        "order": k,
        "customer": {"name": "João", "email": f"c{k}@example.com"},
        "items": [{"sku": f"SKU-{k * 7}", "quantity": 2, "price": 12.5}, {"sku": "SKU-2", "quantity": 1, "price": 3.25}],
        "total": 28.25,
        "coupon": None,
    }


def main() -> None:
    policies = [policy_fields(k) for k in INDICES]
    resolved = [ExecutionPolicy(**fields) for fields in policies]
    retry = RetryPolicy(0.5, 2, 60, 10, 0)
    orders = [order(k) for k in INDICES]
    details = [
        {"code": "insufficient_funds", "attempt": k, "amounts": [1.5, 2.25], "message": "cartão recusado — tente novamente"}
        for k in INDICES
    ]
    beats = [
        {"progress": k / 100, "processed": k * 10, "cursor": f"page-{k}", "log": [f"step {i} ok" for i in range(1, 11)]}
        for k in INDICES
    ]
    converter = JsonPayloadConverter()
    correlations = [f"c-{k}" for k in INDICES]

    @activity(name="charge")
    def charge(order: dict, amount: float, currency: str) -> dict:
        return {"charged": amount, "currency": currency, "receipt": "r-1"}

    calls = [ActivityInvocation("charge", input={"order": orders[k], "amount": 28.25, "currency": "BRL"}) for k in INDICES]

    report("policy.construct", lambda: [ExecutionPolicy(**fields) for fields in policies])
    report("policy.delay", lambda: [retry.delay(attempt) for attempt in range(1, 101)])
    report(
        "invocation.construct",
        lambda: [
            ActivityInvocation("charge_card", input=orders[k], policy=resolved[k], correlation=correlations[k]) for k in INDICES
        ],
    )
    report(
        "failure.construct",
        lambda: [ActivityFailure("card declined", "PaymentDeclined", details[k], True, 1.5) for k in INDICES],
    )
    report("heartbeat.snapshot", lambda: [snapshot_heartbeat_details(beat) for beat in beats])
    report("payload.convert", lambda: [converter.decode(value, object) for value in orders])
    report("definition.call", lambda: [charge(invocation, context=None) for invocation in calls])


main()
