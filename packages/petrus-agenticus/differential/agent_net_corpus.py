"""Generate the Agent-as-Net differential corpus from the pinned reference.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus/differential/agent_net_corpus.py \
        ../../packages/petrus-agenticus/differential/agent_net_corpus.json

The corpus has three parts, replayed by ``test/Petrus/Agenticus/AgentNetSpec.hs``:

* ``definition``: the Net-definition v3 bytes of ``AGENT_AS_NET`` plus its
  sorted handler and guard URIs.
* ``runs``: scripted Engine runs (the upstream test scenarios plus seeded
  random ones). Each records the scripted model phases and Hands outcomes,
  the Activity calls observed, every History record's durable JSONL line,
  the final status, and the terminal token.
* ``envelopes``: ``from_data`` of valid and mutated envelopes, with the
  exact ``json.dumps(to_data())`` bytes or the exact refusal class and
  message.
"""

from __future__ import annotations

import copy
import json
import random
import sys
from pathlib import Path

from petrus.agenticus.program.agent_net import (
    AGENT_AS_NET,
    HANDS_ACTIVITY,
    MODEL_PHASE_ACTIVITY,
    HandsSettlement,
    LoopState,
    ModelResult,
    ModelSettlement,
    Proposal,
    StopReason,
    Terminal,
    ToolWork,
    agent_net_guards,
    agent_net_handlers,
    initial_marking,
    DONE,
)
from petrus.engine import Engine
from petrus.impetus.history.codec import encode_record
from petrus.impetus.history_store import InMemoryHistoryStore
from petrus.impetus.net_definition import project_net_definition, serialize_net_definition
from petrus.motus.dispatch import InlineDispatch

DIGEST = "a" * 64
METHODS = ("workspace_read", "workspace_write", "shell_run", "not_a_tool")
CATEGORIES = ("ok", "path", "aborted", "write", "deadline")


def state_data(phases: int, tools: int, capabilities: list[str], tool_count: int = 0) -> dict:
    return LoopState("episode-1", "turn-1", 1, phases, tool_count, tools, None, None, 7, tuple(capabilities)).to_data()


def run(initial: dict, script: list, hands: list) -> dict:
    model_script = iter(script)
    hands_script = iter(hands)
    calls: list = []

    def model(invocation, *, context):
        del context
        current = LoopState.from_data(invocation.input)
        stop, proposals = next(model_script)
        proposals = tuple(Proposal.from_data(item) for item in proposals)
        calls.append(
            ["model", current.phase, [item.id for item in proposals], [item.to_model_data() for item in current.results]]
        )
        return ModelSettlement(
            current, StopReason(stop), DIGEST, f"output-{current.phase}", f"continuation-{current.phase}", proposals
        ).to_data()

    def tool(invocation, *, context):
        del context
        item = invocation.input["proposal"]
        calls.append(["hands", item["id"], item["method"]])
        category, ok = next(hands_script)
        result = ModelResult(
            item["id"],
            ok,
            {"value": item["id"]} if ok else None,
            None if ok else {"category": category, "detail": "safe failure"},
        )
        return {"version": 1, "result": result.to_data()}

    engine = Engine.create(
        AGENT_AS_NET,
        "scripted-agent",
        history=InMemoryHistoryStore(),
        dispatch=InlineDispatch({MODEL_PHASE_ACTIVITY: model, HANDS_ACTIVITY: tool}),
        marking=initial_marking(LoopState.from_data(initial)),
        handlers=agent_net_handlers(),
        guards=agent_net_guards(),
    )
    while engine.advance().ready:
        pass
    done = engine.marking.place(DONE)
    return {
        "initial": initial,
        "script": script,
        "hands": hands,
        "calls": calls,
        "history": [json.dumps(encode_record(record), allow_nan=False) for record in engine.records],
        "status": engine.status.value,
        "terminal": done[0].data if done else None,
    }


def proposal(identity: str, method: str = "workspace_read") -> dict:
    return Proposal(identity, method, {"path": f"{identity}.txt"}).to_data()


def named_runs() -> list[dict]:
    default = state_data(3, 4, ["workspace_read"])
    cases = [
        ("stop", default, [["stop", []]], []),
        ("multi-tool", default, [["toolUse", [proposal("one"), proposal("two")]], ["stop", []]], [["ok", True], ["ok", True]]),
        (
            "unsupported-and-not-granted",
            default,
            [["toolUse", [proposal("unknown", "not_a_tool"), proposal("blocked", "workspace_write")]], ["stop", []]],
            [],
        ),
        ("length-batch", default, [["length", [proposal("one"), proposal("two")]], ["stop", []]], []),
        ("length-empty", default, [["length", []]], []),
        ("content-not-stop", default, [["stop", [proposal("one")]], ["stop", []]], [["ok", True]]),
        ("error", default, [["error", [proposal("ignored")]]], []),
        ("aborted", default, [["aborted", [proposal("ignored")]]], []),
        ("hands-abort", default, [["toolUse", [proposal("one"), proposal("two")]]], [["aborted", False]]),
        ("phase-budget", state_data(1, 4, ["workspace_read"]), [["length", [proposal("one")]]], []),
        ("tool-budget", state_data(3, 0, ["workspace_read"]), [["toolUse", [proposal("one")]]], []),
        ("mid-batch-budget", state_data(3, 1, ["workspace_read"]), [["toolUse", [proposal("one"), proposal("two")]]], [["ok", True]]),
        (
            "blocked-then-allowed",
            default,
            [["toolUse", [proposal("blocked", "workspace_write"), proposal("allowed")]], ["stop", []]],
            [["ok", True]],
        ),
        ("failed-hands", default, [["toolUse", [proposal("one")]], ["stop", []]], [["path", False]]),
        (
            "results-once",
            default,
            [["toolUse", [proposal("one")]], ["toolUse", [proposal("two")]], ["stop", []]],
            [["ok", True], ["ok", True]],
        ),
        (
            "unicode",
            state_data(2, 2, ["workspace_read", "shell_run"]),
            [["toolUse", [Proposal("café-☃", "shell_run", {"argv": ["echo", "é\U0001f600"]}).to_data()]], ["stop", []]],
            [["ok", True]],
        ),
    ]
    return [dict(run(initial, script, hands), name=name) for name, initial, script, hands in cases]


def random_runs(count: int, seed: int) -> list[dict]:
    rng = random.Random(seed)
    runs = []
    for case in range(count):
        phases = rng.randint(1, 4)
        tools = rng.randint(0, 5)
        capabilities = sorted(rng.sample(METHODS[:3], rng.randint(0, 3)))
        script = []
        serial = 0
        for _ in range(phases):
            stop = rng.choice(["stop", "toolUse", "toolUse", "toolUse", "length", "error", "aborted"])
            batch = []
            for _ in range(rng.randint(0, 3)):
                serial += 1
                batch.append(proposal(f"call-{serial}", rng.choice(METHODS)))
            script.append([stop, batch])
        hands = []
        for _ in range(tools):
            category = rng.choice(CATEGORIES)
            hands.append([category, category == "ok"])
        result = run(state_data(phases, tools, capabilities), script, hands)
        result["name"] = f"random-{case}"
        runs.append(result)
    return runs


def outcome(factory, data) -> dict:
    try:
        value = factory(data)
    except (ValueError, TypeError) as error:
        return {"class": type(error).__name__, "message": str(error)}
    return {"data": json.dumps(value.to_data())}


SETTLED = ModelSettlement(
    LoopState.from_data(state_data(3, 4, ["workspace_read"])),
    StopReason.TOOL_USE,
    DIGEST,
    "output-1",
    "continuation-1",
    (Proposal("one", "workspace_read", {"path": "one.txt"}), Proposal("two", "workspace_read", {})),
)
RESULT = ModelResult("one", True, {"value": "one"}, None)
FAILED = ModelResult("two", False, None, {"category": "path", "detail": "safe failure"})
STATE = LoopState("episode-1", "turn-1", 2, 3, 1, 4, "output-1", "continuation-1", 7, ("workspace_read", "shell_run"), (RESULT,))
WORK = ToolWork(STATE, DIGEST, (Proposal("one", "workspace_read", {}), Proposal("two", "workspace_read", {})), 1)
TERMINAL = Terminal("episode-1", "turn-1", __import__("petrus.agenticus.program.agent_net", fromlist=["TerminalCode"]).TerminalCode.COMPLETED, 2, 1, "output-2", "continuation-2")

BASES = {
    "proposal": (Proposal.from_data, Proposal("one", "workspace_read", {"path": "a"}).to_data()),
    "model_result": (ModelResult.from_data, RESULT.to_data()),
    "model_result_failed": (ModelResult.from_data, FAILED.to_data()),
    "loop_state": (LoopState.from_data, STATE.to_data()),
    "model_settlement": (ModelSettlement.from_data, SETTLED.to_data()),
    "tool_work": (ToolWork.from_data, WORK.to_data()),
    "hands_settlement": (
        HandsSettlement.from_data,
        HandsSettlement(WORK, ModelResult("two", True, {}, None)).to_data(),
    ),
    "terminal": (Terminal.from_data, TERMINAL.to_data()),
}

WEIRD = [
    None,
    True,
    False,
    0,
    1,
    -1,
    2,
    7,
    16,
    17,
    64,
    65,
    1.0,
    1.5,
    "",
    " x",
    "x ",
    "ok",
    "a\u0001b",
    "a\u007fb",
    "é" * 129,
    "x" * 256,
    "x" * 257,
    "a" * 64,
    "A" * 64,
    "workspace_read",
    "stop",
    "toolUse",
    "completed",
    "aborted",
    "path",
    "new-unruled-error",
    [],
    ["workspace_read"],
    ["x", "x"],
    {},
    {"k": "v"},
    {"category": "path", "detail": "d"},
    {"detail": "d", "category": "path"},
    {"category": "nope", "detail": "d"},
    {"category": ["list"], "detail": "d"},
    {"category": "path", "detail": "x" * 129},
    {"content": "x" * 4096},
    {"content": "é" * 700},
    {"content": "é" * 600},
]


def paths(value, prefix=()):
    """Every (path) into nested dicts and lists, depth-first."""
    yield prefix
    if isinstance(value, dict):
        for key, item in value.items():
            yield from paths(item, prefix + (key,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from paths(item, prefix + (index,))


def replaced(value, where, new):
    clone = copy.deepcopy(value)
    if not where:
        return new
    target = clone
    for step in where[:-1]:
        target = target[step]
    target[where[-1]] = new
    return clone


def removed(value, where):
    clone = copy.deepcopy(value)
    target = clone
    for step in where[:-1]:
        target = target[step]
    if isinstance(target, dict):
        del target[where[-1]]
    else:
        target.pop(where[-1])
    return clone


def added(value, where, key):
    clone = copy.deepcopy(value)
    target = clone
    for step in where:
        target = target[step]
    if isinstance(target, dict):
        target[key] = 1
    return clone


def envelopes(seed: int) -> list[dict]:
    rng = random.Random(seed)
    cases = []
    for kind, (factory, base) in BASES.items():
        cases.append({"kind": kind, "label": "base", "input": base, **outcome(factory, base)})
        every = list(paths(base))
        for where in every:
            weird = WEIRD if len(every) < 12 else rng.sample(WEIRD, 5)
            for new in weird:
                mutated = replaced(base, where, new)
                cases.append({"kind": kind, "label": f"set {list(where)}", "input": mutated, **outcome(factory, mutated)})
            if where:
                mutated = removed(base, where)
                cases.append({"kind": kind, "label": f"remove {list(where)}", "input": mutated, **outcome(factory, mutated)})
            parent = base
            for step in where:
                parent = parent[step]
            if isinstance(parent, dict):
                mutated = added(base, where, "extra")
                cases.append({"kind": kind, "label": f"add {list(where)}", "input": mutated, **outcome(factory, mutated)})
    return cases


def main() -> None:
    out = Path(sys.argv[1])
    corpus = {
        "definition": {
            "bytes": serialize_net_definition(project_net_definition(AGENT_AS_NET)).decode(),
            "handlers": sorted(str(uri) for uri in agent_net_handlers()),
            "guards": sorted(str(uri) for uri in agent_net_guards()),
        },
        "runs": named_runs() + random_runs(60, 20260),
        "envelopes": envelopes(4049),
    }
    out.write_text(json.dumps(corpus, separators=(",", ":"), ensure_ascii=True) + "\n")
    print(f"runs={len(corpus['runs'])} envelopes={len(corpus['envelopes'])}")


if __name__ == "__main__":
    main()
