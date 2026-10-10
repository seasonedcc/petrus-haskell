"""Time the reference Effect layer on the same workload as ``bench/Bench/Effect.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_effect.py

Workload (benchmark id ``agenticus-effect``, docs/runtime.md §11 Effect §6):

* ``digest_payload`` over nested payloads of about 1 KB, 100 KB and 1 MB of
  canonical JSON (records with Unicode and escaped strings, integers, bools,
  nulls, nested objects and lists);
* ``EffectGateway.execute`` with an in-memory adapter: the first-execution
  path (lookup, fresh fence, execute) and the replay path (lookup finds the
  applied receipt).

Each line prints the median per-operation time over several batches after a
warm-up batch, and the digests the Haskell twin checks before timing.
"""

from __future__ import annotations

import json
import statistics
import time

from petrus.agenticus.effect.gateway import EffectGateway
from petrus.agenticus.effect.model import (
    EffectDecision,
    EffectFence,
    EffectProposal,
    EffectReceipt,
    LookupResult,
    TargetIdentity,
    digest_payload,
)


def record(i: int) -> dict[str, object]:
    return {
        "id": i,
        "name": f"registro-é-😀-{i}",
        "note": 'texto "citado"\n\tcom barra \\ e controle \x01',
        "tags": ["α", "β", "γ", str(i % 7)],
        "flags": {"active": i % 2 == 0, "deleted": None, "score": i * 7919},
        "nested": {"z": [i, -i, 2**64 + i], "a": {"中文": "値", "k": i % 3 == 0}},
    }


def payload(target_bytes: int) -> dict[str, object]:
    records: list[dict[str, object]] = []
    size = 0
    while size < target_bytes:
        item = record(len(records))
        records.append(item)
        size += len(json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()) + 1
    return {"records": records, "meta": {"count": len(records), "schema": "bench-v1"}}


def timed(name: str, action, per_batch: int, batches: int = 7) -> None:
    for _ in range(max(1, per_batch // 4)):
        action()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        for _ in range(per_batch):
            action()
        samples.append((time.perf_counter() - start) / per_batch)
    print(f"{name:32} {statistics.median(samples) * 1e6:12.3f} us/op")


class Fences:
    def __init__(self, fence: EffectFence):
        self.fence = fence

    def current(self, proposal: EffectProposal) -> EffectFence:
        return self.fence


class Executing:
    """Lookup finds nothing; execute returns a correlated receipt."""

    def __init__(self, receipt: EffectReceipt):
        self.receipt = receipt

    def lookup(self, proposal: EffectProposal) -> LookupResult:
        return LookupResult.safe_to_retry()

    def execute(self, proposal: EffectProposal, payload: dict[str, object], fence: EffectFence) -> EffectReceipt:
        return self.receipt


class Replaying:
    """Lookup finds the applied receipt."""

    def __init__(self, receipt: EffectReceipt):
        self.result = LookupResult.applied(receipt)

    def lookup(self, proposal: EffectProposal) -> LookupResult:
        return self.result

    def execute(self, proposal: EffectProposal, payload: dict[str, object], fence: EffectFence) -> EffectReceipt:
        raise AssertionError("replay must not execute")


def main() -> None:
    sizes = {"1KB": 1_000, "100KB": 100_000, "1MB": 1_000_000}
    payloads = {name: payload(size) for name, size in sizes.items()}
    for name, value in payloads.items():
        canonical = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        print(f"# {name}: {len(canonical)} canonical bytes, {digest_payload(value)}")

    timed("effect/digest-1KB", lambda: digest_payload(payloads["1KB"]), 2000)
    timed("effect/digest-100KB", lambda: digest_payload(payloads["100KB"]), 50)
    timed("effect/digest-1MB", lambda: digest_payload(payloads["1MB"]), 5)

    message = {"message": "ready"}
    proposal = EffectProposal(
        "proposal-7",
        "bulletin.publish",
        1,
        digest_payload(message),
        TargetIdentity("bulletin", "release-notes"),
        "bulletin.publish",
    )
    fence = EffectFence(proposal.proposal_id, proposal.digest, 4, "revision-11", "episode-3", "attachment-8", 2)
    receipt = EffectReceipt(
        proposal.proposal_id,
        proposal.digest,
        proposal.payload_digest,
        proposal.target,
        digest_payload({"provider_record": "record-1"}),
    )
    approval = EffectDecision.approve(proposal, fence)
    executing = EffectGateway(Executing(receipt), Fences(fence))
    replaying = EffectGateway(Replaying(receipt), Fences(fence))
    timed("effect/gateway-execute", lambda: executing.execute(proposal, message, approval), 5000)
    timed("effect/gateway-replay", lambda: replaying.execute(proposal, message, approval), 5000)


if __name__ == "__main__":
    main()
