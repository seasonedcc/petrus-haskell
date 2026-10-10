"""The upstream observation HTTP server, for byte-level comparisons.

Usage: python -I reference_observation.py MODE

MODE is one of:

- ``fresh``: the upstream test's ``make_engine()``;
- ``advanced``: the same Engine after one ``advance()``;
- ``closed``: the same Engine, closed;
- ``broken``: read doors that fail with a ``KeyError`` (snapshot), a
  ``RecursionError`` (document) and a ``TypeError`` (history).

Prints the bound port, serves until stdin closes, then shuts down.
"""

import sys
import threading

from petrus.engine import Engine
from petrus.engine.observation_http import create_observation_server
from petrus.impetus.history_store import InMemoryHistoryStore
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition
from petrus.motus.dispatch import InMemoryDispatch

A, B, MOVE = NetPath("a"), NetPath("b"), NetPath("move")


def make_engine() -> Engine:
    return Engine.create(
        Net([Place(A), Place(B)], [Transition(MOVE)], [Arc(A, MOVE), Arc(MOVE, B)], name="http-observation"),
        "http-instance",
        history=InMemoryHistoryStore(),
        dispatch=InMemoryDispatch(),
        marking=Marking({A: (Token("value", {"n": 1}),)}),
    )


class Broken:
    def snapshot(self):
        raise KeyError("snapshot")

    def net_document(self):
        raise RecursionError("document")

    def history_page(self, after, limit):
        raise TypeError("history")


def main() -> None:
    mode = sys.argv[1]
    if mode == "broken":
        engine = Broken()
    else:
        engine = make_engine()
        if mode == "advanced":
            assert engine.advance().ready
        elif mode == "closed":
            engine.close()
    server = create_observation_server(engine, "127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    print(server.server_port, flush=True)
    sys.stdin.read()
    server.shutdown()
    server.server_close()
    thread.join()


if __name__ == "__main__":
    main()
