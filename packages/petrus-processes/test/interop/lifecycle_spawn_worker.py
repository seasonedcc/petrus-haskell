"""The reference's process.spawn executor as a spawn worker.

Reads one JSON request per line on stdin:

    {"dsn", "parent", "parent_credential", "workspace_key" (hex), "invocation"}

runs the pinned reference's ``SpawnActivity`` over a ``PostgresSpawnRegistry``
and the lifecycle demo's ``DemoProvisioner`` (the §13.2 reference profile with
HMAC child credentials), and answers one line:

    {"ok": outcome, "ensure_calls": n}  or  {"error": message, "ensure_calls": n}

The Haskell cv5-lifecycle-demo uses it through --spawn-worker-command, so a
Haskell parent Engine's process.spawn is executed by the reference.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UPSTREAM = HERE.parents[3] / "upstream" / "petrus"
sys.path.insert(0, str(UPSTREAM / "src"))
sys.path.insert(0, str(UPSTREAM))

import psycopg  # noqa: E402

from petrus.motus.activity import ActivityInvocation  # noqa: E402
from petrus.processes.postgres import PostgresSpawnRegistry  # noqa: E402
from petrus.processes.spawn import SpawnActivity  # noqa: E402


def load_demo():
    spec = importlib.util.spec_from_file_location("cv5_lifecycle_demo", UPSTREAM / "scripts" / "cv5-lifecycle-demo.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["cv5_lifecycle_demo"] = module
    spec.loader.exec_module(module)
    return module


def main() -> None:
    demo = load_demo()
    for line in sys.stdin:
        if not line.strip():
            continue
        request = json.loads(line)
        provisioner = demo.DemoProvisioner(
            request["dsn"], request["parent"], request["parent_credential"], bytes.fromhex(request["workspace_key"])
        )
        raw = request["invocation"]
        invocation = ActivityInvocation(
            raw["activity"], input=raw["input"], correlation=raw.get("correlation"), idempotency=raw.get("idempotency")
        )
        try:
            with psycopg.connect(request["dsn"], autocommit=True) as connection:
                registry = PostgresSpawnRegistry(connection, request["parent"], request["parent_credential"])
                outcome = SpawnActivity(registry, provisioner)(invocation, context=None)
            answer = {"ok": outcome, "ensure_calls": provisioner.ensure_calls}
        except Exception as error:  # noqa: BLE001 - reported to the caller
            answer = {"error": f"{type(error).__name__}: {error}", "ensure_calls": provisioner.ensure_calls}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
