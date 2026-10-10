"""Python counterparts of petrus-engine-postgres's benchmarks (see bench/Main.hs).

Times the reference ``petrus.engine.postgres`` doors (psycopg 3, the pinned
upstream) on the same net and workloads, against a scratch database created
on the server named by PETRUS_TEST_POSTGRES and dropped afterwards. Prints
``name,nanoseconds`` lines (scripts/bench_timing.py).

    cd upstream/petrus
    PETRUS_TEST_POSTGRES=... .venv/bin/python ../../packages/petrus-engine-postgres/bench/python_bench.py
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

from petrus.engine.postgres import create_engine  # noqa: E402
from petrus.impetus.history_store.postgres import ensure_schema  # noqa: E402
from petrus.impetus.petrinet import Arc, Net, NetPath, Place, Token, Transition  # noqa: E402
from petrus.motus.dispatch import InlineDispatch  # noqa: E402

SOURCE, OUTPUT = NetPath("source"), NetPath("output")
ROTATION = 256


def provider_net() -> Net:
    return Net(places=[Place(OUTPUT)], transitions=[Transition(SOURCE)], arcs=[Arc(SOURCE, OUTPUT)])


def main() -> None:
    url = os.environ.get("PETRUS_TEST_POSTGRES")
    if not url:
        sys.exit("PETRUS_TEST_POSTGRES is unset: the petrus-engine-postgres benchmarks need a server")
    name = f"petrus_bench_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    with psycopg.connect(url, autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    try:
        run(make_conninfo(url, dbname=name))
    finally:
        with psycopg.connect(url, autocommit=True) as admin:
            admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


def run(dsn: str) -> None:
    with psycopg.connect(dsn, autocommit=True) as setup:
        ensure_schema(setup)
    counter = itertools.count()
    net = provider_net()

    def open_engine(prefix: str):
        return create_engine(
            psycopg.connect(dsn, autocommit=False), net, f"{prefix}{next(counter)}", dispatch=InlineDispatch({})
        )

    state = {"engine": open_engine("deliver-"), "delivered": 0}
    prior = open_engine("prior-")
    prior.deliver(SOURCE, Token.black(), identity="known")

    def deliver_one():
        state["delivered"] += 1
        if state["delivered"] % ROTATION == 0:
            state["engine"].close()
            state["engine"] = open_engine("deliver-")
        return state["engine"].deliver(SOURCE, Token.black(), identity=f"d{next(counter)}")

    def create_close():
        open_engine("create-").close()

    try:
        report("engine.deliver", deliver_one)
        report("engine.redeliver-prior", lambda: prior.deliver(SOURCE, Token.black(), identity="known"))
        report("engine.create-close", create_close)
    finally:
        state["engine"].close()
        prior.close()


if __name__ == "__main__":
    main()
