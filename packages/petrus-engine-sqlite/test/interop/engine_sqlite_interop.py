"""The reference's half of the SQLite Engine interop suite.

Run from upstream/petrus with the pinned virtual environment (``python -I``).
The order scenario is petrus-engine's (``engine_interop.py``), here driven
through ``petrus.engine.sqlite.create_engine`` / ``load_engine``.

Subcommands:
  run PATH                 create, deliver, advance to rest with InlineDispatch, close
  crash PATH               create, deliver, advance to rest with InMemoryDispatch: the
                           first charge stays in flight and the process exits (os._exit)
  resume PATH              load with InlineDispatch, advance to rest, close
  inspect PATH             load; print the marking as canonical JSON and the record count
  dump PATH                print the History rows (without recorded_at), the schema rows
                           and the History DDL as one JSON document
  hold PATH INSTANCE       create an Engine over an empty net, print "ready", wait for
                           one stdin line, close, print "released"
  try-load PATH INSTANCE   load over an empty net; print "opened" or "<Type>: <message>"
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys

sys.path.insert(0, os.getcwd())
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "petrus-engine", "test", "interop"))

from engine_interop import IDENTITY, INTAKE, advance_until_rest, charge_card, handlers, order_net  # noqa: E402

from petrus.engine.sqlite import create_engine, load_engine  # noqa: E402
from petrus.impetus.petrinet import Net, Token  # noqa: E402
from petrus.motus.dispatch import InlineDispatch, InMemoryDispatch  # noqa: E402


def empty_net() -> Net:
    return Net(places=[], transitions=[], arcs=[])


def create(path: str, dispatch):
    engine = create_engine(path, order_net(), IDENTITY, dispatch=dispatch, handlers=handlers())
    for n in (1, 2, 3):
        engine.deliver(INTAKE, Token("Order", {"id": f"o-{n}", "amount": n}), identity=f"evt_{n}")
    return engine


def dump(path: str) -> dict:
    connection = sqlite3.connect(path)
    try:
        return {
            "ddl": [
                list(row)
                for row in connection.execute(
                    "SELECT type, name, sql FROM sqlite_master WHERE name LIKE 'impetus_history%' ORDER BY type, name"
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
        }
    finally:
        connection.close()


def main(command: str, *arguments: str) -> None:
    if command == "run":
        (path,) = arguments
        engine = create(path, InlineDispatch({"charge_card": charge_card}))
        advance_until_rest(engine)
        engine.close()
    elif command == "crash":
        (path,) = arguments
        engine = create(path, InMemoryDispatch())
        advance_until_rest(engine)
        assert len(engine.in_flight) == 1, engine.in_flight
        os._exit(0)
    elif command == "resume":
        (path,) = arguments
        engine = load_engine(
            path, order_net(), IDENTITY, dispatch=InlineDispatch({"charge_card": charge_card}), handlers=handlers()
        )
        advance_until_rest(engine)
        engine.close()
    elif command == "inspect":
        (path,) = arguments
        engine = load_engine(path, order_net(), IDENTITY, dispatch=InMemoryDispatch(), handlers=handlers())
        marking = {str(place): [[token.color, token.data] for token in tokens] for place, tokens in engine.marking}
        print(json.dumps(marking, sort_keys=True))
        print(len(engine.records))
        engine.close()
    elif command == "dump":
        (path,) = arguments
        print(json.dumps(dump(path), sort_keys=True))
    elif command == "hold":
        path, instance = arguments
        engine = create_engine(path, empty_net(), instance, dispatch=InlineDispatch({}))
        print("ready", flush=True)
        sys.stdin.readline()
        engine.close()
        print("released", flush=True)
    elif command == "try-load":
        path, instance = arguments
        try:
            engine = load_engine(path, empty_net(), instance, dispatch=InlineDispatch({}))
        except Exception as error:  # noqa: BLE001 - the refusal is the answer
            print(f"{type(error).__name__}: {error}", flush=True)
        else:
            engine.close()
            print("opened", flush=True)
    else:
        raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(*sys.argv[1:])
