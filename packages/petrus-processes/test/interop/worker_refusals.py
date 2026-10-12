"""The reference's half of the Worker refusal interop check.

A LocalDispatch publishes ``fabric.send`` and ``process.spawn`` invocations
that their Activities refuse; a Worker executes them over Local custody; the
LocalDispatch collects what custody recorded. The Haskell suite runs every
pairing it needs: this script's dispatcher with either Worker, and its own
dispatcher (over the invocations ``cases`` prints) with this script's
Worker, and compares the failures recorded.

Subcommands:
  cases              print every case as its invocation JSON
  publish PATH DSN   create the fabric schema and dispatch every case
  work PATH DSN      create the fabric schema and run the reference Worker
                     over every claimable case
  collect PATH       re-dispatch every case and print the collected outcomes
"""

from __future__ import annotations

import dataclasses
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UPSTREAM = HERE.parents[3] / "upstream" / "petrus"
sys.path.insert(0, str(UPSTREAM / "src"))

import psycopg  # noqa: E402

from petrus.fabric.model import Envelope  # noqa: E402
from petrus.fabric.postgres import PostgresFabric, ensure_fabric_schema  # noqa: E402
from petrus.motus.activity import ActivityFailure, ActivityInvocation, ExecutionPolicy  # noqa: E402
from petrus.motus.dispatch import LocalDispatch, LocalWorkerDispatch  # noqa: E402
from petrus.motus.worker import Worker  # noqa: E402
from petrus.processes.model import SpawnSpec  # noqa: E402
from petrus.processes.spawn import SpawnActivity  # noqa: E402

INSTANCE = "interop"
CLIENT = "mallory"
CREDENTIAL = "abcdefghijklmnopqrstuvwxyz0123456789"


class SendActivity:
    """The reference demos' SendActivity (scripts/cv5-fabric-demo.py)."""

    def __init__(self, connection, instance: str, credential: str):
        self.client = PostgresFabric(connection, instance, credential)

    def __call__(self, invocation: ActivityInvocation, *, context) -> dict[str, object]:
        envelope = Envelope.from_data(invocation.input)
        if invocation.idempotency != envelope.ingress_identity:
            raise ValueError(
                f"fabric.send invocation idempotency {invocation.idempotency!r} does not match "
                f"envelope identity {envelope.ingress_identity!r}"
            )
        submission = self.client.submit(envelope)
        return {
            "state": submission.state,
            "duplicate": submission.duplicate,
            "delivery_id": submission.delivery_id,
            "correlation": envelope.correlation,
        }


def envelope(sender: str, delivery_id: str) -> Envelope:
    return Envelope(delivery_id, sender, "bob", "inbox", f"corr-{delivery_id}", {"n": 1})


def invocation(activity: str, data: object, idempotency: str | None) -> ActivityInvocation:
    return ActivityInvocation(
        activity,
        input=data,
        policy=ExecutionPolicy(attempts=1),
        correlation="refusal",
        idempotency=idempotency,
    )


def cases() -> list[ActivityInvocation]:
    foreign = envelope("alice", "d-1")
    own = envelope(CLIENT, "d-2")
    malformed_payload = {**own.to_data(), "payload": [1]}
    spec = SpawnSpec(CLIENT, "spawn-1", "worker", "calls", {"protocol": "call-v1"}, {})
    return [
        # PermissionError: the envelope's sender is not the bound client.
        invocation("fabric.send", foreign.to_data(), foreign.ingress_identity),
        # PermissionError: the bound client is not registered.
        invocation("fabric.send", own.to_data(), own.ingress_identity),
        # ValueError: the idempotency is not the envelope's ingress identity.
        invocation("fabric.send", own.to_data(), "something-else"),
        # ValueError: not a version-1 envelope.
        invocation("fabric.send", {"version": 1}, None),
        # TypeError: the payload is not a JSON object.
        invocation("fabric.send", malformed_payload, own.ingress_identity),
        # ValueError: the idempotency does not identify the parent and spawn_id.
        invocation("process.spawn", spec.to_data(), "process.spawn:wrong"),
        # ValueError/TypeError: not a spawn spec.
        invocation("process.spawn", {"parent": CLIENT}, None),
    ]


def outcome_json(outcome: object) -> object:
    if isinstance(outcome, ActivityFailure):
        return {"failed": {"error": outcome.error, "kind": outcome.kind, "retryable": outcome.retryable}}
    return {"completed": outcome}


def main(command: str, arguments: list[str]) -> None:
    if command == "cases":
        print(json.dumps([dataclasses.asdict(call) for call in cases()]))
    elif command == "publish":
        path, dsn = arguments
        with psycopg.connect(dsn, autocommit=True) as connection:
            ensure_fabric_schema(connection)
        dispatch = LocalDispatch(path, instance=INSTANCE)
        for occurrence, call in enumerate(cases(), start=1):
            dispatch.dispatch(occurrence, call)
    elif command == "work":
        path, dsn = arguments
        with psycopg.connect(dsn, autocommit=True) as connection:
            ensure_fabric_schema(connection)
            activities = {
                "fabric.send": SendActivity(connection, CLIENT, CREDENTIAL),
                "process.spawn": SpawnActivity(None, None),
            }
            worker = Worker(LocalWorkerDispatch(path), activities, worker_id="python")
            worker.run_available(limit=len(cases()))
    elif command == "collect":
        (path,) = arguments
        dispatch = LocalDispatch(path, instance=INSTANCE)
        for occurrence, call in enumerate(cases(), start=1):
            dispatch.dispatch(occurrence, call)
        outcomes = sorted(dispatch.collect(), key=lambda pair: pair[0])
        print(json.dumps([[occurrence, outcome_json(outcome)] for occurrence, outcome in outcomes]))
    else:
        raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
