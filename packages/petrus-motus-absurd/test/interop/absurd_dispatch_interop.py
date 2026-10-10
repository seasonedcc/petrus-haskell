"""The reference's half of the Absurd Dispatch interop suite.

Run from upstream/petrus with the pinned environment (psycopg and absurd-sdk
from the ``absurd`` extra). The first argument after the subcommand name is
usually a libpq connection string to the scratch database the Haskell suite
also uses. Invocations cross as their task-payload wire (``encode_invocation``
JSON); outcomes print as {"occurrence": N, "result": V} or
{"occurrence": N, "failure": {error, kind, details, retryable, retry_after}}.

Subcommands:
  pin                                   print the triple pin and the vendored file's sha256
  ensure DSN                            ensure_absurd_schema; print the schema version
  dispatch DSN INSTANCE QUEUE OCC WIRE  AbsurdDispatch.dispatch in a joined transaction,
                                        commit; print the session's (queue, task)
  cancel DSN INSTANCE QUEUE OCC WIRE POS
                                        a fresh adapter cancels; commit; print the disposition
  collect DSN INSTANCE QUEUE OCC WIRE TIMEOUT
                                        a resumed authority: redispatch lookup-first,
                                        commit, wait_for_results(TIMEOUT) on a listen
                                        connection, collect; print the outcomes
  work DSN QUEUE MODE [DETAILS]         AbsurdWorkerDispatch claims one Attempt (10 s),
                                        heartbeats DETAILS when given, then MODE:
                                          complete:JSON | fail-classified:JSON |
                                          fail-exception:MESSAGE | none
                                        print the Attempt (and the terminal outcome)
  hold DSN QUEUE                        claim one Attempt, print it, then read stdin lines:
                                          heartbeat JSON | complete JSON | close
                                        printing {"ok": ...} or {"error": TYPE, "message": ...}
  key-instance KEY                      _instance_from_key(KEY) or the refusal
  decode WIRE                           decode_invocation(WIRE) re-encoded, or the refusal
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.getcwd())

import psycopg  # noqa: E402

import petrus.motus.dispatch.absurd as absurd  # noqa: E402
from petrus.motus.activity import ActivityFailure  # noqa: E402
from petrus.motus.dispatch import CancellationInstruction  # noqa: E402
from petrus.motus.dispatch.absurd import (  # noqa: E402
    AbsurdDispatch,
    AbsurdWorkerDispatch,
    decode_invocation,
    encode_invocation,
    ensure_absurd_schema,
)


def emit(value) -> None:
    print(json.dumps(value), flush=True)


def outcome(occurrence, value):
    if isinstance(value, ActivityFailure):
        return {
            "occurrence": occurrence,
            "failure": {
                "error": value.error,
                "kind": value.kind,
                "details": value.details,
                "retryable": value.retryable,
                "retry_after": value.retry_after,
            },
        }
    return {"occurrence": occurrence, "result": value}


def attempt_json(attempt):
    return {
        "attempt_id": attempt.attempt_id,
        "epoch": attempt.epoch,
        "claimant": attempt.claimant,
        "queue": attempt.queue,
        "invocation": encode_invocation(attempt.invocation),
        "latest_details": attempt.latest_details,
        "instance": attempt.instance,
    }


def claim_within(worker, seconds=10.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        attempt = worker.claim()
        if attempt is not None:
            return attempt
        worker.wait(0.1)
    raise SystemExit("nothing claimable")


def main(argv: list[str]) -> None:
    command, *rest = argv
    if command == "pin":
        vendored = (
            absurd.resources.files("petrus.motus.dispatch")
            .joinpath(f"absurd_schema/absurd-{absurd.ABSURD_VERSION}.sql")
            .read_bytes()
        )
        emit(
            {
                "version": absurd.ABSURD_VERSION,
                "commit": absurd.ABSURD_COMMIT,
                "sha256": absurd.ABSURD_SQL_SHA256,
                "vendored_sha256": hashlib.sha256(vendored).hexdigest(),
                "dispatch_channel": absurd.DISPATCH_CHANNEL,
                "results_channel": absurd.RESULTS_CHANNEL,
                "details_checkpoint": absurd.DETAILS_CHECKPOINT,
            }
        )
    elif command == "ensure":
        (dsn,) = rest
        with psycopg.connect(dsn, autocommit=True) as connection:
            ensure_absurd_schema(connection)
            emit({"version": connection.execute("SELECT absurd.get_schema_version()").fetchone()[0]})
    elif command == "dispatch":
        dsn, instance, queue, occurrence, wire = rest
        with psycopg.connect(dsn, autocommit=False) as connection:
            adapter = AbsurdDispatch(connection, instance=instance, default_queue=queue)
            adapter.dispatch(int(occurrence), decode_invocation(json.loads(wire)))
            connection.commit()
            emit(list(adapter._tasks[int(occurrence)]))
    elif command == "cancel":
        dsn, instance, queue, occurrence, wire, position = rest
        with psycopg.connect(dsn, autocommit=False) as connection:
            adapter = AbsurdDispatch(connection, instance=instance, default_queue=queue)
            instruction = CancellationInstruction(int(occurrence), decode_invocation(json.loads(wire)), int(position))
            disposition = adapter.cancel(instruction)
            connection.commit()
            emit(disposition.value)
    elif command == "collect":
        dsn, instance, queue, occurrence, wire, timeout = rest
        with (
            psycopg.connect(dsn, autocommit=False) as connection,
            psycopg.connect(dsn, autocommit=True) as listen,
        ):
            adapter = AbsurdDispatch(connection, instance=instance, listen=listen, poll_interval=0.1, default_queue=queue)
            adapter.dispatch(int(occurrence), decode_invocation(json.loads(wire)))
            connection.commit()
            ready = adapter.wait_for_results(float(timeout))
            collected = adapter.collect()
            connection.commit()
            emit(
                {
                    "ready": ready,
                    "task": list(adapter._tasks[int(occurrence)]),
                    "outcomes": [outcome(o, v) for o, v in collected],
                }
            )
    elif command == "work":
        dsn, queue, mode, *details = rest
        worker = AbsurdWorkerDispatch(dsn, queues=(queue,), worker_id="python-worker")
        try:
            attempt = claim_within(worker)
            report = {"attempt": attempt_json(attempt)}
            if details:
                report["heartbeat"] = worker.heartbeat(attempt, details=json.loads(details[0]))
            kind, _, argument = mode.partition(":")
            if kind == "complete":
                worker.complete(attempt, json.loads(argument))
            elif kind == "fail-classified":
                worker.fail(attempt, ActivityFailure(**json.loads(argument)))
            elif kind == "fail-exception":
                worker.fail(attempt, ValueError(argument))
            emit(report)
        finally:
            worker.close()
    elif command == "hold":
        dsn, queue = rest
        worker = AbsurdWorkerDispatch(dsn, queues=(queue,), worker_id="python-holder")
        try:
            attempt = claim_within(worker)
            emit(attempt_json(attempt))
            for line in sys.stdin:
                verb, _, argument = line.strip().partition(" ")
                if verb == "close":
                    break
                try:
                    if verb == "heartbeat":
                        emit({"ok": worker.heartbeat(attempt, details=json.loads(argument))})
                    elif verb == "complete":
                        worker.complete(attempt, json.loads(argument))
                        emit({"ok": True})
                except Exception as error:  # noqa: BLE001 -- report every refusal by type
                    emit({"error": type(error).__name__, "message": str(error)})
        finally:
            worker.close()
    elif command == "key-instance":
        (key,) = rest
        try:
            emit({"instance": absurd._instance_from_key(json.loads(key))})
        except ValueError as error:
            emit({"error": str(error)})
    elif command == "decode":
        (wire,) = rest
        try:
            emit({"wire": encode_invocation(decode_invocation(json.loads(wire)))})
        except ValueError as error:
            emit({"error": str(error)})
    else:
        raise SystemExit(f"unknown subcommand {command!r}")


if __name__ == "__main__":
    main(sys.argv[1:])
