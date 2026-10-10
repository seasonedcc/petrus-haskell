"""Time the reference Thread lifecycle on the same workload as ``bench/Bench/Thread.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/bench/python_thread.py

Workload: one Thread with 1 000 sequential Episodes of 4 Turns each.  Every
Episode runs a harness-owned program that produces a Continuation: start the
Episode (claiming the previous revision), then four times start a Turn, accept
one append and settle it completed, then settle the Episode completed with a
fresh result Continuation.  Each line prints the median per-operation time
over several batches after one warm-up run.
"""

from __future__ import annotations

import json
import statistics
import time

from petrus.agenticus.catalog.descriptor import DescriptorIdentity, DescriptorKind
from petrus.agenticus.program.descriptor import (
    AgentProgramDescriptor,
    ContinuationRequirement,
    ProgramOwnership,
)
from petrus.agenticus.thread.continuation import Continuation, ContinuationDescriptor
from petrus.agenticus.thread.identity import ContinuationId, EpisodeId, ThreadId, TurnId
from petrus.agenticus.thread.lifecycle import EpisodeBudget, EpisodeOutcome, Thread, TurnOutcome

PROGRAM_ID = DescriptorIdentity(DescriptorKind.PROGRAM, "bench.program", 1)
CONTINUATION_IDENTITY = DescriptorIdentity(DescriptorKind.CONTINUATION, "bench.context", 1)
RUNTIME = DescriptorIdentity(DescriptorKind.RUNTIME, "bench.runtime", 1)
PROGRAM = AgentProgramDescriptor(
    identity=PROGRAM_ID,
    ownership=ProgramOwnership.HARNESS,
    accepted_continuations=(ContinuationRequirement(CONTINUATION_IDENTITY, PROGRAM_ID),),
    produced_continuation=CONTINUATION_IDENTITY,
)
DESCRIPTOR = ContinuationDescriptor(CONTINUATION_IDENTITY, PROGRAM_ID)
BUDGET = EpisodeBudget(max_turns=4, max_accepted_appends=4)


def episode(thread: Thread, i: int) -> Thread:
    thread = thread.start_episode(EpisodeId(f"episode-{i}"), PROGRAM, RUNTIME, BUDGET)
    for j in range(1, 5):
        turn = TurnId(f"turn-{i * 4 + j}")
        thread = thread.start_turn(turn).accept_append(turn).settle_turn(turn, TurnOutcome.COMPLETED)
    following = Continuation(ContinuationId(f"continuation-{i}"), thread.id, DESCRIPTOR, f"store:{i}")
    return thread.settle_episode(EpisodeOutcome.COMPLETED, following).thread


def build(n: int) -> Thread:
    thread = Thread(ThreadId("bench-thread"))
    for i in range(1, n + 1):
        thread = episode(thread, i)
    return thread


def timed(name: str, action, per_batch: int, batches: int = 5) -> None:
    action()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        for _ in range(per_batch):
            action()
        samples.append((time.perf_counter() - start) / per_batch)
    median = statistics.median(samples)
    unit, scale = ("ms", 1e3) if median >= 1e-3 else ("us", 1e6)
    print(f"{name:32} {median * scale:12.3f} {unit}/op")


def main() -> None:
    built = build(1000)
    data = built.to_data()
    timed("thread/build-1000x4", lambda: build(1000), 1, 3)
    timed("thread/episode-after-1000", lambda: episode(built, 1001), 5)
    timed("thread/to-json-1000x4", lambda: json.dumps(built.to_data()), 5)
    timed("thread/dumps-only-1000x4", lambda: json.dumps(data), 5)
    timed("thread/from-data-1000x4", lambda: Thread.from_data(data), 5)


if __name__ == "__main__":
    main()
