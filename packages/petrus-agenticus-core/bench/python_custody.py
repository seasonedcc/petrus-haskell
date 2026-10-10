"""Time the reference Connection custody on the workload of ``bench/Bench/Custody.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_custody.py [FULL|OFF] [N ...]

Benchmark id ``agenticus-custody``.  Workload: a fresh installation with 3
enrolled hosts and 10 authorized connections, then N materialize(read)/release
cycles, cycle ``i`` on connection ``i % 10`` and host ``i % 3``.  Prints the
median wall time of each operation kind and the total time of the N cycles,
with the reference pragmas (``synchronous = FULL``) and with
``synchronous = OFF``.
"""

from __future__ import annotations

import json
import shutil
import statistics
import sys
import tempfile
import time
from hashlib import sha256
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from petrus.agenticus.connection.custody import AgentConnectionCustody, ConnectionIdentity, LeaseMode, OpaqueState
from petrus.agenticus.connection.key import KeyContext, KeyErasureEvidence, KeyOperationError
from petrus.agenticus.connection.materialization import PrivateFileMaterializer
from petrus.agenticus.connection.storage import SqliteConnectionStorage


class BenchKeys:
    """AES-256-GCM with a counter nonce, as the reference's test keys."""

    def __init__(self) -> None:
        self._aead = AESGCM(sha256(b"agenticus-custody-bench-key").digest())
        self._counter = 0

    def seal(self, context: KeyContext, plaintext: bytearray) -> bytes:
        self._counter += 1
        nonce = self._counter.to_bytes(12, "big")
        return nonce + self._aead.encrypt(nonce, bytes(plaintext), context.authenticated_data())

    def open(self, context: KeyContext, ciphertext: bytes) -> bytearray:
        try:
            return bytearray(self._aead.decrypt(ciphertext[:12], ciphertext[12:], context.authenticated_data()))
        except Exception as error:
            raise KeyOperationError("encrypted connection state failed integrity verification") from error

    def erase(self, connection_id: str) -> KeyErasureEvidence:
        return KeyErasureEvidence(connection_id=connection_id, erased=True)


def provider_state(connection: str) -> bytes:
    return json.dumps(
        {"access_token": f"access-{connection}", "refresh_token": f"refresh-{connection}"}, separators=(",", ":")
    ).encode()


def session(label: str, synchronous_off: bool, n: int) -> None:
    scratch = Path(tempfile.mkdtemp(prefix="petrus-custody-bench"))
    try:
        root = scratch / "installation"
        storage = SqliteConnectionStorage(root / "connections.sqlite3")
        if synchronous_off:
            storage._database.execute("PRAGMA synchronous = OFF")
        materializer = PrivateFileMaterializer(root / "materialized")
        custody = AgentConnectionCustody(storage, BenchKeys(), materializer, clock=lambda: 1000.0)
        hosts = [f"host-{h}" for h in range(3)]
        connections = [f"connection-{c}" for c in range(10)]
        for host in hosts:
            custody.enroll_host(host, operation_id=f"enroll-{host}")
        for connection in connections:
            identity = ConnectionIdentity(
                connection, "fake-rotating-oauth", sha256(connection.encode()).hexdigest(), "subscription_oauth"
            )
            custody.authorize(identity, OpaqueState(provider_state(connection)), operation_id=f"authorize-{connection}")
        materializing = []
        releasing = []
        started = time.perf_counter()
        for i in range(n):
            start = time.perf_counter()
            materialization = custody.materialize(
                connections[i % 10], hosts[i % 3], mode=LeaseMode.READ, ttl=60, operation_id=f"materialize-{i}"
            )
            middle = time.perf_counter()
            custody.release(materialization, operation_id=f"release-{i}")
            end = time.perf_counter()
            materializing.append((middle - start) * 1e6)
            releasing.append((end - middle) * 1e6)
        finished = time.perf_counter()
        custody.close()
        print(
            f"custody sync={label:<4} N={n:<5} materialize p50 {statistics.median_low(materializing):10.1f} us   "
            f"release p50 {statistics.median_low(releasing):10.1f} us   total {finished - started:9.3f} s",
            flush=True,
        )
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main() -> None:
    arguments = sys.argv[1:]
    modes = [("FULL", False), ("OFF", True)]
    if arguments and arguments[0] in ("FULL", "OFF"):
        modes = [mode for mode in modes if mode[0] == arguments[0]]
        arguments = arguments[1:]
    sizes = [int(argument) for argument in arguments] or [100, 1000, 5000]
    for label, synchronous_off in modes:
        for n in sizes:
            session(label, synchronous_off, n)


if __name__ == "__main__":
    main()
