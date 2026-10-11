"""Drive the reference agent state stores, for on-disk interop.

Usage: ``python -I -B agents_reference.py COMMAND ARGS...``; every command
prints one JSON document on stdout.

* ``seal ROOT CONNECTION EPOCH VERSION HEX``: seal the plaintext with
  ``PersistentKeyOperations(ROOT)`` under ``KeyContext(CONNECTION, EPOCH,
  VERSION)``; prints ``{"sealed": hex}``.
* ``open ROOT CONNECTION EPOCH VERSION HEX``: open the ciphertext; prints
  ``{"opened": hex}`` or ``{"refused": class, "message": text}``.
* ``routes ROOT < steps.json``: open ``AgentRouteStore(ROOT /
  "agent-routes.sqlite3")``, activate the default composition over
  ``ROOT / "applications"``, run the steps (``{"claim": operation}`` or
  ``{"settle": [operations]}``), close; prints one report per step (the
  claimed route, or the refusal).
* ``dump ROOT``: the route database's schema text and sorted rows.
* ``terminal ROOT``: ``_terminal_operations(ROOT)``, the agent operations
  with a known terminal record in the Histories under ``ROOT``; prints
  ``{"operations": sorted}`` or the refusal.
* ``results - < cases.json``: for each ``{"request": asdict(ReviewRequest),
  "raw": text}``, ``_validate_result("review", _parse_result(raw),
  request)``; prints one report per case: ``{"accepted": true}``, the
  ``AgentProtocolError`` (``{"refused": reason, "category": ...}``) or any
  other exception (``{"raised": class, "message": str}``).

``InteropSpec`` runs the same operations through the Haskell port on the
same directories, in both directions.
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

from petrus.agenticus.connection.key import KeyContext

from hamsterdan.agents.pi import _parse_result
from hamsterdan.agents.protocol import AgentProtocolError, ReviewRequest, _validate_result
from hamsterdan.host.agenticus import AgentRouteStore, _terminal_operations, compose_agent
from hamsterdan.host.pi_a2 import PersistentKeyOperations


def context(arguments: list[str]) -> KeyContext:
    return KeyContext(arguments[0], int(arguments[1]), int(arguments[2]))


def routes(root: Path, steps: list[dict]) -> list[dict]:
    composition = compose_agent()
    store = AgentRouteStore(root / "agent-routes.sqlite3")
    reports: list[dict] = []
    try:
        store.activate(composition, root / "applications")
        for step in steps:
            try:
                if "claim" in step:
                    route = store.claim(step["claim"], composition)
                    reports.append(
                        {
                            "operation": route.operation,
                            "profile": route.profile,
                            "snapshot": route.snapshot.to_data(),
                            "resolved": route.resolved,
                        }
                    )
                else:
                    store.settle(step["settle"])
                    reports.append({"settled": step["settle"]})
            except Exception as error:  # noqa: BLE001 - reported for comparison
                reports.append({"refused": type(error).__name__, "message": str(error)})
    finally:
        store.close()
    return reports


def dump(root: Path) -> dict:
    with sqlite3.connect(f"file:{root / 'agent-routes.sqlite3'}?mode=ro", uri=True) as database:
        tables = {}
        for name, sql in database.execute(
            "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name"
        ):
            rows = []
            if sql.startswith("CREATE TABLE"):
                rows = sorted([list(row) for row in database.execute(f'SELECT * FROM "{name}"')], key=repr)
            tables[name] = {"sql": sql, "rows": rows}
        return {"user_version": database.execute("PRAGMA user_version").fetchone()[0], "tables": tables}


def results(cases: list[dict]) -> list[dict]:
    reports: list[dict] = []
    for case in cases:
        request = ReviewRequest(**case["request"])
        try:
            _validate_result("review", _parse_result(case["raw"]), request)
            reports.append({"accepted": True})
        except AgentProtocolError as error:
            category = error.result_category
            reports.append({"refused": str(error), "category": None if category is None else str(category)})
        except Exception as error:  # noqa: BLE001 - reported for comparison
            reports.append({"raised": type(error).__name__, "message": str(error)})
    return reports


def main() -> None:
    command, root, arguments = sys.argv[1], Path(sys.argv[2]), sys.argv[3:]
    if command == "seal":
        keys = PersistentKeyOperations(root)
        result: object = {"sealed": keys.seal(context(arguments), bytearray.fromhex(arguments[3])).hex()}
    elif command == "open":
        keys = PersistentKeyOperations(root)
        try:
            result = {"opened": keys.open(context(arguments), bytes.fromhex(arguments[3])).hex()}
        except Exception as error:  # noqa: BLE001 - reported for comparison
            result = {"refused": type(error).__name__, "message": str(error)}
    elif command == "routes":
        result = routes(root, json.load(sys.stdin))
    elif command == "results":
        result = results(json.load(sys.stdin))
    elif command == "dump":
        result = dump(root)
    elif command == "terminal":
        try:
            result = {"operations": sorted(_terminal_operations(root))}
        except Exception as error:  # noqa: BLE001 - reported for comparison
            result = {"refused": type(error).__name__, "message": str(error)}
    else:
        raise SystemExit(f"unknown command {command}")
    json.dump(result, sys.stdout, sort_keys=True)


if __name__ == "__main__":
    main()
