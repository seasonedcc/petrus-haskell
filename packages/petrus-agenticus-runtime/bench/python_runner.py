"""Time the reference Local Agent-as-a-Net runner on the workload of ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_runner.py

Each line prints the median per-operation time over several batches, after
one warm-up batch.
"""

from __future__ import annotations

import json
import statistics
import tempfile
import time
from pathlib import Path

from petrus.agenticus.attachment.binding import BindingSettlement
from petrus.agenticus.attachment.episode import EpisodeAttachment
from petrus.agenticus.catalog.descriptor import CapabilityDescriptor
from petrus.agenticus.catalog.resolution import ResolutionSnapshot
from petrus.agenticus.hands.contract import CAPABILITY_SCOPED_HANDS, ToolMethod
from petrus.agenticus.hands.gateway import ShellOutcome, StagedWrite, TestOutcome
from petrus.agenticus.program.agent_net import LoopState, ModelSettlement, Proposal, StopReason
from petrus.agenticus.runtime.agent_net_runner import AgentNetRunner, AgentNetThreadProjection
from petrus.agenticus.runtime.profiles import AGENT_AS_NET_A5_LOCAL, TerritoryProfile, territory_identity
from petrus.agenticus.thread.identity import EpisodeId, ThreadId
from petrus.agenticus.thread.lifecycle import Thread

DIGEST = "a" * 64


class Binding:
    binding_kind = "local-runner"

    def cancel(self, reason: str) -> None:
        pass

    def export_archive(self) -> bytes:
        return b"archive"

    def settle(self) -> BindingSettlement:
        return BindingSettlement("local-runner", "clean", True)


class Workspace:
    def read(self, path: str) -> str:
        return "safe"

    def search(self, query: str, path: str) -> tuple[str, ...]:
        return ("match",)

    def shell(self, argv: tuple[str, ...], cwd: str) -> ShellOutcome:
        return ShellOutcome(0, "safe", "", False)

    def stage_write(self, call_id: str, path: str, content: str) -> StagedWrite:
        return StagedWrite(call_id, path, "b" * 64)

    def commit_write(self, staged: StagedWrite) -> str:
        return staged.digest

    def discard_write(self, staged: StagedWrite) -> None:
        pass

    def run_test(self) -> TestOutcome:
        return TestOutcome(True, "c" * 64)

    def discard_all_stages(self) -> int:
        return 0


def read(call_id: str, path: str) -> Proposal:
    return Proposal(call_id, "workspace_read", {"path": path})


class Model:
    def __init__(self) -> None:
        self.plans = iter(
            [
                (StopReason.TOOL_USE, (read("read-1", "README.md"), read("read-2", "src/main.py"))),
                (StopReason.TOOL_USE, (read("read-3", "docs/x.md"),)),
                (StopReason.STOP, ()),
            ]
        )

    def __call__(self, invocation, *, context) -> object:
        state = LoopState.from_data(invocation.input)
        context.heartbeat(details={"phase": "model"})
        stop, proposals = next(self.plans)
        return ModelSettlement(
            state, stop, DIGEST, f"output-{state.phase}", f"continuation-{state.phase}", proposals
        ).to_data()


def run_once() -> str:
    snapshot = ResolutionSnapshot(
        1,
        (
            AGENT_AS_NET_A5_LOCAL,
            CAPABILITY_SCOPED_HANDS,
            CapabilityDescriptor(territory_identity(TerritoryProfile.LOCAL), frozenset()),
        ),
    )
    current = EpisodeAttachment(
        episode_id=EpisodeId("episode-1"),
        snapshot=snapshot,
        binding=Binding(),
        attachment_id="attachment-1",
        deadline=100,
        clock=lambda: 1,
    )
    current.grants().open(
        (ToolMethod.WORKSPACE_READ,),
        writable_paths=("out.txt",),
        allowed_argv=(("printf", "ok"),),
        deadline=90,
        max_calls=8,
    )
    with tempfile.TemporaryDirectory() as tmp:
        runner = AgentNetRunner.create(
            tmp,
            instance_id="agent-net-1",
            thread=Thread(ThreadId("thread-1")),
            initial=LoopState("episode-1", "turn-1", 1, 3, 0, 8, None, None, 1, ("workspace_read",)),
            attachment=current,
            model_activity=Model(),
            hands_adapter=Workspace(),
        )
        projection = runner.drain()
        runner.close()
        assert projection.settled
        return (Path(tmp) / "thread.json").read_text(encoding="utf-8")


def roundtrip(text: str) -> str:
    value = AgentNetThreadProjection.from_data(json.loads(text))
    return json.dumps(value.to_data(), allow_nan=False, separators=(",", ":"), sort_keys=True)


def timed(label: str, operation, batches: int = 7, per_batch: int = 20) -> None:
    operation()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        for _ in range(per_batch):
            operation()
        samples.append((time.perf_counter() - start) / per_batch)
    median = statistics.median(samples)
    unit, scale = ("ms", 1e3) if median >= 1e-3 else ("µs", 1e6)
    print(f"{label:<28} {median * scale:8.3f} {unit}")


def main() -> None:
    final = run_once()
    timed("runner-3-phases-3-reads", run_once)
    timed("projection-roundtrip", lambda: roundtrip(final), per_batch=200)


if __name__ == "__main__":
    main()
