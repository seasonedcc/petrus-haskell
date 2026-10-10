"""Python counterparts of petrus-processes' benchmarks (see bench/Main.hs).

Times the reference ``petrus.processes`` values and activity and the
``petrus.processes.postgres`` registry (psycopg 3, the pinned upstream) on the
same values and operations, against a scratch database created on the server
named by PETRUS_TEST_POSTGRES and dropped afterwards. Prints
``name,nanoseconds`` lines (scripts/bench_timing.py).

    cd upstream/petrus
    PETRUS_TEST_POSTGRES=... .venv/bin/python -B ../../packages/petrus-processes/bench/python_bench.py
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

from petrus.fabric import ReplyRoute  # noqa: E402
from petrus.fabric.postgres import ensure_fabric_schema, issue_credential, register_process  # noqa: E402
from petrus.motus.activity import ActivityInvocation  # noqa: E402
from petrus.processes import (  # noqa: E402
    CallRequest,
    CallResult,
    SpawnClaim,
    SpawnSpec,
    child_identity,
    reply_from_envelope,
    request_envelope,
    result_envelope,
)
from petrus.processes.postgres import PostgresSpawnRegistry, ensure_lifecycle_schema  # noqa: E402
from petrus.processes.spawn import SPAWN_ACTIVITY, SpawnActivity, spawn_idempotency  # noqa: E402

CAPABILITIES = {"tools": ["search", "fetch"], "tier": "standard"}
CONFIG = {"prompt": "summarise", "temperature": 0.25, "limits": {"tokens": 4096}}
ROUTE = ReplyRoute("parent", "replies")
ANSWER = CallResult("call-1", {"answer": 42})


def spec(spawn_id: str) -> SpawnSpec:
    return SpawnSpec("parent", spawn_id, "analysis-agent", "calls", CAPABILITIES, CONFIG, ROUTE)


def call_envelope(call_id: str):
    request = CallRequest(call_id, "answer", {"question": 42, "context": ["a", "b"]})
    return request_envelope(request=request, sender="parent", recipient="child", source="calls", reply_route=ROUTE)


def invocation(item: SpawnSpec) -> ActivityInvocation:
    return ActivityInvocation(SPAWN_ACTIVITY, input=item.to_data(), idempotency=spawn_idempotency(item.parent, item.spawn_id))


class MemoryRegistry:
    def claim(self, value: SpawnSpec) -> SpawnClaim:
        return SpawnClaim(value.parent, value.spawn_id, value.child, False)

    def child_of(self, parent, spawn_id):
        return None

    def children_of(self, parent):
        return ()

    def parent_of(self, child):
        return None


class NoProvisioning:
    def ensure(self, provisioning) -> None:
        return None


def main() -> None:
    url = os.environ.get("PETRUS_TEST_POSTGRES")
    if not url:
        sys.exit("PETRUS_TEST_POSTGRES is unset: the petrus-processes registry benchmarks need a server")
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
    ensure_lifecycle_schema(connection)
    credential = issue_credential()
    register_process(connection, "parent", credential)
    registry = PostgresSpawnRegistry(connection, "parent", credential)
    item = spec("spawn-1")
    request = call_envelope("call-1")
    result = result_envelope(result=ANSWER, request=request, sender="child")
    registry.claim(item)
    counter = itertools.count()

    def fresh() -> SpawnSpec:
        return spec(f"spawn-{next(counter)}-fresh")

    memory = SpawnActivity(MemoryRegistry(), NoProvisioning())
    over_postgres = SpawnActivity(registry, NoProvisioning())

    report("model.child-identity", lambda: child_identity("parent", "spawn-1"))
    report("model.spawn-spec-digest", lambda: spec("spawn-1").digest)
    report("model.spawn-spec-roundtrip", lambda: SpawnSpec.from_data(item.to_data()))
    report("call.request-envelope", lambda: call_envelope("call-1"))
    report("call.result-envelope", lambda: result_envelope(result=ANSWER, request=request, sender="child"))
    report("call.reply-from-envelope", lambda: reply_from_envelope(result, request=request))
    report("spawn.activity", lambda: memory(invocation(item), context=None))
    report("postgres.claim-prior", lambda: registry.claim(item).prior_claim)
    report("postgres.child-of", lambda: registry.child_of("parent", "spawn-1"))
    report("postgres.claim-new", lambda: registry.claim(fresh()).prior_claim)
    report("postgres.spawn-activity", lambda: over_postgres(invocation(fresh()), context=None))


if __name__ == "__main__":
    main()
