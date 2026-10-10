"""Time the reference SQLite Engine on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-engine-sqlite/bench/python_bench.py

The order scenario is petrus-engine's (``engine_interop.py``) driven through
``petrus.engine.sqlite.create_engine`` / ``load_engine``. Every timing is the
median of several runs after one warm-up, in milliseconds, with a result size
the Haskell side computes too.
"""

from __future__ import annotations

import os
import shutil
import statistics
import sys
import tempfile
import time

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "petrus-engine", "test", "interop")
)

import engine_interop as scenario  # noqa: E402

from petrus.engine.sqlite import create_engine, load_engine  # noqa: E402
from petrus.impetus.petrinet import Net, Token  # noqa: E402
from petrus.motus.dispatch import InlineDispatch, InMemoryDispatch  # noqa: E402

SMALL_ORDERS = 3
LARGE_ORDERS = 200


def advance_until_rest(engine) -> None:
    while engine.advance().ready:
        pass


def orders(path: str, n: int) -> int:
    engine = create_engine(
        path,
        scenario.order_net(),
        scenario.IDENTITY,
        dispatch=InlineDispatch({"charge_card": scenario.charge_card}),
        handlers=scenario.handlers(),
    )
    for k in range(1, n + 1):
        engine.deliver(scenario.INTAKE, Token("Order", {"id": f"o-{k}", "amount": k}), identity=f"evt_{k}")
    advance_until_rest(engine)
    size = len(engine.records)
    engine.close()
    return size


def remove_database(path: str) -> None:
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)


def timed(name: str, action, repeats: int) -> None:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    print(f"{name:34} {statistics.median(samples) * 1000:12.3f} ms   (size {size}, n={repeats})")
    sys.stdout.flush()


def main() -> None:
    only = set(sys.argv[1:])
    directory = tempfile.mkdtemp(prefix="petrus-engine-sqlite-bench")
    fresh = os.path.join(directory, "fresh.sqlite3")
    existing = os.path.join(directory, "existing.sqlite3")
    empty = os.path.join(directory, "empty.sqlite3")
    empty_net = Net(places=[], transitions=[], arcs=[])
    orders(existing, LARGE_ORDERS)
    create_engine(empty, empty_net, "one", dispatch=InlineDispatch({})).close()

    def fresh_orders(n: int):
        def run() -> int:
            size = orders(fresh, n)
            remove_database(fresh)
            return size

        return run

    def load() -> int:
        engine = load_engine(
            existing,
            scenario.order_net(),
            scenario.IDENTITY,
            dispatch=InlineDispatch({"charge_card": scenario.charge_card}),
            handlers=scenario.handlers(),
        )
        engine.advance()
        size = len(engine.records)
        engine.close()
        return size

    def open_close() -> int:
        engine = load_engine(empty, empty_net, "one", dispatch=InMemoryDispatch())
        size = len(engine.records)
        engine.close()
        return size

    workloads = [
        ("engine-sqlite/orders-small-sqlite", fresh_orders(SMALL_ORDERS), 20),
        ("engine-sqlite/orders-large-sqlite", fresh_orders(LARGE_ORDERS), 3),
        ("engine-sqlite/load-sqlite", load, 5),
        ("engine-sqlite/open-close", open_close, 200),
    ]
    for name, action, repeats in workloads:
        if not only or name.split("/")[-1] in only:
            timed(name, action, repeats)
    shutil.rmtree(directory)


if __name__ == "__main__":
    main()
