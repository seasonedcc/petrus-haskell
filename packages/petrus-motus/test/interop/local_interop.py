"""The reference's half of the Local Dispatch interop suite (run from upstream/petrus).

Every command works on a SQLite file that the Haskell suite also opens, so
each one exercises the shared schema, statements, and JSON encodings.

Subcommands:
  open PATH INSTANCE         open (create, migrate, or validate) the file
  publish PATH INSTANCE N    dispatch occurrences 1..N of work(value=i)
  work PATH CLAIMANT         claim and complete everything claimable in "default";
                             print the claimed attempts as JSON
  collect PATH INSTANCE N    a fresh session re-dispatches 1..N and collects;
                             print the outcomes as JSON
  scenario PATH              the deterministic provider-clock scenario; print
                             its telemetry events, dispositions and outcomes
  migrate PATH               open a v1 file under a fixed provider clock
  dump PATH                  print every Local Dispatch row and DDL text
  history-write PATH         append one record to a SqliteHistoryStore
  history-check PATH         print the SqliteHistoryStore records and table names
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys

sys.path.insert(0, os.getcwd())

import petrus.telemetry as telemetry  # noqa: E402
from petrus.impetus.history import TokensInitialized  # noqa: E402
from petrus.impetus.history_store import SqliteHistoryStore  # noqa: E402
from petrus.impetus.petrinet import NetPath, Token  # noqa: E402
from petrus.motus.activity import ActivityFailure, ActivityInvocation, ExecutionPolicy  # noqa: E402
from petrus.motus.dispatch import (  # noqa: E402
    CancellationInstruction,
    LocalDispatch,
    LocalWorkerDispatch,
)


class ManualClock:
    def __init__(self, at: int):
        self.at = at

    def now_ms(self) -> int:
        return self.at


def work(value: object, *, attempts: int = 2, **policy) -> ActivityInvocation:
    return ActivityInvocation(
        "work",
        input={"value": value},
        policy=ExecutionPolicy(attempts=attempts, heartbeat_timeout=30, **policy),
        correlation="correlation",
        idempotency="idempotency",
    )


def scenario_invocation(name: str, value: object, *, attempts: int, **policy) -> ActivityInvocation:
    return ActivityInvocation(
        name,
        input={"value": value, "label": "ünïcode ✓"},
        policy=ExecutionPolicy(attempts=attempts, heartbeat_timeout=30, **policy),
        correlation=f"corr-{name}",
        idempotency=None,
    )


def outcome_json(outcome: object) -> object:
    if isinstance(outcome, ActivityFailure):
        return {
            "failed": {
                "error": outcome.error,
                "kind": outcome.kind,
                "details": outcome.details,
                "retryable": outcome.retryable,
                "retry_after": outcome.retry_after,
            }
        }
    return {"completed": outcome}


def attempt_json(attempt) -> object:
    invocation = attempt.invocation
    return {
        "attempt_id": attempt.attempt_id,
        "epoch": attempt.epoch,
        "claimant": attempt.claimant,
        "queue": attempt.queue,
        "instance": attempt.instance,
        "latest_details": attempt.latest_details,
        "activity": invocation.activity,
        "input": invocation.input,
        "correlation": invocation.correlation,
        "idempotency": invocation.idempotency,
        "attempts": invocation.policy.attempts,
    }


def emit(value: object) -> None:
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def scenario(path: str) -> None:
    clock = ManualClock(1_000)
    dispatch = LocalDispatch(
        path, instance="interop", default_queue="general", activity_queues={"cpu_work": "cpu"}, clock=clock
    )
    w1 = LocalWorkerDispatch(path, queues=["general", "cpu"], _claimant="w1", _clock_reader=dispatch._clock)
    w2 = LocalWorkerDispatch(path, queues=["cpu", "general"], _claimant="w2", _clock_reader=dispatch._clock)
    one = scenario_invocation("work", 1, attempts=2, initial_interval=1)
    two = scenario_invocation("work", {"z": "café", "a": 1.5}, attempts=1)
    three = scenario_invocation("cpu_work", 3, attempts=3, start_to_close=0.25, schedule_to_close=10)
    four = scenario_invocation("work", 4, attempts=2)
    five = scenario_invocation("work", 5, attempts=1)
    six = scenario_invocation("work", 6, attempts=1, schedule_to_close=1)
    results: list[object] = []
    with telemetry.capture() as events:
        for occurrence, invocation in ((1, one), (2, two), (3, three), (4, four), (5, five)):
            dispatch.dispatch(occurrence, invocation)
        a1 = w1.claim()
        w1.fail(
            a1,
            ActivityFailure("later", kind="Unavailable", details={"b": 1, "a": 2}, retryable=True, retry_after=0.5),
        )
        a2 = w1.claim()
        results.append(w1.heartbeat(a2, details={"z": 1, "a": [1, 2]}))
        results.append(w1.heartbeat(a2))
        w1.complete(a2, {"ok": True, "note": "é", "n": 2.0})
        w1.complete(a2, {"ok": True, "note": "é", "n": 2.0})
        a3 = w1.claim()
        w1.fail(a3, "broken")
        results.append(dispatch.cancel(CancellationInstruction(4, four, 9)).value)
        dispatch.dispatch(4, four)
        a3b = w1.claim()
        results.append(attempt_json(a3b))
        clock.at = 1_300
        a3c = w2.claim()
        results.append(attempt_json(a3c))
        w2.complete(a3c, "third time")
        a5 = w2.claim()
        results.append(attempt_json(a5))
        clock.at = 40_000
        results.append(w2.wait(0))
        a1b = w1.claim()
        results.append(attempt_json(a1b))
        w1.complete(a1b, [1, "two", None])
        results.append([[occurrence, outcome_json(outcome)] for occurrence, outcome in dispatch.collect()])
        results.append(dispatch.cancel(CancellationInstruction(2, two, 10)).value)
        dispatch.dispatch(6, six)
        clock.at = 42_000
        results.append(w1.claim())
        results.append([[occurrence, outcome_json(outcome)] for occurrence, outcome in dispatch.collect()])
        results.append(dispatch.collect())
        # A refused heartbeat's ValueError, reported as the exception itself,
        # is stored as its repr and class name.
        dispatch.dispatch(7, scenario_invocation("work", 7, attempts=1))
        a7 = w1.claim()
        try:
            w1.heartbeat(a7, details={"x": float("nan")})
        except ValueError as error:
            w1.fail(a7, error)
        results.append([[occurrence, outcome_json(outcome)] for occurrence, outcome in dispatch.collect()])
    emit({"events": list(events), "results": results})


def migrate(path: str) -> None:
    LocalDispatch(path, instance="one", clock=ManualClock(5_000))


def dump(path: str) -> None:
    with sqlite3.connect(path) as connection:
        emit(
            {
                "master": connection.execute(
                    "SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name LIKE 'impetus_local_dispatch_%' ORDER BY name"
                ).fetchall(),
                "schema": connection.execute("SELECT * FROM impetus_local_dispatch_schema").fetchall(),
                "tasks": connection.execute("SELECT * FROM impetus_local_dispatch_tasks ORDER BY sequence").fetchall(),
                "terminals": connection.execute(
                    "SELECT * FROM impetus_local_dispatch_terminals ORDER BY sequence"
                ).fetchall(),
                "cancellations": connection.execute(
                    "SELECT * FROM impetus_local_dispatch_cancellations ORDER BY instance, occurrence"
                ).fetchall(),
                "journal_mode": connection.execute("PRAGMA journal_mode").fetchone()[0],
            }
        )


HISTORY_RECORD = TokensInitialized(NetPath("ready"), (Token.black(),), instant=0)


def main(command: str, arguments: list[str]) -> None:
    if command == "open":
        path, instance = arguments
        LocalDispatch(path, instance=instance)
    elif command == "publish":
        path, instance, count = arguments
        dispatch = LocalDispatch(path, instance=instance)
        for occurrence in range(1, int(count) + 1):
            dispatch.dispatch(occurrence, work(occurrence))
    elif command == "work":
        path, claimant = arguments
        custody = LocalWorkerDispatch(path, _claimant=claimant)
        claimed = []
        while (attempt := custody.claim()) is not None:
            claimed.append(attempt_json(attempt))
            custody.complete(attempt, {"by": claimant, "value": attempt.invocation.input["value"]})
        emit(claimed)
    elif command == "collect":
        path, instance, count = arguments
        dispatch = LocalDispatch(path, instance=instance)
        for occurrence in range(1, int(count) + 1):
            dispatch.dispatch(occurrence, work(occurrence))
        emit([[occurrence, outcome_json(outcome)] for occurrence, outcome in dispatch.collect()])
    elif command == "scenario":
        (path,) = arguments
        scenario(path)
    elif command == "migrate":
        (path,) = arguments
        migrate(path)
    elif command == "dump":
        (path,) = arguments
        dump(path)
    elif command == "history-write":
        (path,) = arguments
        SqliteHistoryStore(path, "one").append(HISTORY_RECORD)
    elif command == "history-check":
        (path,) = arguments
        records = SqliteHistoryStore(path, "one").records
        with sqlite3.connect(path) as connection:
            names = {row[0] for row in connection.execute("SELECT name FROM sqlite_master")}
        emit(
            {
                "records_match": records == (HISTORY_RECORD,),
                "names": sorted(names & {"impetus_history_events", "impetus_local_dispatch_tasks"}),
            }
        )
    else:
        raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
