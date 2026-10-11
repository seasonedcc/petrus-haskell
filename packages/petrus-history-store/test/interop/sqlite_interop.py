"""The reference's half of the SQLite History store interop suite.

Run from upstream/petrus with the pinned virtual environment (``python -I``).

Subcommands:
  write-every PATH INSTANCE    extend every_record_category() + [EXOTIC] through SqliteHistoryStore
  verify-every PATH INSTANCE   load; records equal that list and every stored payload is the
                               reference's spelling of its record; print the count
  dump PATH                    print sqlite_master, the schema rows, every event row (without
                               recorded_at) and the journal mode, as one JSON document
  open PATH INSTANCE           open; print "ok <len>" or "<ExceptionType>: <message>"
  append PATH INSTANCE JSON    open, extend with the records encoded in JSON (a list of
                               encode_record values), print "ok <len>" or the refusal
  race PATH INSTANCE           print "ready", wait for one stdin line, open and close the
                               store, print "done" or the failure
  begin PATH                   drive the activity net to an in-flight Activity (kill window 1)
  finish PATH                  resume, complete the in-flight occurrence; prepare must not re-run
  inspect PATH                 resume; assert the receipt marking; print the record count
  write-surrogates PATH INSTANCE   extend surrogate_records() (lone surrogates in token data,
                                   identity, result and error)
  verify-surrogates PATH INSTANCE  load; records equal surrogate_records() and every stored payload
                                   is the reference's spelling of its record; print the count
  begin-surrogate PATH         `begin`, delivering surrogate_payment() (a memo with lone surrogates)
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys

sys.path.insert(0, os.getcwd())

from petrus.impetus.history.codec import decode_record, encode_record  # noqa: E402
from petrus.impetus.history import (  # noqa: E402
    ActivityCompleted,
    ExternalEventDelivered,
    FiringFailed,
    TokensInitialized,
    TokensProduced,
)
from petrus.impetus.history_store import SqliteHistoryStore  # noqa: E402
from petrus.impetus.instance import Instance  # noqa: E402
from petrus.impetus.petrinet import Marking, NetPath, Token  # noqa: E402
from tests.petrus.impetus.history_store.test_history_backends import (  # noqa: E402
    INTAKE,
    OUT,
    Charge,
    activity_net,
    payment,
)
from tests.petrus.impetus.history_store.test_persistence import every_record_category  # noqa: E402

RECEIPT = Marking({OUT: (Token("Receipt", {"status": "captured"}),)})
INSTANCE = "interop-1"

# Lone surrogates: a str may hold one, json.dumps escapes it ("\ud800") and
# json.loads reads it back. The Haskell suite's `surrogateRecords` is the same
# list; its strings are WTF-8 Text there.
SURROGATE_DATA = ("\ud800", {"\udc00x": ["a\ud83d", 1, "\udfff\ud800"]})


def surrogate_records() -> list:
    tokens = tuple(Token("Payment", data) for data in SURROGATE_DATA)
    return [
        ExternalEventDelivered(INTAKE, tokens, identity="evt-\udfff", occurrence=1, instant=1),
        TokensProduced(NetPath("queue"), tokens, occurrence=1, instant=1),
        ActivityCompleted(NetPath("work"), {"note": "\udbff!", "\ud800": None}, occurrence=2, instant=3),
        FiringFailed(NetPath("work"), "boom \ud800", occurrence=2, instant=4),
    ]


def surrogate_payment() -> Token:
    return Token("Payment", {"amount": 100, "memo": "\ud800 \udc00"})

# The Haskell suite's `exotic` (SqliteSupport.hs): the payload spelling's edges.
EXOTIC = TokensInitialized(
    NetPath("p"),
    (
        Token(
            "text",
            {
                "s": "naïve ☃ \U0001f600 \"q\" \\ / \t\n\x00 \x7f",
                "f": 0.1,
                "big": 10**20,
                "neg": -0.0,
                "exp": 1e16,
                "tiny": 5e-324,
                "list": [1, 2.5, None, True, {}],
                "é": "key",
            },
        ),
    ),
    instant=0.5,
)


def records() -> list:
    return [*every_record_category(), EXOTIC]


def spelling(record) -> str:
    return json.dumps(encode_record(record), allow_nan=False, separators=(",", ":"))


def outcome(action) -> str:
    try:
        return f"ok {action()}"
    except Exception as error:  # noqa: BLE001 - the refusal is the answer
        return f"{type(error).__name__}: {error}"


def dump(path: str) -> dict:
    connection = sqlite3.connect(path)
    try:
        return {
            "master": [
                list(row)
                for row in connection.execute(
                    "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
                )
            ],
            "schema": [list(row) for row in connection.execute("SELECT * FROM impetus_history_schema")],
            "events": [
                list(row)
                for row in connection.execute(
                    "SELECT instance, position, event_id, record_type, occurrence, payload "
                    "FROM impetus_history_events ORDER BY instance, position"
                )
            ],
            "recorded_at": [
                row[0] is not None and len(row[0]) == 24 and row[0].endswith("Z")
                for row in connection.execute("SELECT recorded_at FROM impetus_history_events")
            ],
            "journal_mode": connection.execute("PRAGMA journal_mode").fetchone()[0],
        }
    finally:
        connection.close()


def main(command: str, *arguments: str) -> None:
    if command == "write-every":
        path, instance = arguments
        store = SqliteHistoryStore(path, instance)
        store.extend(records())
        store.close()
    elif command == "verify-every":
        path, instance = arguments
        store = SqliteHistoryStore(path, instance)
        assert store.records == tuple(records()), "records differ"
        connection = sqlite3.connect(path)
        stored = [
            row[0]
            for row in connection.execute(
                "SELECT payload FROM impetus_history_events WHERE instance = ? ORDER BY position", (instance,)
            )
        ]
        connection.close()
        assert stored == [spelling(record) for record in records()], "payloads differ"
        print(len(store))
        store.close()
    elif command == "write-surrogates":
        path, instance = arguments
        store = SqliteHistoryStore(path, instance)
        store.extend(surrogate_records())
        store.close()
    elif command == "verify-surrogates":
        path, instance = arguments
        store = SqliteHistoryStore(path, instance)
        assert store.records == tuple(surrogate_records()), "records differ"
        connection = sqlite3.connect(path)
        stored = [
            row[0]
            for row in connection.execute(
                "SELECT payload FROM impetus_history_events WHERE instance = ? ORDER BY position", (instance,)
            )
        ]
        connection.close()
        assert stored == [spelling(record) for record in surrogate_records()], "payloads differ"
        print(len(store))
        store.close()
    elif command == "dump":
        (path,) = arguments
        print(json.dumps(dump(path), sort_keys=True))
    elif command == "open":
        path, instance = arguments

        def opened() -> int:
            store = SqliteHistoryStore(path, instance)
            try:
                return len(store)
            finally:
                store.close()

        print(outcome(opened))
    elif command == "append":
        path, instance, encoded = arguments
        batch = [decode_record(value) for value in json.loads(encoded)]
        store = SqliteHistoryStore(path, instance)

        def appended() -> int:
            store.extend(batch)
            return len(store)

        print(outcome(appended))
        store.close()
    elif command == "race":
        path, instance = arguments
        print("ready", flush=True)
        sys.stdin.readline()
        print(outcome(lambda: SqliteHistoryStore(path, instance).close()), flush=True)
    elif command in ("begin", "begin-surrogate"):
        (path,) = arguments
        instance = Instance(
            activity_net(), handlers={"charge": Charge()}, history=SqliteHistoryStore(path, INSTANCE), instance_id=INSTANCE
        )
        delivered = payment() if command == "begin" else surrogate_payment()
        accepted = instance.accept_delivery(INTAKE, delivered, identity="evt_123", at=1)
        instance.complete_delivery(accepted, at=1)
        instance.begin(instance.candidates()[0], at=2)
    elif command == "finish":
        (path,) = arguments
        handler = Charge()
        resumed = Instance.resume(activity_net(), SqliteHistoryStore(path, INSTANCE), handlers={"charge": handler})
        [occurrence] = resumed.in_flight
        resumed.record_activity_completion(occurrence, {"status": "captured"}, at=3)
        resumed.complete(occurrence, at=4)
        assert handler.prepared == 0, "prepare re-ran"
        assert resumed.marking == RECEIPT, resumed.marking
    elif command == "inspect":
        (path,) = arguments
        resumed = Instance.resume(activity_net(), SqliteHistoryStore(path, INSTANCE), handlers={"charge": Charge()})
        assert resumed.marking == RECEIPT, resumed.marking
        assert resumed.watermark == 4, resumed.watermark
        assert str(resumed.instance_id) == INSTANCE, resumed.instance_id
        assert resumed.in_flight == (), resumed.in_flight
        print(len(resumed.history))
    else:
        raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(*sys.argv[1:])
