"""Python counterparts of petrus-simulation's benchmarks (bench/Main.hs).

``simulate.*`` time ``petrus.simulation.simulate`` on the same scenarios;
``http.*`` time one round trip per call to ``create_simulation_server`` over
the owner fixture build, on a fresh loopback connection with a Python socket
client that closes with a reset (SO_LINGER 0), as the Haskell rows do.
Prints ``name,nanoseconds`` lines (scripts/bench_timing.py).
"""

import json
import os
import socket
import struct
import sys
import threading
import warnings

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
sys.path.insert(0, ".")  # run from upstream/petrus: its ``tests`` package
from bench_timing import report  # noqa: E402
from tests.simulation_support import build_scenario  # noqa: E402

from petrus.impetus.dsl import BuiltNet  # noqa: E402
from petrus.impetus.observation import marking as project_marking  # noqa: E402
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition  # noqa: E402
from petrus.simulation import SimulationProfileError, simulate, simulation_profile  # noqa: E402
from petrus.simulation_http import create_simulation_server  # noqa: E402

ORIGIN = "http://localhost:5173"
LINGER_RESET = struct.pack("ii", 1, 0)
A, B, T = NetPath("a"), NetPath("b"), NetPath("t")


def run(built, marking, max_actions) -> int:
    try:
        return len(simulate(built, marking, max_actions=max_actions))
    except SimulationProfileError:
        return 0


def black(count: int) -> Marking:
    return Marking({A: (Token.black(),) * count})


def post(body: bytes) -> bytes:
    return (
        f"POST /v1/simulations HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: {ORIGIN}\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n"
    ).encode() + body


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
    warnings.simplefilter("ignore")
    built, marking = build_scenario()
    loop = BuiltNet(Net([Place(A)], [Transition(T)], [Arc(A, T), Arc(T, A)]))
    paths = [NetPath(f"t{n}") for n in range(20)]
    scan = BuiltNet(Net([Place(A)], [Transition(p) for p in paths], [Arc(A, p) for p in paths] + [Arc(p, A) for p in paths]))
    sinks = BuiltNet(Net([Place(A)], [Transition(p) for p in paths], [Arc(A, p) for p in paths]))
    rest = BuiltNet(Net([Place(A)], [], []))
    fire = BuiltNet(Net([Place(A), Place(B)], [Transition(T)], [Arc(A, T), Arc(T, B)]))

    report("simulate.fixture-32", lambda: run(built, marking, 32))
    report("simulate.loop-24x256", lambda: run(loop, black(24), 256))
    report("simulate.loop-512x256-oversized", lambda: run(loop, black(512), 256))
    report("simulate.scan-480x16", lambda: run(scan, black(480), 16))
    report("simulate.payload-990k-rest", lambda: run(rest, Marking({A: (Token("X", "x" * 990_000),)}), 1))
    report("simulate.payload-400k-fire", lambda: run(fire, Marking({A: (Token("X", "x" * 400_000),)}), 1))
    report("simulate.refused-scan-bound", lambda: run(sinks, black(512), 1))

    profile_request = f"GET /v1/simulation-profile HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: {ORIGIN}\r\n\r\n".encode()
    options_request = f"OPTIONS /v1/simulations HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: {ORIGIN}\r\n\r\n".encode()
    invalid_request = post(b'{"expected_definition":{},"initial_marking":[],"max_actions":true}')
    fixture_request = post(
        json.dumps(
            {
                "expected_definition": simulation_profile(built)["definition"],
                "initial_marking": project_marking(marking),
                "max_actions": 32,
            },
            separators=(",", ":"),
        ).encode()
    )
    server = create_simulation_server(built, "127.0.0.1", 0, allowed_origin=ORIGIN)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    port = server.server_port
    try:
        report("http.profile", lambda: roundtrip(port, profile_request))
        report("http.options", lambda: roundtrip(port, options_request))
        report("http.invalid-400", lambda: roundtrip(port, invalid_request))
        report("http.simulate-fixture-32", lambda: roundtrip(port, fixture_request))
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
