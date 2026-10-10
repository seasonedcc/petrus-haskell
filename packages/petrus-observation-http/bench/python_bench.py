"""Python counterparts of petrus-observation-http's benchmarks (bench/Main.hs).

Serves the "busy" Engine (the upstream test's Net with its move looping back
to ``a``, advanced 100 times) with ``create_observation_server`` and times
one round trip per call on a fresh loopback connection with a Python socket
client that closes with a reset (SO_LINGER 0), as the Haskell rows do.
Prints ``name,nanoseconds`` lines (scripts/bench_timing.py).
"""

import os
import socket
import struct
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test"))
from bench_timing import report  # noqa: E402
from reference_observation import make_busy_engine  # noqa: E402

from petrus.engine.observation_http import create_observation_server  # noqa: E402

LINGER_RESET = struct.pack("ii", 1, 0)


def get(target: str) -> bytes:
    return (
        f"GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost:5173\r\nAccept: application/json\r\n\r\n"
    ).encode()


SNAPSHOT = get("/v1/snapshot")
DOCUMENT = get("/v1/document")
HISTORY = get("/v1/history?after=0&limit=100")
REFUSED = b"POST /v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"


def roundtrip(port: int, request: bytes) -> bytes:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, LINGER_RESET)
        client.connect(("127.0.0.1", port))
        client.sendall(request)
        client.shutdown(socket.SHUT_WR)
        chunks = []
        while chunk := client.recv(65536):
            chunks.append(chunk)
    return b"".join(chunks)


def main() -> None:
    engine = make_busy_engine()
    server = create_observation_server(engine, "127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    port = server.server_port
    try:
        report("roundtrip.snapshot", lambda: roundtrip(port, SNAPSHOT))
        report("roundtrip.document", lambda: roundtrip(port, DOCUMENT))
        report("roundtrip.history-100", lambda: roundtrip(port, HISTORY))
        report("roundtrip.refused-405", lambda: roundtrip(port, REFUSED))
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        engine.close()


if __name__ == "__main__":
    main()
