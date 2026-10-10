"""Time the reference territory custody on the workload of ``bench/Bench/Retention.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus/bench/python_retention.py

Each line prints the median per-operation time over several batches, after
one warm-up batch.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sqlite3
import statistics
import tempfile
import time
from pathlib import Path

from petrus.agenticus.attachment._retention import SqliteTerritoryCustody

ARCHIVE = b"x" * 4096
DIGEST = hashlib.sha256(ARCHIVE).hexdigest()


def row(i: int) -> tuple[object, ...]:
    return (
        f"custody-{i}", "host-one", 1, "retained", "episode-a", "attachment-a", 3, f"operation-{i}", "local",
        f"lease-{i}", '["command-cancellation","process-group","workspace"]', 1.0e12, ARCHIVE, DIGEST,
        None, None, None, None,
    )


def timed(label: str, operation, batches: int = 7) -> None:
    operation()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        operation()
        samples.append(time.perf_counter() - start)
    print(f"{label:24s} {statistics.median(samples) * 1e3:10.3f} ms")


def main() -> None:
    scratch = Path(tempfile.mkdtemp(prefix="retention-bench-"))
    try:
        directory = scratch / "custody"
        directory.mkdir(mode=0o700)
        os.chmod(directory, 0o700)
        path = directory / "territories.db"
        SqliteTerritoryCustody(path, clock=lambda: 10).close()
        with sqlite3.connect(path) as database:
            placeholders = ", ".join("?" * 18)
            database.executemany(f"INSERT INTO territory_custody VALUES ({placeholders})", [row(i) for i in range(1, 101)])
            stored = {r[0]: r for r in database.execute("SELECT * FROM territory_custody").fetchall()}
        rows = {i: stored[f"custody-{i}"] for i in range(1, 101)}
        custody = SqliteTerritoryCustody(path, clock=lambda: 10)

        def decode_many() -> None:
            decoded = [SqliteTerritoryCustody._decode(rows[i % 100 + 1]) for i in range(1, 1001)]  # noqa: SLF001
            assert len(decoded) == 1000

        ids = [f"custody-{i}" for i in range(1, 101)]

        def lookups() -> None:
            assert sum(1 for i in range(200) if custody.lookup(ids[i % 100]) is not None) == 200

        def recover() -> None:
            assert len(custody.recover()) == 100

        timed("decode-row-x1000", decode_many)
        timed("ledger-lookup-x200", lookups)
        timed("ledger-recover-100", recover)
        custody.close()
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
