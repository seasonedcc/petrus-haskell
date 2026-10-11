"""The pinned ``petrus.motus.activity``: the oracle of ``Petrus.Activity.DifferentialSpec``.

Run by the test suite with the pinned interpreter (``scripts/upstream-python``)
from ``upstream/petrus``. It reads one case per stdin line, a JSON array
``[operation, arguments...]`` that petrus-json wrote, and writes one line
per case:

* ``{"ok":<value>}``: the value door accepted, and ``<value>`` is the
  object's wire form (``dataclasses.asdict``, members in field order) or the
  operation's result, as ``json.dumps(value, ensure_ascii=False,
  separators=(",", ":"))`` writes it;
* ``{"error":[exception class, message]}``: the door refused.

The operations are the module's public doors:

    retry        initial_interval, coefficient, max_interval, max_attempts, jitter
    delay        the same five, failed_attempt          -> RetryPolicy(...).delay(n)
    policy       the eight ExecutionPolicy fields
    invocation   activity, input, [eight policy fields], correlation, idempotency
    failure      error, kind, details, retryable, retry_after
    declaration  name, heartbeat_timeout
    heartbeat    value                                  -> snapshot_heartbeat_details
    payload      value                                  -> JsonPayloadConverter().decode
    call         name, [parameters], activity, input, has_result, result
                 -> an ActivityDefinition whose function returns ``result``, or
                    its keyword arguments as a dict, called with the invocation

Integers of any size travel in both directions (the transport lifts CPython's
4300-digit limit while it reads and writes), and the limit is back in force
while the door runs, as it is in the reference.
"""

from __future__ import annotations

import json
import sys
from dataclasses import asdict

from petrus.motus.activity import (
    ActivityDeclaration,
    ActivityDefinition,
    ActivityFailure,
    ActivityInvocation,
    ExecutionPolicy,
    JsonPayloadConverter,
    RetryPolicy,
    snapshot_heartbeat_details,
)

LIMIT = sys.get_int_max_str_digits()


def run(case: list) -> object:
    operation, *arguments = case
    if operation == "retry":
        return asdict(RetryPolicy(*arguments))
    if operation == "delay":
        *fields, attempt = arguments
        return RetryPolicy(*fields).delay(attempt)
    if operation == "policy":
        return asdict(ExecutionPolicy(*arguments))
    if operation == "invocation":
        activity, payload, policy, correlation, idempotency = arguments
        resolved = ExecutionPolicy(*policy)
        return asdict(
            ActivityInvocation(activity, input=payload, policy=resolved, correlation=correlation, idempotency=idempotency)
        )
    if operation == "failure":
        return asdict(ActivityFailure(*arguments))
    if operation == "declaration":
        return asdict(ActivityDeclaration(*arguments))
    if operation == "heartbeat":
        return snapshot_heartbeat_details(arguments[0])
    if operation == "payload":
        return JsonPayloadConverter().decode(arguments[0], object)
    if operation == "call":
        name, parameters, activity, payload, has_result, result = arguments
        declaration = ActivityDeclaration(name)
        invocation = ActivityInvocation(activity, input=payload)

        def function(**keywords: object) -> object:
            return result if has_result else dict(keywords)

        definition = ActivityDefinition(
            function, declaration, JsonPayloadConverter(), {parameter: object for parameter in parameters}, object
        )
        return definition(invocation, context=None)
    raise SystemExit(f"unknown operation {operation!r}")


def main() -> None:
    out = []
    for line in sys.stdin.read().split("\n"):
        if not line:
            continue
        sys.set_int_max_str_digits(0)
        case = json.loads(line)
        sys.set_int_max_str_digits(LIMIT)
        try:
            answer = {"ok": run(case)}
        except (ValueError, TypeError, OverflowError) as error:
            answer = {"error": [type(error).__name__, str(error)]}
        sys.set_int_max_str_digits(0)
        out.append(json.dumps(answer, ensure_ascii=False, separators=(",", ":")))
    sys.stdout.write("\n".join(out) + "\n")


main()
