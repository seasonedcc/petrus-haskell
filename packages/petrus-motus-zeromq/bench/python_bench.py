"""Time the reference ZeroMQ Dispatch transport on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-motus-zeromq/bench/python_bench.py

Each row runs this process's client against a server process over IPC. There are three
server set-ups:

- ``local``: ``python -m petrus.motus.transport.zeromq`` over a fresh Local SQLite
  Dispatch, as deployed;
- ``local-held-open``: the same, while this process holds a co-resident connection
  to the file (equal IO with the Haskell port; see RESULTS.md);
- ``memory``: the server over in-memory custody (the private ``_from_factory``
  door), which leaves only the transport. Worker ``empty`` never gets an Attempt;
  any other Worker always gets the same one.

The workloads are:

- ``claim-empty-100``: 100 sequential claims that find nothing (request latency);
- ``roundtrip-20``: dispatch 20, then claim, heartbeat and complete each through
  the server, then collect;
- ``custody-20``: 20 claim, heartbeat and complete cycles;
- ``async-claim-empty-100-c{1,8}``: 100 empty claims spread over 1 or 8 concurrent
  requesters that share one native asynchronous access (at most 8 sockets in
  flight).

Every timing is the median of several runs after one warm-up, in milliseconds,
printed to stderr with a result size that the Haskell side computes too. Stdout gets
``name,nanoseconds`` lines for ``scripts/bench``.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import threading
import time

from petrus.motus.activity import ActivityInvocation, ExecutionPolicy
from petrus.motus.dispatch import ActivityAttempt, LocalDispatch
from petrus.motus.transport.zeromq import (
    AsyncZeroMQWorkerAccess,
    ZeroMQDispatchServer,
    ZeroMQWorkerDispatch,
)


def work(value: int) -> ActivityInvocation:
    return ActivityInvocation(
        "work",
        input={"value": value},
        policy=ExecutionPolicy(attempts=2, heartbeat_timeout=30),
        correlation="correlation",
        idempotency="idempotency",
    )


def timed(name: str, action, repeats: int) -> None:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    median = statistics.median(samples)
    print(f"{name:42} {median * 1000:12.3f} ms   (size {size}, n={repeats})", file=sys.stderr, flush=True)
    print(f"{name},{median * 1e9:.0f}", flush=True)


def claim_empty(endpoint: str, n: int) -> int:
    client = ZeroMQWorkerDispatch(endpoint, worker_id="empty")
    try:
        for _ in range(n):
            client.claim()
    finally:
        client.close()
    return n


def custody(client: ZeroMQWorkerDispatch, attempt: ActivityAttempt) -> None:
    client.heartbeat(attempt, details={"progress": 1})
    client.complete(attempt, {"ok": True})


class RoundTrips:
    def __init__(self, dispatch: LocalDispatch, endpoint: str):
        self.dispatch, self.endpoint, self.offset = dispatch, endpoint, 0

    def __call__(self, n: int) -> int:
        for occurrence in range(self.offset + 1, self.offset + n + 1):
            self.dispatch.dispatch(occurrence, work(occurrence))
        self.offset += n
        client = ZeroMQWorkerDispatch(self.endpoint, worker_id="busy")
        try:
            while (attempt := client.claim()) is not None:
                custody(client, attempt)
        finally:
            client.close()
        return len(self.dispatch.collect())


def memory_custody(endpoint: str, n: int) -> int:
    client = ZeroMQWorkerDispatch(endpoint, worker_id="busy")
    try:
        for _ in range(n):
            if (attempt := client.claim()) is not None:
                custody(client, attempt)
    finally:
        client.close()
    return n


def async_claim_empty(endpoint: str, concurrency: int, n: int) -> int:
    async def run() -> None:
        access = await AsyncZeroMQWorkerAccess.create(endpoint, worker_id="empty", max_in_flight_operations=8)
        try:

            async def requester(slot: int, share: int) -> None:
                for _ in range(share):
                    await access.claim(slot)

            await asyncio.gather(
                *(
                    requester(slot, n // concurrency + (1 if slot <= n % concurrency else 0))
                    for slot in range(1, concurrency + 1)
                )
            )
        finally:
            await access.close()

    asyncio.run(run())
    return n


class MemoryCustody:
    """In-memory custody: worker ``empty`` never gets an Attempt; others always get one."""

    attempt = ActivityAttempt("a1", "1", "bench", "default", work(1))

    def __init__(self, worker_id: str):
        self.empty = worker_id == "empty"

    def claim(self):
        return None if self.empty else self.attempt

    def heartbeat(self, attempt, *, details=None):
        return details

    def complete(self, attempt, result):
        pass

    def fail(self, attempt, error):
        pass

    def wait(self, timeout):
        return False

    def close(self):
        pass


def memory_server(endpoint: str) -> None:
    server = ZeroMQDispatchServer._from_factory(endpoint, lambda queues, worker_id: MemoryCustody(worker_id))

    def announce() -> None:
        print(json.dumps({"ready": True, "endpoint": server.wait_ready()}), flush=True)

    threading.Thread(target=announce, daemon=True).start()
    server.serve_forever()


class Server:
    """A server process: start it, read its endpoint, terminate it on exit."""

    def __init__(self, command: list[str]):
        self.process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)

    def __enter__(self) -> str:
        assert self.process.stdout is not None
        return json.loads(self.process.stdout.readline())["endpoint"]

    def __exit__(self, *exc) -> None:
        self.process.terminate()
        self.process.wait(timeout=10)
        assert self.process.stdout is not None
        self.process.stdout.close()


def local_rows(base: str, label: str, *, held: bool) -> None:
    directory = f"{base}/{label}"
    os.mkdir(directory)
    path = f"{directory}/dispatch.db"
    dispatch = LocalDispatch(path, instance="bench")
    connection = sqlite3.connect(path) if held else None
    try:
        if connection is not None:
            connection.execute("SELECT count(*) FROM impetus_local_dispatch_tasks").fetchone()
        command = [
            sys.executable,
            "-m",
            "petrus.motus.transport.zeromq",
            "--path",
            path,
            "--bind",
            f"ipc://{directory}/dispatch.sock",
            "--drain-timeout",
            "0.1",
        ]
        with Server(command) as endpoint:
            round_trips = RoundTrips(dispatch, endpoint)
            timed(f"zeromq/{label}/claim-empty-100", lambda: claim_empty(endpoint, 100), 10)
            timed(f"zeromq/{label}/roundtrip-20", lambda: round_trips(20), 10)
    finally:
        if connection is not None:
            connection.close()


def main() -> None:
    if sys.argv[1:2] == ["--memory-server"]:
        memory_server(sys.argv[2])
        return
    base = tempfile.mkdtemp(prefix="pzb")
    try:
        local_rows(base, "local", held=False)
        local_rows(base, "local-held-open", held=True)
        with Server([sys.executable, os.path.abspath(__file__), "--memory-server", f"ipc://{base}/memory.sock"]) as endpoint:
            timed("zeromq/memory/claim-empty-100", lambda: claim_empty(endpoint, 100), 10)
            timed("zeromq/memory/custody-20", lambda: memory_custody(endpoint, 20), 10)
            for concurrency in (1, 8):
                timed(
                    f"zeromq/memory/async-claim-empty-100-c{concurrency}",
                    lambda c=concurrency: async_claim_empty(endpoint, c, 100),
                    10,
                )
    finally:
        shutil.rmtree(base)


if __name__ == "__main__":
    main()
