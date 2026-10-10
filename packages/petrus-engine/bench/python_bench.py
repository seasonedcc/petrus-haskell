"""Time the reference Engine on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-engine/bench/python_bench.py

The order scenario is the interop suite's (``test/interop/engine_interop.py``):
identified deliveries, a pure validation, an inline Activity charge, and a
delayed settlement, driven end to end by one-action ``advance`` turns. Every
timing is the median of several runs after one warm-up, in milliseconds,
with a result size the Haskell side computes too.
"""

from __future__ import annotations

import os
import shutil
import statistics
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test", "interop"))

import engine_interop as scenario  # noqa: E402

from petrus.engine import Engine  # noqa: E402
from petrus.impetus.history_store import InMemoryHistoryStore, JsonlHistoryStore  # noqa: E402
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition  # noqa: E402
from petrus.motus.dispatch import InlineDispatch, InMemoryDispatch  # noqa: E402

SMALL_ORDERS = 3
LARGE_ORDERS = 200
CHAIN_LENGTH = 20
CHAIN_TOKENS = 50


def advance_until_rest(engine: Engine) -> int:
    turns = 1
    while engine.advance().ready:
        turns += 1
    return turns


def orders(history, n: int) -> int:
    engine = Engine.create(
        scenario.order_net(),
        scenario.IDENTITY,
        history=history,
        dispatch=InlineDispatch({"charge_card": scenario.charge_card}),
        handlers=scenario.handlers(),
    )
    for k in range(1, n + 1):
        engine.deliver(scenario.INTAKE, Token("Order", {"id": f"o-{k}", "amount": k}), identity=f"evt_{k}")
    advance_until_rest(engine)
    size = len(engine.records)
    engine.close()
    return size


def chain_net() -> Net:
    places = [Place(NetPath(f"p{i}")) for i in range(CHAIN_LENGTH + 1)]
    transitions = [Transition(NetPath(f"t{i}")) for i in range(CHAIN_LENGTH)]
    arcs = []
    for i in range(CHAIN_LENGTH):
        arcs.append(Arc(NetPath(f"p{i}"), NetPath(f"t{i}")))
        arcs.append(Arc(NetPath(f"t{i}"), NetPath(f"p{i + 1}")))
    return Net(places=places, transitions=transitions, arcs=arcs)


def chain() -> int:
    marking = Marking({NetPath("p0"): tuple(Token("Item", {"seq": k}) for k in range(CHAIN_TOKENS))})
    engine = Engine.create(chain_net(), "chain", history=InMemoryHistoryStore(), dispatch=InMemoryDispatch(), marking=marking)
    advance_until_rest(engine)
    size = len(engine.records)
    engine.close()
    return size


def timed(name: str, action, repeats: int) -> None:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    print(f"{name:28} {statistics.median(samples) * 1000:12.3f} ms   (size {size}, n={repeats})")
    sys.stdout.flush()


def main() -> None:
    directory = tempfile.mkdtemp(prefix="petrus-engine-bench")
    fresh = os.path.join(directory, "fresh.jsonl")
    existing = os.path.join(directory, "existing.jsonl")
    orders(JsonlHistoryStore(existing), LARGE_ORDERS)

    def jsonl_orders() -> int:
        size = orders(JsonlHistoryStore(fresh), LARGE_ORDERS)
        os.remove(fresh)
        return size

    def load() -> int:
        engine = Engine.load(
            scenario.order_net(),
            scenario.IDENTITY,
            history=JsonlHistoryStore(existing),
            dispatch=InlineDispatch({"charge_card": scenario.charge_card}),
            handlers=scenario.handlers(),
        )
        engine.advance()
        size = len(engine.records)
        engine.close()
        return size

    timed("engine/orders-small", lambda: orders(InMemoryHistoryStore(), SMALL_ORDERS), 20)
    timed("engine/orders-large", lambda: orders(InMemoryHistoryStore(), LARGE_ORDERS), 3)
    timed("engine/orders-large-jsonl", jsonl_orders, 3)
    timed("engine/chain", chain, 3)
    timed("engine/load-jsonl", load, 5)
    shutil.rmtree(directory)


if __name__ == "__main__":
    main()
