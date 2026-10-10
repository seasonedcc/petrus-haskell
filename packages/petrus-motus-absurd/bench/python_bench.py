"""Python counterparts of petrus-motus-absurd's benchmarks (see bench/Main.hs).

Times the reference ``petrus.motus.dispatch.absurd`` (psycopg 3, the pinned
upstream) on the same invocations and doors, against a scratch database
created on the server named by PETRUS_TEST_POSTGRES and dropped afterwards.
Prints ``name,nanoseconds`` lines (scripts/bench_timing.py).

    cd upstream/petrus
    PETRUS_TEST_POSTGRES=... .venv/bin/python ../../packages/petrus-motus-absurd/bench/python_bench.py

The round trip's cost depends on how much Absurd state has accumulated (the
claim sweeps scan the queue's tables, and the catalog grows with every queue
rotation), so the batches are 0.5 s unless PETRUS_BENCH_BATCH_SECONDS says
otherwise: the 0.05 s default would sample only the first few hundred round
trips of a fresh database, where tasty-bench samples thousands.
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

from petrus.motus.activity import ActivityInvocation  # noqa: E402
from petrus.motus.dispatch.absurd import (  # noqa: E402
    AbsurdDispatch,
    AbsurdWorkerDispatch,
    decode_invocation,
    encode_invocation,
    ensure_absurd_schema,
)

ROTATION = 256


def invocation_for(n: int) -> ActivityInvocation:
    return ActivityInvocation(
        "bench_work",
        input={"n": n, "label": "a benchmark payload"},
        idempotency=f"effect-{n}",
    )


def main() -> None:
    url = os.environ.get("PETRUS_TEST_POSTGRES")
    if not url:
        sys.exit("PETRUS_TEST_POSTGRES is unset: the petrus-motus-absurd benchmarks need a server")
    name = f"petrus_bench_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    with psycopg.connect(url, autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    try:
        run(make_conninfo(url, dbname=name))
    finally:
        with psycopg.connect(url, autocommit=True) as admin:
            admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


class Lane:
    """A fresh queue, a join-mode authority with its adapter, and (round trip) a Worker; see bench/Main.hs."""

    def __init__(self, dsn: str, admin, counter, with_worker: bool) -> None:
        n = next(counter)
        self.admin = admin
        self.queue = f"bench_{n}"
        admin.execute("SELECT absurd.create_queue(%s)", (self.queue,))
        self.connection = psycopg.connect(dsn, autocommit=False)
        self.adapter = AbsurdDispatch(self.connection, instance=f"bench-{n}", default_queue=self.queue)
        self.worker = AbsurdWorkerDispatch(dsn, queues=[self.queue]) if with_worker else None
        self.dispatched = 0

    def close(self) -> None:
        if self.worker is not None:
            self.worker.close()
        self.connection.close()
        self.admin.execute("SELECT absurd.drop_queue(%s)", (self.queue,))


def run(dsn: str) -> None:
    admin = psycopg.connect(dsn, autocommit=True)
    ensure_absurd_schema(admin)
    counter = itertools.count()
    lanes = {False: Lane(dsn, admin, counter, False), True: Lane(dsn, admin, counter, True)}

    def dispatch_one(with_worker: bool) -> Lane:
        lane = lanes[with_worker]
        if lane.dispatched >= ROTATION:
            lane.close()
            lane = lanes[with_worker] = Lane(dsn, admin, counter, with_worker)
        lane.adapter.dispatch(lane.dispatched + 1, invocation_for(next(counter)))
        lane.connection.commit()
        lane.dispatched += 1
        return lane

    def round_trip() -> None:
        lane = dispatch_one(True)
        attempt = lane.worker.claim()
        if attempt is None:
            raise RuntimeError("the worker found no task")
        lane.worker.complete(attempt, f"done {attempt.invocation.activity}")
        while True:
            outcomes = lane.adapter.collect()
            lane.connection.commit()
            if outcomes:
                return

    try:
        report("wire.encode-decode", lambda: decode_invocation(encode_invocation(invocation_for(7))).idempotency)
        report("calibration.select-1", lambda: admin.execute("SELECT 1"))
        report("dispatch.spawn-commit", lambda: dispatch_one(False))
        report("roundtrip.dispatch-claim-complete-collect", round_trip)
    finally:
        for lane in lanes.values():
            lane.close()
        admin.close()


if __name__ == "__main__":
    main()
