"""Time the reference DSL on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-dsl/bench/python_bench.py

Workloads (the ``chain`` and ``stamped`` builders of
``differential/dsl_corpus.py``, which the differential corpus checks the
Haskell twins against at sizes 50 and 30):

- ``chain-N``: a flat chain of N places and N transitions, authored, built
  to the canonical Net, and serialized as Net definition v3;
- ``stamped-K``: a 10-node child stamped at K scopes nested three deep,
  authored, composed, built, and serialized.

Each line prints the median of several runs after one warm-up, in
milliseconds, with the serialized size in bytes (the Haskell side prints the
same sizes).
"""

from __future__ import annotations

from pathlib import Path
import statistics
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "differential"))

from dsl_corpus import chain, stamped  # noqa: E402

from petrus.impetus.net_definition import project_net_definition, serialize_net_definition  # noqa: E402


def timed(name: str, action, repeats: int) -> None:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    print(f"{name:28} {statistics.median(samples) * 1000:12.3f} ms   (size {size}, n={repeats})")
    sys.stdout.flush()


def build(make, size: int):
    return lambda: len(make(size).build().net.arcs)


def serialize(make, size: int):
    return lambda: len(serialize_net_definition(project_net_definition(make(size).build().net)))


def main() -> None:
    for size, repeats in ((1_000, 10), (10_000, 5)):
        timed(f"build/chain-{size}", build(chain, size), repeats)
        timed(f"build+v3/chain-{size}", serialize(chain, size), repeats)
    for scopes, repeats in ((10, 20), (100, 10), (1_000, 5)):
        timed(f"build/stamped-{scopes}", build(stamped, scopes), repeats)
        timed(f"build+v3/stamped-{scopes}", serialize(stamped, scopes), repeats)


if __name__ == "__main__":
    main()
