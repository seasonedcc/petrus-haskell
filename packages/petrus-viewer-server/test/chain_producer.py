"""Test fixture: the Python reference twin of test/ChainProducer.hs.

Usage: python -I chain_producer.py INSTANCE

The pinned upstream Engine for the chain Net a -> t1 -> b -> t2 -> c -> t3
-> d (name "viewer-chain", one token in a), served by the upstream
observation HTTP server on an ephemeral loopback port. Prints the port; each
stdin line "advance" runs one engine.advance() and prints the number of
firings; end of input shuts down.
"""

import sys
import threading

from petrus.engine import Engine
from petrus.engine.observation_http import create_observation_server
from petrus.impetus.history_store import InMemoryHistoryStore
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition
from petrus.motus.dispatch import InMemoryDispatch

A, B, C, D = (NetPath(p) for p in ("a", "b", "c", "d"))
T1, T2, T3 = (NetPath(t) for t in ("t1", "t2", "t3"))


def main() -> None:
    engine = Engine.create(
        Net(
            [Place(A), Place(B), Place(C), Place(D)],
            [Transition(T1), Transition(T2), Transition(T3)],
            [Arc(A, T1), Arc(T1, B), Arc(B, T2), Arc(T2, C), Arc(C, T3), Arc(T3, D)],
            name="viewer-chain",
        ),
        sys.argv[1],
        history=InMemoryHistoryStore(),
        dispatch=InMemoryDispatch(),
        marking=Marking({A: (Token("value", {"n": 1}),)}),
    )
    server = create_observation_server(engine, "127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    print(server.server_port, flush=True)
    for line in sys.stdin:
        if line.split() == ["advance"]:
            print(len(engine.advance().firings), flush=True)
        else:
            print(f"unknown command: {line.strip()}", flush=True)
    server.shutdown()
    server.server_close()
    thread.join()
    engine.close()


if __name__ == "__main__":
    main()
