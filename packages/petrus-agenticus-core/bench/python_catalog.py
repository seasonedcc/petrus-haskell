"""Time the reference Catalog on the same workload as ``bench/Bench/Catalog.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_catalog.py

Workload: 1 000 enabled descriptors spread over the seven kinds, each offering
``cap-0``..``cap-9``; runtimes require five other kinds with all ten
capabilities. Each line prints the median per-operation time over several
batches after one warm-up batch.
"""

from __future__ import annotations

import json
import statistics
import time

from petrus.agenticus.catalog.descriptor import (
    CapabilityDescriptor,
    CompatibilityRequirement,
    DescriptorIdentity,
    DescriptorKind,
)
from petrus.agenticus.catalog.resolution import Catalog, ResolutionRequest, ResolutionSnapshot

KINDS = list(DescriptorKind)
CAPS = frozenset(f"cap-{j}" for j in range(10))
REQUIRED = (
    DescriptorKind.CONNECTION,
    DescriptorKind.HANDS,
    DescriptorKind.TERRITORY,
    DescriptorKind.CONTINUATION,
    DescriptorKind.EFFECT,
)


def workload() -> list[CapabilityDescriptor]:
    descriptors = []
    for i in range(1000):
        kind = KINDS[i % 7]
        requires = (
            tuple(CompatibilityRequirement(k, None, 1, CAPS) for k in REQUIRED) if kind is DescriptorKind.RUNTIME else ()
        )
        descriptors.append(CapabilityDescriptor(DescriptorIdentity(kind, f"{kind.value}-{i}", 1), CAPS, requires))
    return descriptors


def timed(name: str, action, per_batch: int, batches: int = 7) -> None:
    action()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        for _ in range(per_batch):
            action()
        samples.append((time.perf_counter() - start) / per_batch)
    print(f"{name:32} {statistics.median(samples) * 1e6:12.3f} us/op")


def main() -> None:
    descriptors = workload()
    catalog = Catalog()
    for descriptor in descriptors:
        catalog.register(descriptor)
        catalog.enable(descriptor.identity)
    request = ResolutionRequest(
        tuple(
            next(d.identity for d in descriptors if d.identity.kind is k) for k in (DescriptorKind.RUNTIME, *REQUIRED)
        )
    )
    snapshot = catalog.resolve(request).snapshot
    assert snapshot is not None
    data = snapshot.to_data()

    def register_all() -> int:
        fresh = Catalog()
        for descriptor in descriptors:
            fresh.register(descriptor)
            fresh.enable(descriptor.identity)
        return fresh.revision

    timed("catalog/resolve-6-kinds", lambda: catalog.resolve(request), 2000)
    timed("catalog/snapshot-to-json", lambda: json.dumps(snapshot.to_data()), 2000)
    timed("catalog/snapshot-from-data", lambda: ResolutionSnapshot.from_data(data), 2000)
    timed("catalog/register+enable-1000", register_all, 5)


if __name__ == "__main__":
    main()
