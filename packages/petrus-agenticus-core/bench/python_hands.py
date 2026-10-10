"""Time the reference Hands gateway on the same workload as ``bench/Bench/Hands.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_hands.py

Workload: gateway overhead per call over an in-memory adapter that answers
immediately; batches of 10 000 submissions with unique call ids (call ledger
and grant budget raised to fit), from one caller and from eight concurrent
callers (a thread pool), for ``workspace_read`` and ``workspace_write``. Each
batch builds a fresh gateway. ``parse-5-methods`` times ``parse_tool_request``
on one request of each method. Each line prints the median time over
several batches after one warm-up batch.
"""

from __future__ import annotations

import statistics
import time
from concurrent.futures import ThreadPoolExecutor
from threading import RLock

from petrus.agenticus.hands.contract import ToolMethod, parse_tool_request
from petrus.agenticus.hands.gateway import CallFence, HandsGateway, ShellOutcome, StagedWrite, TestOutcome
from petrus.agenticus.hands.grants import GrantLedger

BATCH = 10_000


def envelope(call: str, method: str, params: dict[str, object]) -> dict[str, object]:
    return {
        "version": 1,
        "call_id": call,
        "episode_id": "episode-1",
        "attachment_id": "attachment-1",
        "attachment_epoch": 1,
        "grant_epoch": 1,
        "method": method,
        "params": params,
    }


SAMPLES = [
    envelope("call-1", "workspace_read", {"path": "src/module/file.txt"}),
    envelope("call-1", "workspace_search", {"query": "needle", "path": "src"}),
    envelope("call-1", "workspace_shell", {"argv": ["printf", "ok"], "cwd": "."}),
    envelope("call-1", "workspace_write", {"path": "out.txt", "content": "x" * 256}),
    envelope("call-1", "workspace_test", {}),
]


def requests(method: str, params: dict[str, object]) -> list[dict[str, object]]:
    return [envelope(f"call-{i}", method, params) for i in range(1, BATCH + 1)]


READS = requests("workspace_read", {"path": "README.md"})
WRITES = requests("workspace_write", {"path": "out.txt", "content": "safe"})


class MemoryAdapter:
    def read(self, path: str) -> str:
        return "safe"

    def search(self, query: str, path: str) -> tuple[str, ...]:
        return ("match",)

    def shell(self, argv: tuple[str, ...], cwd: str) -> ShellOutcome:
        return ShellOutcome(0, "ok", "", False)

    def stage_write(self, call_id: str, path: str, content: str) -> StagedWrite:
        return StagedWrite(call_id, path, "d" * 64)

    def commit_write(self, staged: StagedWrite) -> str:
        return staged.digest

    def discard_write(self, staged: StagedWrite) -> None:
        return None

    def run_test(self) -> TestOutcome:
        return TestOutcome(True, "e" * 64)

    def discard_all_stages(self) -> int:
        return 0


class OpenFence:
    value = CallFence(True, False, 1e12)

    def snapshot(self) -> CallFence:
        return self.value


def fresh_gateway() -> HandsGateway:
    ledger = GrantLedger("attachment-1", 1)
    ledger.open(
        [ToolMethod.WORKSPACE_READ, ToolMethod.WORKSPACE_WRITE],
        writable_paths=["out.txt"],
        deadline=1e12,
        max_calls=BATCH,
    )
    return HandsGateway(
        episode_id="episode-1",
        adapter=MemoryAdapter(),
        grants=ledger,
        fence=OpenFence(),
        barrier=RLock(),
        max_calls=BATCH,
    )


def sequentially(payloads: list[dict[str, object]]) -> int:
    gateway = fresh_gateway()
    for payload in payloads:
        gateway.submit(payload)
    return gateway.counters().results_admitted


def concurrently(callers: int, payloads: list[dict[str, object]]) -> int:
    gateway = fresh_gateway()
    chunks = [payloads[k::callers] for k in range(callers)]

    def run(chunk: list[dict[str, object]]) -> None:
        for payload in chunk:
            gateway.submit(payload)

    with ThreadPoolExecutor(max_workers=callers) as pool:
        list(pool.map(run, chunks))
    return gateway.counters().results_admitted


def timed(name: str, action, per_batch: int, batches: int = 7) -> None:
    action()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        for _ in range(per_batch):
            action()
        samples.append((time.perf_counter() - start) / per_batch)
    median = statistics.median(samples)
    print(f"{name:36} {median * 1e6:14.3f} us/op")


def main() -> None:
    assert sequentially(READS) == BATCH and concurrently(8, WRITES) == BATCH
    timed("hands/parse-5-methods", lambda: [parse_tool_request(s) for s in SAMPLES], 2000)
    timed("hands/gateway-read-10k-1-caller", lambda: sequentially(READS), 1)
    timed("hands/gateway-read-10k-8-callers", lambda: concurrently(8, READS), 1)
    timed("hands/gateway-write-10k-1-caller", lambda: sequentially(WRITES), 1)
    timed("hands/gateway-write-10k-8-callers", lambda: concurrently(8, WRITES), 1)


if __name__ == "__main__":
    main()
