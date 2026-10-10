"""Generate the Local Agent-as-a-Net runner differential corpus from the reference.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-runtime/differential/runner_corpus.py \
        ../../packages/petrus-agenticus-runtime/differential/runner_corpus.json

Sections:

* ``runs``: scripted runs of ``AgentNetRunner`` with the same scripted
  Binding, Workspace and Model as ``test_agent_net_runner.py``. Each run
  records the exact ``thread.json`` text after ``create`` and after every
  ``advance``, the final ``history.jsonl`` text, the refusal that stopped the
  run (if any), and the Workspace and Binding call logs.
* ``projections``: ``AgentNetThreadProjection.from_data`` over every
  committed ``thread.json`` value and over mutations of them (a removed key,
  an ``"extra": 1`` key, or a weird value at one path; seed 7071). Each case
  names its base step and mutation, and records either the compact sorted
  ``to_data`` bytes or the ``{class, message}`` refusal.
"""

from __future__ import annotations

import copy
import json
import random
import sys
import tempfile
from dataclasses import dataclass, field
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

SEED = 7071
DIGEST = "a" * 64


@dataclass
class Binding:
    events: list[str] = field(default_factory=list)
    binding_kind: str = "local-runner"

    def cancel(self, reason: str) -> None:
        self.events.append("cancel")

    def export_archive(self) -> bytes:
        self.events.append("export")
        return b"archive"

    def settle(self) -> BindingSettlement:
        self.events.append("destroy")
        return BindingSettlement("local-runner", "clean", True)


class Workspace:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def read(self, path: str) -> str:
        self.calls.append("read")
        return "safe"

    def search(self, query: str, path: str) -> tuple[str, ...]:
        self.calls.append("search")
        return ("match",)

    def shell(self, argv: tuple[str, ...], cwd: str) -> ShellOutcome:
        self.calls.append("shell")
        return ShellOutcome(0, "safe", "", False)

    def stage_write(self, call_id: str, path: str, content: str) -> StagedWrite:
        self.calls.append("stage")
        return StagedWrite(call_id, path, "b" * 64)

    def commit_write(self, staged: StagedWrite) -> str:
        self.calls.append("commit")
        return staged.digest

    def discard_write(self, staged: StagedWrite) -> None:
        self.calls.append("discard")

    def run_test(self) -> TestOutcome:
        self.calls.append("test")
        return TestOutcome(True, "c" * 64)

    def discard_all_stages(self) -> int:
        self.calls.append("cleanup")
        return 0


class Model:
    def __init__(self, plans: list[dict[str, object]], failing: bool) -> None:
        self.plans = iter(plans)
        self.failing = failing

    def __call__(self, invocation, *, context) -> object:
        if self.failing:
            raise RuntimeError("provider-failed")
        state = LoopState.from_data(invocation.input)
        context.heartbeat(details={"phase": "model"})
        plan = next(self.plans)
        proposals = tuple(Proposal(p["id"], p["name"], p["arguments"]) for p in plan["proposals"])
        return ModelSettlement(
            state,
            StopReason(plan["stop"]),
            DIGEST,
            f"output-{state.phase}",
            f"continuation-{state.phase}",
            proposals,
        ).to_data()


def proposal(call_id: str, name: str, arguments: dict[str, object]) -> dict[str, object]:
    # Keys are sorted because the corpus file is written with sort_keys=True,
    # and the replay must see the arguments in the order the reference used.
    return {"id": call_id, "name": name, "arguments": dict(sorted(arguments.items()))}


READ = proposal("read-1", "workspace_read", {"path": "README.md"})


def scenario(name: str, plans: list[dict[str, object]], **overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "name": name,
        "methods": ["workspace_read"],
        "max_calls": 4,
        "capabilities": ["workspace_read"],
        "phase_limit": 3,
        "tool_limit": 4,
        "failing": False,
        "plans": plans,
    }
    value.update(overrides)
    return value


def plan(stop: str, *proposals: dict[str, object]) -> dict[str, object]:
    return {"stop": stop, "proposals": list(proposals)}


ALL_TOOLS = ["workspace_read", "workspace_search", "workspace_shell", "workspace_write", "workspace_test"]

SCENARIOS = [
    scenario("stop", [plan("stop")]),
    scenario("read-then-stop", [plan("toolUse", READ), plan("stop")]),
    scenario(
        "multi-tool-batches",
        [
            plan(
                "toolUse",
                proposal("read-1", "workspace_read", {"path": "README.md"}),
                proposal("read-2", "workspace_read", {"path": "src/main.py"}),
            ),
            plan("toolUse", proposal("read-3", "workspace_read", {"path": "docs/x.md"})),
            plan("stop"),
        ],
        tool_limit=8,
        max_calls=8,
    ),
    scenario(
        "every-tool",
        [
            plan(
                "toolUse",
                proposal("read-1", "workspace_read", {"path": "README.md"}),
                proposal("search-1", "workspace_search", {"query": "needle", "path": "."}),
                proposal("shell-1", "workspace_shell", {"argv": ["printf", "ok"], "cwd": "."}),
            ),
            plan(
                "toolUse",
                proposal("write-1", "workspace_write", {"path": "out.txt", "content": "hello"}),
                proposal("test-1", "workspace_test", {}),
            ),
            plan("stop"),
        ],
        methods=ALL_TOOLS,
        capabilities=ALL_TOOLS,
        max_calls=8,
        tool_limit=8,
    ),
    scenario(
        "not-granted-and-unsupported",
        [
            plan(
                "toolUse",
                proposal("write-1", "workspace_write", {"path": "out.txt", "content": "x"}),
                proposal("other-1", "browser_open", {"url": "https://example.invalid"}),
                READ,
            ),
            plan("stop"),
        ],
    ),
    scenario("phase-budget", [plan("toolUse", READ)], phase_limit=1),
    scenario(
        "tool-budget",
        [
            plan(
                "toolUse",
                proposal("read-1", "workspace_read", {"path": "a"}),
                proposal("read-2", "workspace_read", {"path": "b"}),
            ),
            plan("stop"),
        ],
        tool_limit=1,
    ),
    scenario("length-with-proposal", [plan("length", READ), plan("stop")]),
    scenario("length", [plan("length")]),
    scenario("aborted", [plan("aborted")]),
    scenario("error", [plan("error")]),
    scenario("failing-model", [], failing=True),
]


def attachment(spec: dict[str, object]) -> tuple[EpisodeAttachment, Binding]:
    binding = Binding()
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
        binding=binding,
        attachment_id="attachment-1",
        deadline=100,
        clock=lambda: 1,
    )
    current.grants().open(
        tuple(ToolMethod(m) for m in spec["methods"]),
        writable_paths=("out.txt",),
        allowed_argv=(("printf", "ok"),),
        deadline=90,
        max_calls=spec["max_calls"],
    )
    return current, binding


def refusal(error: BaseException) -> dict[str, str]:
    return {"class": type(error).__name__, "message": str(error)}


def run(spec: dict[str, object]) -> dict[str, object]:
    current, binding = attachment(spec)
    workspace = Workspace()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        runner = AgentNetRunner.create(
            root,
            instance_id="agent-net-1",
            thread=Thread(ThreadId("thread-1")),
            initial=LoopState(
                "episode-1",
                "turn-1",
                1,
                spec["phase_limit"],
                0,
                spec["tool_limit"],
                None,
                None,
                1,
                tuple(spec["capabilities"]),
            ),
            attachment=current,
            model_activity=Model(spec["plans"], spec["failing"]),
            hands_adapter=workspace,
        )
        steps = [(root / "thread.json").read_text(encoding="utf-8")]
        error = None
        try:
            for _ in range(64):
                if runner.settled:
                    break
                runner.advance()
                steps.append((root / "thread.json").read_text(encoding="utf-8"))
        except Exception as caught:  # noqa: BLE001 - the refusal is the recorded outcome
            error = refusal(caught)
            steps.append((root / "thread.json").read_text(encoding="utf-8"))
        history = (root / "history.jsonl").read_text(encoding="utf-8")
        runner.close()
    return {
        **spec,
        "steps": steps,
        "error": error,
        "history": history,
        "workspace_calls": workspace.calls,
        "binding_events": binding.events,
    }


WEIRD: list[object] = [
    None,
    True,
    False,
    0,
    -1,
    1,
    2,
    1.5,
    "",
    "x",
    "x" * 300,
    "x" * 600,
    [],
    {},
    ["a"],
    {"k": 1},
    "stop",
    "completed",
    "indeterminate",
    "model_phase",
    "hands",
    "episode-1",
    "turn-1",
]


def paths(value: object, prefix: tuple[object, ...] = ()) -> list[tuple[object, ...]]:
    found = [prefix]
    if isinstance(value, dict):
        for key, item in value.items():
            found.extend(paths(item, (*prefix, key)))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(paths(item, (*prefix, index)))
    return found


def at(value: object, path: tuple[object, ...]) -> object:
    for key in path:
        value = value[key]  # type: ignore[index]
    return value


def replace_at(value: object, path: tuple[object, ...], new: object) -> object:
    if not path:
        return new
    copied = copy.deepcopy(value)
    at(copied, path[:-1])[path[-1]] = new  # type: ignore[index]
    return copied


def remove_at(value: object, path: tuple[object, ...]) -> object:
    copied = copy.deepcopy(value)
    del at(copied, path[:-1])[path[-1]]  # type: ignore[union-attr]
    return copied


def extra_at(value: object, path: tuple[object, ...]) -> object:
    copied = copy.deepcopy(value)
    at(copied, path)["extra"] = 1  # type: ignore[index]
    return copied


def outcome(data: object) -> dict[str, object]:
    try:
        value = AgentNetThreadProjection.from_data(data)
    except Exception as error:  # noqa: BLE001 - the refusal is the recorded outcome
        return refusal(error)
    return {"data": json.dumps(value.to_data(), allow_nan=False, separators=(",", ":"), sort_keys=True)}


def projection_cases(runs: list[dict[str, object]], rng: random.Random) -> list[dict[str, object]]:
    """Mutations are stored as ``{run, step, path, op, value}`` against a
    committed step, not as whole documents, to keep the corpus small."""
    cases = []
    for run_index, entry in enumerate(runs):
        steps = entry["steps"]  # type: ignore[assignment]
        for step_index, step in enumerate(steps):  # type: ignore[arg-type]
            base = json.loads(step)
            where = {"run": run_index, "step": step_index}
            cases.append({**where, "path": [], "op": "none", "value": None, **outcome(base)})
            candidates = paths(base)
            for path in rng.sample(candidates, min(len(candidates), 12)):
                container = at(base, path[:-1]) if path else None
                if path and isinstance(container, dict):
                    mutated = remove_at(base, path)
                    cases.append({**where, "path": list(path), "op": "remove", "value": None, **outcome(mutated)})
                if isinstance(at(base, path), dict):
                    mutated = extra_at(base, path)
                    cases.append({**where, "path": list(path), "op": "extra", "value": None, **outcome(mutated)})
                for weird in rng.sample(WEIRD, 4):
                    mutated = replace_at(base, path, weird)
                    cases.append({**where, "path": list(path), "op": "replace", "value": weird, **outcome(mutated)})
    return cases


def main() -> None:
    rng = random.Random(SEED)
    runs = [run(spec) for spec in SCENARIOS]
    corpus = {"seed": SEED, "runs": runs, "projections": projection_cases(runs, rng)}
    Path(sys.argv[1]).write_text(json.dumps(corpus, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
