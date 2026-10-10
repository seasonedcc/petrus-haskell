"""Time the reference Local Dispatch on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-motus/bench/python_bench.py

Every workload runs over a fresh SQLite file (created, then deleted with its
WAL side files): ``open-fresh`` is schema initialization alone; each
``roundtrip`` dispatches n occurrences, claims and completes each with one
worker, and collects them all, under the database clock or a provider
clock. Every timing is the median of several runs after one warm-up, in
milliseconds, with a result size the Haskell side computes too.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import statistics
import sys
import tempfile
import time

from petrus.motus.activity import ActivityInvocation, ExecutionPolicy
import petrus.motus.dispatch.local as local
from petrus.motus.dispatch import LocalDispatch, LocalWorkerDispatch

ROUND_TRIPS = 50


class CountingClock:
    """A provider clock that advances one millisecond per reading."""

    def __init__(self) -> None:
        self.at = 1_000

    def now_ms(self) -> int:
        at = self.at
        self.at += 1
        return at


def work(value: int) -> ActivityInvocation:
    return ActivityInvocation(
        "work",
        input={"value": value},
        policy=ExecutionPolicy(attempts=2, heartbeat_timeout=30),
        correlation="correlation",
        idempotency="idempotency",
    )


def discard(path: str) -> None:
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)


def open_fresh(path: str) -> int:
    LocalDispatch(path, instance="bench")
    discard(path)
    return 0


def round_trip(path: str, n: int, *, provider: bool) -> int:
    collected = cycles(path, n, provider=provider)
    discard(path)
    return collected


def cycles(path: str, n: int, *, provider: bool) -> int:
    dispatch = LocalDispatch(path, instance="bench", clock=CountingClock() if provider else None)
    for occurrence in range(1, n + 1):
        dispatch.dispatch(occurrence, work(occurrence))
    worker = LocalWorkerDispatch(path, _claimant="bench-worker", _clock_reader=dispatch._clock)
    while (attempt := worker.claim()) is not None:
        worker.complete(attempt, {"ok": True})
    return len(dispatch.collect())


def held_round_trip(path: str, n: int) -> int:
    """round_trip while a co-resident connection holds the file open."""
    LocalDispatch(path, instance="bench")
    held = sqlite3.connect(path)
    try:
        held.execute("SELECT count(*) FROM impetus_local_dispatch_tasks").fetchone()
        collected = cycles(path, n, provider=False)
    finally:
        held.close()
    discard(path)
    return collected


class _Closing:
    """A connection whose ``with`` block also closes it.

    The reference's read-only ``with _connect(path) as connection:`` blocks
    (schema initialization among them) only commit on exit; the connection
    closes when the garbage collector reaches it, and until then it holds the
    WAL open, which spares every later per-operation connection the
    last-close checkpoint. This wrapper closes on exit, as the Haskell port
    does, so the ``*-closing`` rows time the same file IO.
    """

    def __init__(self, connection):
        self.connection = connection

    def __enter__(self):
        return self.connection.__enter__()

    def __exit__(self, *exc):
        try:
            return self.connection.__exit__(*exc)
        finally:
            self.connection.close()

    def __getattr__(self, name):
        return getattr(self.connection, name)


def closing_connections(action):
    def run() -> int:
        connect, raw_connect = local._connect, local._raw_connect
        local._connect = lambda path: _Closing(connect(path))
        local._raw_connect = lambda path: _Closing(raw_connect(path))
        try:
            return action()
        finally:
            local._connect, local._raw_connect = connect, raw_connect

    return run


def timed(name: str, action, repeats: int) -> None:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    print(f"{name:42} {statistics.median(samples) * 1000:12.3f} ms   (size {size}, n={repeats})")
    sys.stdout.flush()


def main() -> None:
    directory = tempfile.mkdtemp(prefix="petrus-motus-bench")
    path = os.path.join(directory, "dispatch.db")
    timed("local/open-fresh", lambda: open_fresh(path), 20)
    timed("local/roundtrip-1", lambda: round_trip(path, 1, provider=False), 20)
    timed("local/roundtrip-50-db-clock", lambda: round_trip(path, ROUND_TRIPS, provider=False), 10)
    timed("local/roundtrip-50-provider-clock", lambda: round_trip(path, ROUND_TRIPS, provider=True), 10)
    timed("local/roundtrip-50-held-open", lambda: held_round_trip(path, ROUND_TRIPS), 10)
    timed("local/open-fresh-closing", closing_connections(lambda: open_fresh(path)), 20)
    timed("local/roundtrip-1-closing", closing_connections(lambda: round_trip(path, 1, provider=False)), 20)
    timed(
        "local/roundtrip-50-db-clock-closing",
        closing_connections(lambda: round_trip(path, ROUND_TRIPS, provider=False)),
        10,
    )
    timed(
        "local/roundtrip-50-provider-clock-closing",
        closing_connections(lambda: round_trip(path, ROUND_TRIPS, provider=True)),
        10,
    )
    shutil.rmtree(directory)


if __name__ == "__main__":
    main()
