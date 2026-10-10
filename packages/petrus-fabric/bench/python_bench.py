"""Python counterparts of petrus-fabric's benchmarks (see bench/Main.hs).

Times the reference ``petrus.fabric`` values and ``petrus.fabric.postgres``
store (psycopg 3, the pinned upstream) on the same values and operations,
against a scratch database created on the server named by
PETRUS_TEST_POSTGRES and dropped afterwards. Prints ``name,nanoseconds``
lines (scripts/bench_timing.py).

    cd upstream/petrus
    PETRUS_TEST_POSTGRES=... .venv/bin/python -B ../../packages/petrus-fabric/bench/python_bench.py
"""

from __future__ import annotations

import itertools
import os
import sys
import uuid

import psycopg
from psycopg.conninfo import make_conninfo

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

from petrus.fabric import Envelope, ReplyRoute  # noqa: E402
from petrus.fabric.ingress import FabricInbox  # noqa: E402
from petrus.fabric.model import _canonical  # noqa: E402
from petrus.fabric.postgres import PostgresFabric, ensure_fabric_schema, issue_credential, register_process  # noqa: E402
from petrus.impetus.instance import FiringOutcome  # noqa: E402
from petrus.impetus.petrinet import NetPath  # noqa: E402

PAYLOAD = {
    "command": "go",
    "args": {"items": [1, 2, 3, 4, 5], "flag": True, "ratio": 0.5},
    "text": "hello world",
    "nested": {"a": {"b": {"c": [None, "x"]}}},
}
LARGE = {"rows": [{"id": i, "name": f"row-{i}", "tags": ["a", "b"], "score": i * 0.5} for i in range(250)]}
ROUTE = ReplyRoute("sender", "replies/finish")


def build(delivery_id: str, recipient: str, payload: dict) -> Envelope:
    return Envelope(delivery_id, "sender", recipient, "commands/start", "conversation-1", payload, ROUTE)


def main() -> None:
    url = os.environ.get("PETRUS_TEST_POSTGRES")
    if not url:
        sys.exit("PETRUS_TEST_POSTGRES is unset: the petrus-fabric store benchmarks need a server")
    name = f"petrus_bench_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    with psycopg.connect(url, autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    try:
        with psycopg.connect(make_conninfo(url, dbname=name), autocommit=True) as connection:
            run(connection)
    finally:
        with psycopg.connect(url, autocommit=True) as admin:
            admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


def run(connection) -> None:
    ensure_fabric_schema(connection)

    def register(name: str) -> PostgresFabric:
        credential = issue_credential()
        register_process(connection, name, credential)
        return PostgresFabric(connection, name, credential)

    sender, recipient, drainer = register("sender"), register("recipient"), register("drain-recipient")
    for r in (recipient, drainer):
        r.expose_source("commands/start")
        r.grant("sender", "commands/start")
    recipient.offer_service("commands/start", "worker", {"model": "large", "region": "eu"})
    item = build("delivery-1", "recipient", PAYLOAD)
    stored = build("stored", "recipient", PAYLOAD)
    sender.submit(stored)
    counter = itertools.count()

    def fresh(to: str) -> Envelope:
        return build(f"d-{next(counter)}", to, PAYLOAD)

    class Door:
        def deliver(self, source, tokens, *, identity):
            return FiringOutcome(NetPath(source), next(counter) + 1, (), (), ())

    inbox = FabricInbox(drainer, Door())

    def send_drain() -> int:
        sender.send(fresh("drain-recipient"))
        return len(inbox.drain(1))

    report("envelope.build", lambda: build("delivery-1", "recipient", PAYLOAD))
    report("envelope.digest", lambda: build("delivery-1", "recipient", PAYLOAD).digest)
    report("envelope.roundtrip", lambda: Envelope.from_data(item.to_data()))
    report("canonical.16KiB", lambda: len(_canonical(LARGE)))
    report("postgres.submit", lambda: sender.submit(fresh("recipient")).duplicate)
    report("postgres.submit-duplicate", lambda: sender.submit(stored).duplicate)
    report("postgres.send-drain", send_drain)
    report("postgres.discover", lambda: len(sender.discover("worker", {"model": "large"})))


if __name__ == "__main__":
    main()
