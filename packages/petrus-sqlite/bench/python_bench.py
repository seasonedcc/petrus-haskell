"""Python counterparts of petrus-sqlite's benchmarks (see bench/Main.hs).

Uses the upstream functions where they exist (Local Dispatch's ``_connect``,
the History store's ``_WriterFence``) and otherwise the statement sequence
upstream runs. Prints ``name,nanoseconds`` lines (scripts/bench_timing.py).
"""

import itertools
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

from petrus.impetus.history_store.sqlite import _DDL, _WriterFence  # noqa: E402
from petrus.motus.dispatch.local import _connect  # noqa: E402

INSERT = (
    "INSERT INTO impetus_history_events "
    "(instance, position, event_id, record_type, occurrence, payload) VALUES (?, ?, ?, ?, ?, ?) "
    "ON CONFLICT DO NOTHING"
)

# Calls per batch of the tx rows, as bench/Main.hs's txCommits and txBatches:
# both sides make exactly the same inserts (the table grows with every call)
# and take the same statistic (bench_timing.py's median of batches).
TX_COMMITS = 5000
TX_BATCHES = 500

PAYLOAD = '{"k":"value"},' * 20


def history_connection(path: str) -> sqlite3.Connection:
    # SqliteHistoryStore.__init__ / _configure
    connection = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    connection.execute("PRAGMA busy_timeout = 5000")
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA synchronous = FULL")
    mode = connection.execute("PRAGMA journal_mode = WAL").fetchone()[0]
    assert str(mode).lower() == "wal"
    return connection


def row(instance: str, position: int, payload: str):
    return (instance, position, f"{instance}:{position}", "FiringStarted", position + 1, payload)


def normalize(statement: str) -> str:
    return re.sub(r"\s+", " ", statement.strip()).lower()


def seeded(parent):
    """A scratch directory under PARENT holding a database with the History
    table and 1 000 seeded rows (bench/Main.hs's ``seeded``), and a connection
    to it."""
    directory = os.path.realpath(tempfile.mkdtemp(prefix="petrus-sqlite-bench", dir=parent))
    database = os.path.join(directory, "bench.sqlite3")
    connection = history_connection(database)
    connection.execute(_DDL[2])
    connection.execute("BEGIN IMMEDIATE")
    for position in range(1000):
        connection.execute(INSERT, row("seed", position, PAYLOAD))
    connection.commit()
    return directory, database, connection


def tx_rows(group: str, connection: sqlite3.Connection) -> None:
    """The two transaction rows of GROUP over CONNECTION (bench/Main.hs's
    ``txRows``)."""
    counter = itertools.count()

    def transaction(statements):
        connection.execute("BEGIN IMMEDIATE")
        try:
            statements()
            connection.commit()
        except BaseException:
            connection.rollback()
            raise

    def insert_one():
        position = next(counter)
        transaction(lambda: connection.execute(INSERT, row("single", position, PAYLOAD)).rowcount)

    def insert_batch():
        base = next(counter)

        def statements():
            for i in range(100):
                connection.execute(INSERT, row("batch", base * 100 + i, PAYLOAD))

        transaction(statements)

    report(f"{group}.immediate-insert-commit", insert_one, TX_COMMITS)
    report(f"{group}.immediate-insert-100", insert_batch, TX_BATCHES)


def main() -> None:
    directory, database, connection = seeded(None)
    # The tx rows again over a database on a memory-backed file system, when
    # PETRUS_BENCH_TMPFS names a directory on one (scripts/with-tmpfs), as
    # bench/Main.hs does.
    memory_parent = os.environ.get("PETRUS_BENCH_TMPFS")
    memory = seeded(memory_parent) if memory_parent else None
    try:

        def connect_close():
            _connect(Path(database)).close()

        def fence():
            _WriterFence(database, "bench").close()

        report("connect.local-dispatch-profile", connect_close)
        tx_rows("tx", connection)
        report(
            "query.select-by-key",
            lambda: len(
                connection.execute(
                    "SELECT payload FROM impetus_history_events WHERE instance = ? AND position = ?", ("seed", 500)
                ).fetchall()
            ),
        )
        report(
            "query.select-1000",
            lambda: len(
                connection.execute(
                    "SELECT position, event_id, record_type, occurrence, payload FROM impetus_history_events "
                    "WHERE instance = ? ORDER BY position",
                    ("seed",),
                ).fetchall()
            ),
        )
        report("schema.normalize-ddl", lambda: normalize(_DDL[2]))
        report("fence.acquire-release", fence)
        if memory:
            tx_rows("tx-tmpfs", memory[2])
    finally:
        connection.close()
        shutil.rmtree(directory)
        if memory:
            memory[2].close()
            shutil.rmtree(memory[0])


if __name__ == "__main__":
    main()
