"""Python counterparts of petrus-engine-absurd's benchmarks (see bench/Main.hs).

Times the reference ``petrus.engine.absurd.create_engine`` (psycopg 3, the
pinned upstream) on the reference's own topology net
(``tests/absurd_support.py``) with an in-process ``AbsurdWorkerDispatch``,
against a scratch database created on the server named by
PETRUS_TEST_POSTGRES and dropped afterwards. Prints ``name,nanoseconds``
lines (scripts/bench_timing.py).

    cd upstream/petrus
    PETRUS_TEST_POSTGRES=... .venv/bin/python ../../packages/petrus-engine-absurd/bench/python_bench.py

The rows' cost depends on how much Absurd state has accumulated (the claim
sweeps scan the queue's tables, and the catalog grows with every queue
rotation), so the batches are 0.5 s unless PETRUS_BENCH_BATCH_SECONDS says
otherwise: the 0.05 s default would sample only the first few hundred
Instances of a fresh database, where tasty-bench samples thousands.
"""

from __future__ import annotations

import itertools
import os
import sys
import uuid

import psycopg
from psycopg.conninfo import make_conninfo

os.environ.setdefault("PETRUS_BENCH_BATCH_SECONDS", "0.5")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

sys.path.insert(0, os.getcwd())  # upstream/petrus, for tests.absurd_support

from petrus.engine.absurd import create_engine  # noqa: E402
from petrus.impetus.history_store.postgres import ensure_schema  # noqa: E402
from petrus.impetus.instance import Status  # noqa: E402
from petrus.impetus.petrinet import Token  # noqa: E402
from petrus.motus.dispatch.absurd import AbsurdWorkerDispatch, ensure_absurd_schema  # noqa: E402
from tests.absurd_support import APPROVAL, CAPABILITY, INGRESS, ISSUE, OPERATOR, topology_handlers, topology_net  # noqa: E402

ROTATION = 256


def main() -> None:
    url = os.environ.get("PETRUS_TEST_POSTGRES")
    if not url:
        sys.exit("PETRUS_TEST_POSTGRES is unset: the petrus-engine-absurd benchmarks need a server")
    name = f"petrus_bench_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    with psycopg.connect(url, autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    try:
        run(make_conninfo(url, dbname=name))
    finally:
        with psycopg.connect(url, autocommit=True) as admin:
            admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


def advance_until_blocked(engine):
    """``advance_until_blocked`` of test_worker_topology.py."""
    while True:
        outcome = engine.advance()
        if not outcome.ready:
            return outcome


def drive_until_rest(engine) -> None:
    """``drive_until_rest`` of test_worker_topology.py (without its 30 s deadline)."""
    while True:
        outcome = advance_until_blocked(engine)
        if not outcome.waiting:
            return
        engine.wait(1.0)


class Lane:
    def __init__(self, dsn: str, admin, counter) -> None:
        self.admin = admin
        self.queue = f"bench_{next(counter)}"
        admin.execute("SELECT absurd.create_queue(%s)", (self.queue,))
        self.worker = AbsurdWorkerDispatch(dsn, queues=[self.queue])
        self.served = 0

    def close(self) -> None:
        self.worker.close()
        self.admin.execute("SELECT absurd.drop_queue(%s)", (self.queue,))


def run(dsn: str) -> None:
    admin = psycopg.connect(dsn, autocommit=True)
    ensure_schema(admin)
    ensure_absurd_schema(admin)
    counter = itertools.count()
    net = topology_net()

    def open_engine(queue: str, prefix: str):
        return create_engine(
            psycopg.connect(dsn, autocommit=False),
            net,
            f"{prefix}{next(counter)}",
            listen=psycopg.connect(dsn, autocommit=True),
            handlers=topology_handlers(),
            poll_interval=0.1,
            default_queue=queue,
        )

    state = {"lane": Lane(dsn, admin, counter)}

    def create_close() -> None:
        open_engine(CAPABILITY, "create-").close()

    def round_trip() -> None:
        lane = state["lane"]
        if lane.served >= ROTATION:
            lane.close()
            lane = state["lane"] = Lane(dsn, admin, counter)
        lane.served += 1
        engine = open_engine(lane.queue, "trip-")
        try:
            issue = f"goose-{next(counter)}"
            engine.deliver(INGRESS, Token(ISSUE, {"id": issue}), identity=f"ingress-{issue}")
            advance_until_blocked(engine)
            attempt = lane.worker.claim()
            if attempt is None:
                raise RuntimeError("the worker found no task")
            lane.worker.complete(attempt, f"sparked {issue}")
            drive_until_rest(engine)
            engine.deliver(OPERATOR, Token(APPROVAL, {"id": issue}), identity=f"approval-{issue}")
            drive_until_rest(engine)
            if engine.status is not Status.COMPLETED:
                raise RuntimeError(f"the Instance did not complete: {engine.status}")
        finally:
            engine.close()

    try:
        report("engine.create-close", create_close)
        report("roundtrip.issue-to-completion", round_trip)
    finally:
        state["lane"].close()
        admin.close()


if __name__ == "__main__":
    main()
