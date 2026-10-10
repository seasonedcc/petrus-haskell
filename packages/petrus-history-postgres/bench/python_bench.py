"""Python counterparts of petrus-history-postgres's benchmarks (see bench/Main.hs).

Times the reference ``PostgresHistoryStore`` (psycopg 3, the pinned
upstream) on the same records and workloads, against a scratch database
created on the server named by PETRUS_TEST_POSTGRES and dropped afterwards.
Prints ``name,nanoseconds`` lines (scripts/bench_timing.py).

    cd upstream/petrus
    PETRUS_TEST_POSTGRES=... .venv/bin/python ../../packages/petrus-history-postgres/bench/python_bench.py
"""

from __future__ import annotations

import json
import os
import sys
import uuid

import psycopg
from psycopg.conninfo import make_conninfo

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

from petrus.impetus.history import ActivityCompleted, ActivityFailed, FiringCompleted, FiringFailed  # noqa: E402
from petrus.impetus.history.codec import encode_record  # noqa: E402
from petrus.impetus.history_store.postgres import PostgresHistoryStore, ensure_schema  # noqa: E402
from petrus.impetus.instance import Instance  # noqa: E402
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition  # noqa: E402

TERMINAL = (FiringCompleted, FiringFailed, ActivityCompleted, ActivityFailed)


def drained(tokens: int) -> list:
    net = Net(
        places=[Place(NetPath("queue")), Place(NetPath("taken"))],
        transitions=[Transition(NetPath("take"))],
        arcs=[Arc(NetPath("queue"), NetPath("take")), Arc(NetPath("take"), NetPath("taken"))],
    )
    marking = Marking({NetPath("queue"): tuple(Token("Item", {"seq": n}) for n in range(tokens))})
    instance = Instance(net, marking, instance_id="bench")
    instance.run()
    return list(instance.history.records)


def main() -> None:
    url = os.environ.get("PETRUS_TEST_POSTGRES")
    if not url:
        sys.exit("PETRUS_TEST_POSTGRES is unset: the petrus-history-postgres benchmarks need a server")
    name = f"petrus_bench_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    with psycopg.connect(url, autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    try:
        run(make_conninfo(url, dbname=name))
    finally:
        with psycopg.connect(url, autocommit=True) as admin:
            admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


def run(dsn: str) -> None:
    auto = psycopg.connect(dsn, autocommit=True)
    joined = psycopg.connect(dsn, autocommit=False)
    writer = psycopg.connect(dsn, autocommit=True)
    try:
        ensure_schema(auto)
        small = drained(200)
        large = drained(2000)
        appendable = [r for r in small if not isinstance(r, TERMINAL)]
        one, eight, ack = appendable[:1], appendable[:8], appendable[0]
        PostgresHistoryStore(writer, "load-1k").extend(small)
        PostgresHistoryStore(writer, "load-10k").extend(large)
        stale = PostgresHistoryStore(auto, "verify")
        encoded = encode_record(ack)
        writer.execute(
            "INSERT INTO impetus.semantic_events (event_id, net_instance_id, record_type, occurrence, payload)"
            " SELECT 'verify:' || n, 'verify', %s, %s, %s::jsonb FROM generate_series(0, 299999) AS n",
            (type(ack).__name__, encoded.get("occurrence"), json.dumps(encoded, allow_nan=False)),
        )
        auto_store = PostgresHistoryStore(auto, "append-auto")
        joined_store = PostgresHistoryStore(joined, "append-joined")
        joined.commit()

        def joined_commit(batch):
            joined_store.extend(batch)
            joined.commit()

        report("append.autocommit-1", lambda: auto_store.extend(one))
        report("append.autocommit-8", lambda: auto_store.extend(eight))
        report("append.joined-1-commit", lambda: joined_commit(one))
        report("append.joined-8-commit", lambda: joined_commit(eight))
        report("load.1k", lambda: len(PostgresHistoryStore(auto, "load-1k")))
        report("load.10k", lambda: len(PostgresHistoryStore(auto, "load-10k")))
        report("verify.conflict-acknowledge", lambda: stale.extend([ack]))
    finally:
        for connection in (auto, joined, writer):
            connection.close()


if __name__ == "__main__":
    main()
