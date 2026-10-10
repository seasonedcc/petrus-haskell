"""The reference's half of the Absurd Engine interop suite.

Run from upstream/petrus with the pinned environment (psycopg and absurd-sdk
from the ``absurd`` extra). The first argument after the subcommand name is
the libpq connection string of the scratch database the Haskell suite also
uses. Every Engine here is ``petrus.engine.absurd`` over the topology net of
``tests.absurd_support`` (source ingress -> ``spark_work`` on the queue ->
human gate -> done), opened with ``poll_interval=0.1`` on the given queue.
Outputs are one JSON document; records cross in their history-codec
encoding (``encode_record``).

Subcommands:
  dispatch DSN INSTANCE QUEUE ISSUE_JSON ATTEMPTS HEARTBEAT
                       create, deliver the ingress issue, advance until
                       blocked, close: the authority dies after the begin
                       batch, spawn and doorbell committed as one; print the
                       outstanding occurrence and its idempotency key
  finish DSN INSTANCE QUEUE ISSUE_ID ATTEMPTS
                       load, drive until rest (30 s), deliver the approval,
                       drive until rest, close; print status, the done
                       token's data, and every record
  halt DSN INSTANCE QUEUE ATTEMPTS
                       load, drive until the Engine raises; print the
                       error's type and message and the durable records
  scope-dispatch DSN INSTANCE QUEUE ISSUE_JSON
                       create, open the scope "interop-lifecycle", deliver
                       the issue under it, advance until blocked, close;
                       print the outstanding occurrence and its task key
  scope-close DSN INSTANCE QUEUE
                       load, close the scope "interop-lifecycle", close;
                       print the cancelled occurrences and every record
  load-advance DSN INSTANCE QUEUE
                       load, advance once, close; print whether it waits and
                       the record types
  records DSN INSTANCE print every durable record of the instance
"""

from __future__ import annotations

import json
import os
import sys
import time

sys.path.insert(0, os.getcwd())

import psycopg  # noqa: E402

from petrus.engine.absurd import create_engine, load_engine  # noqa: E402
from petrus.impetus.history.codec import encode_record  # noqa: E402
from petrus.impetus.history_store.postgres import PostgresHistoryStore  # noqa: E402
from petrus.impetus.petrinet import Token  # noqa: E402
from tests.absurd_support import (  # noqa: E402
    APPROVAL,
    DONE,
    INGRESS,
    ISSUE,
    OPERATOR,
    topology_handlers,
    topology_net,
)

from petrus.motus.activity import ActivityDeclaration  # noqa: E402


def emit(value) -> None:
    print(json.dumps(value), flush=True)


def open_engine(dsn, instance, queue, *, load, attempts=1, heartbeat=30):
    door = load_engine if load else create_engine
    joined = psycopg.connect(dsn, autocommit=False)
    listener = psycopg.connect(dsn, autocommit=True)
    return door(
        joined,
        topology_net(),
        instance,
        listen=listener,
        handlers=topology_handlers(attempts),
        poll_interval=0.1,
        default_queue=queue,
        activities=[ActivityDeclaration("spark_work", heartbeat_timeout=heartbeat)],
    )


def advance_until_blocked(engine):
    while True:
        outcome = engine.advance()
        if not outcome.ready:
            return outcome


def drive_until_rest(engine, deadline_seconds=30.0):
    deadline = time.monotonic() + deadline_seconds
    while True:
        outcome = advance_until_blocked(engine)
        if not outcome.waiting:
            return
        if time.monotonic() >= deadline:
            raise SystemExit("timed out waiting on worker results")
        engine.wait(1.0)


def encoded(records):
    return [encode_record(record) for record in records]


def main(argv: list[str]) -> None:
    command, *rest = argv
    if command == "dispatch":
        dsn, instance, queue, issue, attempts, heartbeat = rest
        engine = open_engine(dsn, instance, queue, load=False, attempts=int(attempts), heartbeat=int(heartbeat))
        try:
            data = json.loads(issue)
            engine.deliver(INGRESS, Token(ISSUE, data), identity=f"ingress-{data['id']}")
            outcome = advance_until_blocked(engine)
            (outstanding,) = engine.in_flight
            emit(
                {
                    "waiting": outcome.waiting,
                    "occurrence": outstanding.id,
                    "key": f"{instance}:occurrence-{outstanding.id}",
                    "records": encoded(engine.records),
                }
            )
        finally:
            engine.close()
    elif command == "finish":
        dsn, instance, queue, issue_id, attempts = rest
        engine = open_engine(dsn, instance, queue, load=True, attempts=int(attempts))
        try:
            drive_until_rest(engine)
            engine.deliver(OPERATOR, Token(APPROVAL, {"id": issue_id}), identity=f"approval-{issue_id}")
            drive_until_rest(engine)
            emit(
                {
                    "status": engine.status.value,
                    "done": [token.data for token in engine.marking.place(DONE)],
                    "records": encoded(engine.records),
                }
            )
        finally:
            engine.close()
    elif command == "halt":
        dsn, instance, queue, attempts = rest
        engine = open_engine(dsn, instance, queue, load=True, attempts=int(attempts))
        try:
            try:
                drive_until_rest(engine)
            except Exception as error:  # noqa: BLE001 -- report the halt by type
                halted = {"error": type(error).__name__, "message": str(error)}
            else:
                halted = None
        finally:
            engine.close()
        with psycopg.connect(dsn, autocommit=True) as probe:
            records = PostgresHistoryStore(probe, instance).records
        emit({"halted": halted, "records": encoded(records)})
    elif command == "scope-dispatch":
        dsn, instance, queue, issue = rest
        engine = open_engine(dsn, instance, queue, load=False)
        try:
            data = json.loads(issue)
            scope = engine.open_scope("interop-lifecycle")
            engine.deliver(INGRESS, Token(ISSUE, data), identity=f"issue-{data['id']}", scope=scope)
            outcome = advance_until_blocked(engine)
            (outstanding,) = engine.in_flight
            emit(
                {
                    "waiting": outcome.waiting,
                    "occurrence": outstanding.id,
                    "key": f"{instance}:occurrence-{outstanding.id}",
                }
            )
        finally:
            engine.close()
    elif command == "scope-close":
        dsn, instance, queue = rest
        engine = open_engine(dsn, instance, queue, load=True)
        try:
            closure = engine.close_scope(engine.active_scopes["interop-lifecycle"])
            emit({"cancelled": list(closure.cancelled), "records": encoded(engine.records)})
        finally:
            engine.close()
    elif command == "load-advance":
        dsn, instance, queue = rest
        engine = open_engine(dsn, instance, queue, load=True)
        try:
            outcome = engine.advance()
            emit({"waiting": outcome.waiting, "records": encoded(engine.records)})
        finally:
            engine.close()
    elif command == "records":
        dsn, instance = rest
        with psycopg.connect(dsn, autocommit=True) as probe:
            emit(encoded(PostgresHistoryStore(probe, instance).records))
    else:
        raise SystemExit(f"unknown subcommand {command!r}")


if __name__ == "__main__":
    main(sys.argv[1:])
