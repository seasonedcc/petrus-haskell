"""Python counterparts of petrus-postgres's benchmarks (see bench/Main.hs).

Runs psycopg 3 the way upstream drives it (the History store's insert
statement, ``connection.transaction()``, the private
``PostgresAuthorityFence``, ``notifies(timeout=..., stop_after=1)``)
against the server named by PETRUS_TEST_POSTGRES, using session-local
temporary tables only. Prints ``name,nanoseconds`` lines
(scripts/bench_timing.py).
"""

import itertools
import os
import sys

import psycopg
from psycopg._queries import _query2pg_nocache

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

from petrus.engine._postgres import PostgresAuthorityFence  # noqa: E402

INSERT = (
    "INSERT INTO bench_events (event_id, net_instance_id, record_type, occurrence, payload)"
    " VALUES (%s, %s, %s, %s, %s::jsonb) ON CONFLICT DO NOTHING"
)
PAYLOAD = (
    '{"type": "FiringStarted", "occurrence": 7, "transition": "t", '
    '"instant": "2026-01-01T00:00:00+00:00", "tokens": [1, 2, 3]}'
)
# Calls per batch of the rows bench/Main.hs times with the twin's protocol
# (txCommits, txOwned, fenceCalls, notifyCalls): both sides make exactly the
# same calls and take the same statistic (bench_timing.py's median of
# batches).
TX_COMMITS = 3000
TX_OWNED = 600
FENCE_CALLS = 4000
NOTIFY_CALLS = 7000
CREATE = (
    "CREATE TEMPORARY TABLE bench_events (sequence bigserial PRIMARY KEY, event_id text UNIQUE NOT NULL, "
    "net_instance_id text NOT NULL, record_type text NOT NULL, occurrence bigint, payload jsonb NOT NULL)"
)


def main() -> None:
    url = os.environ.get("PETRUS_TEST_POSTGRES")
    if not url:
        sys.exit("PETRUS_TEST_POSTGRES is unset: the petrus-postgres benchmarks need a server")
    auto = psycopg.connect(url, autocommit=True)
    joined = psycopg.connect(url, autocommit=False)
    listener = psycopg.connect(url, autocommit=True)
    sender = psycopg.connect(url, autocommit=True)
    try:
        auto.execute(CREATE)
        joined.execute(CREATE)
        joined.commit()
        auto.execute("CREATE TEMPORARY TABLE bench_rows (n int PRIMARY KEY, label text, payload jsonb)")
        auto.execute(
            "INSERT INTO bench_rows SELECT n, 'label-' || n, jsonb_build_object('n', n, 'tags', "
            "jsonb_build_array('a', 'b'), 'ok', true) FROM generate_series(1, 1000) AS n"
        )
        listener.execute("LISTEN petrus_bench")
        counter = itertools.count()

        def event(connection, prefix):
            n = next(counter)
            return connection.execute(INSERT, (f"{prefix}{n}", "bench", "FiringStarted", 7, PAYLOAD)).rowcount

        def join_insert_commit():
            event(joined, "j")
            joined.commit()

        def owned_insert_10():
            with auto.transaction():
                for _ in range(10):
                    event(auto, "o")

        def notify_roundtrip():
            sender.execute("SELECT pg_notify(%s, %s)", ("petrus_bench", "q"))
            for n in listener.notifies(timeout=5, stop_after=1):
                return n.payload
            return None

        report("roundtrip.select-1", lambda: auto.execute("SELECT 1").fetchall())
        report("roundtrip.select-param", lambda: auto.execute("SELECT %s::int8 + 1", (41,)).fetchall())
        report(
            "query.select-1000-decoded",
            lambda: len(auto.execute("SELECT n, label, payload FROM bench_rows ORDER BY n").fetchall()),
        )
        report("tx.join-insert-commit", join_insert_commit, number=TX_COMMITS)
        report("tx.owned-insert-10", owned_insert_10, number=TX_OWNED)
        report(
            "fence.acquire-release",
            lambda: PostgresAuthorityFence(auto, "petrus-bench-fence").close(),
            number=FENCE_CALLS,
        )
        report("notify.roundtrip", notify_roundtrip, number=NOTIFY_CALLS)
        report("params.convert-placeholders", lambda: _query2pg_nocache(INSERT.encode(), "utf-8"))
    finally:
        for connection in (auto, joined, listener, sender):
            connection.close()


if __name__ == "__main__":
    main()
