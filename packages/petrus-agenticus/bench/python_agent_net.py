"""Time the reference Agent-as-a-Net on the workload of ``bench/Bench/AgentNet.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus/bench/python_agent_net.py

Each line prints the median per-operation time over several batches, after
one warm-up batch.
"""

from __future__ import annotations

import json
import statistics
import time

from petrus.agenticus.program.agent_net import (
    AGENT_AS_NET,
    HANDS_ACTIVITY,
    MODEL_PHASE_ACTIVITY,
    LoopState,
    ModelResult,
    ModelSettlement,
    Proposal,
    StopReason,
    agent_net_guards,
    agent_net_handlers,
    initial_marking,
)
from petrus.engine import Engine
from petrus.impetus.history_store import InMemoryHistoryStore
from petrus.motus.dispatch import InlineDispatch

DIGEST = "a" * 64
INITIAL = LoopState("episode-1", "turn-1", 1, 4, 0, 8, None, None, 7, ("workspace_read",), ())


def proposals_for(phase: int) -> tuple[Proposal, ...]:
    if phase > 3:
        return ()
    return tuple(
        Proposal(f"call-{phase}-{k}", "workspace_read", {"path": f"call-{phase}-{k}.txt"}) for k in (1, 2)
    )


def model(invocation, *, context):
    del context
    current = LoopState.from_data(invocation.input)
    proposals = proposals_for(current.phase)
    stop = StopReason.TOOL_USE if proposals else StopReason.STOP
    return ModelSettlement(
        current, stop, DIGEST, f"output-{current.phase}", f"continuation-{current.phase}", proposals
    ).to_data()


def tool(invocation, *, context):
    del context
    identity = invocation.input["proposal"]["id"]
    return {"version": 1, "result": ModelResult(identity, True, {"value": identity}, None).to_data()}


HANDLERS = agent_net_handlers()
GUARDS = agent_net_guards()


def run_once() -> int:
    engine = Engine.create(
        AGENT_AS_NET,
        "scripted-agent",
        history=InMemoryHistoryStore(),
        dispatch=InlineDispatch({MODEL_PHASE_ACTIVITY: model, HANDS_ACTIVITY: tool}),
        marking=initial_marking(INITIAL),
        handlers=HANDLERS,
        guards=GUARDS,
    )
    while engine.advance().ready:
        pass
    count = len(engine.records)
    engine.close()
    return count


RICH = LoopState(
    "episode-1",
    "turn-1",
    3,
    16,
    16,
    64,
    "output-2",
    "continuation-2",
    7,
    ("workspace_read", "workspace_write"),
    tuple(ModelResult(f"call-{k}", True, {"value": f"call-{k}"}, None) for k in range(1, 17)),
)


def roundtrip() -> int:
    return LoopState.from_data(json.loads(json.dumps(RICH.to_data()))).phase


def timed(name: str, action, per_batch: int, batches: int = 7) -> None:
    for _ in range(per_batch):
        action()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        for _ in range(per_batch):
            action()
        samples.append((time.perf_counter() - start) / per_batch)
    print(f"{name:32} {statistics.median(samples) * 1e6:12.3f} us/op")


def main() -> None:
    assert run_once() == 122, "workload drifted from bench/Bench/AgentNet.hs"
    timed("agent-net/run-4-phases-6-tools", run_once, 200)
    timed("agent-net/loop-state-roundtrip-16", roundtrip, 2000)


if __name__ == "__main__":
    main()
