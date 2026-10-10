"""The reference's half of the Worker topology interop suite (run from upstream/petrus).

The order scenario of ``engine_interop.py``, but with the charge going
through a durable Local SQLite Dispatch to a Worker instead of running
inline. The Engine and the Worker take turns (lock-step), so the History is
deterministic whichever implementation plays either part.

Subcommands:
  engine PATH DB   create the Engine over JSONL History PATH and Local Dispatch
                   DB, deliver the orders, and advance until blocked; while an
                   Activity is outstanding print "blocked" and wait for a
                   "drained" line on stdin, then advance again; print "rest"
                   once nothing is outstanding
  drain DB         run a Worker over Local Dispatch DB until nothing is claimable
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.getcwd())
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from engine_interop import IDENTITY, charge_card, create  # noqa: E402
from petrus.motus.dispatch.local import LocalDispatch, LocalWorkerDispatch  # noqa: E402
from petrus.motus.worker import Worker  # noqa: E402


def engine(path: str, db: str) -> None:
    session = create(path, LocalDispatch(db, instance=IDENTITY))
    while True:
        outcome = session.advance()
        while outcome.ready:
            outcome = session.advance()
        if not outcome.waiting:
            break
        print("blocked", flush=True)
        if sys.stdin.readline().strip() != "drained":
            raise SystemExit("expected 'drained'")
    session.close()
    print("rest", flush=True)


def drain(db: str) -> None:
    worker = Worker(LocalWorkerDispatch(db, worker_id="python-drain"), {"charge_card": charge_card})
    try:
        worker.run_available(limit=100)
    finally:
        worker.close()


def main() -> None:
    command, *arguments = sys.argv[1:]
    {"engine": engine, "drain": drain}[command](*arguments)


if __name__ == "__main__":
    main()
