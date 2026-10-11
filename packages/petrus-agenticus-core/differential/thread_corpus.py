"""Generate the Thread/Program/Runtime-foundation differential corpus.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/differential/thread_corpus.py

It writes ``thread_corpus.json`` next to this script.  The Haskell suite
(``test/Petrus/Agenticus/ThreadDifferentialSpec.hs``) replays every case and
compares the exact ``json.dumps`` bytes and the exact refusal class and
message:

* ``traces``: seeded random lifecycle sessions (start_episode, start_turn,
  accept_append, settle_turn, request_cancellation, settle_episode, close,
  plus Episode-level settle/cancel probes), recording
  ``json.dumps(thread.to_data())`` after every accepted step and the refusal
  of every rejected one;
* ``decode``: ``from_data`` of every lifecycle document the traces produced,
  and of seeded random mutations of them (each invariant violation);
* ``compatibility``: explicit Continuation compatibility verdicts;
* ``runtime``: installation, probe, turn-result, cleanup and protocol-error
  values.
"""

from __future__ import annotations

import copy
import json
import sys
import random
from pathlib import Path
from typing import Any

from petrus.agenticus.catalog.descriptor import DescriptorIdentity, DescriptorKind
from petrus.agenticus.program.descriptor import (
    AgentProgramDescriptor,
    ContinuationRequirement,
    ProgramOwnership,
)
from petrus.agenticus.runtime.installation import (
    InstalledComponent,
    ProbeDisposition,
    ProbeIssue,
    RuntimeInstallation,
    RuntimeProbeResult,
)
from petrus.agenticus.runtime.operation import (
    RuntimeCleanupDisposition,
    RuntimeOperationCleanup,
    RuntimeProtocolError,
)
from petrus.agenticus.runtime.result import RuntimeTurnSettlement, safe_termination_code
from petrus.agenticus.thread.continuation import (
    Continuation,
    ContinuationDescriptor,
    ContinuationState,
    check_continuation_compatibility,
)
from petrus.agenticus.thread.identity import ContinuationId, EpisodeId, ThreadId, TurnId
from petrus.agenticus.thread.lifecycle import (
    Episode,
    EpisodeBudget,
    EpisodeOutcome,
    Thread,
    Turn,
    TurnOutcome,
)

SEED = 20260710
OUT_NAME = "thread_corpus.json"


def dumps(value: object) -> str:
    return json.dumps(value)


def refusal(error: Exception) -> dict[str, str]:
    return {"class": type(error).__name__, "message": str(error)}


def attempt(action) -> dict[str, Any]:
    try:
        return {"ok": action()}
    except (ValueError, TypeError, LookupError, RuntimeError) as error:
        return {"error": refusal(error)}


def ident(kind: DescriptorKind, name: str, version: int = 1) -> DescriptorIdentity:
    return DescriptorIdentity(kind, name, version)


# ---------------------------------------------------------------------------
# Pools

PROGRAMS = [ident(DescriptorKind.PROGRAM, name) for name in ("prog.alpha", "prog.beta", "prog.gamma")]
CONTINUATIONS = [ident(DescriptorKind.CONTINUATION, name) for name in ("cont.alpha", "cont.beta", "cont.gamma")]
RUNTIMES = [ident(DescriptorKind.RUNTIME, name) for name in ("rt.local", "rt.docker", "rt.e2b")]


def program_pool() -> list[AgentProgramDescriptor]:
    a, b, g = PROGRAMS
    ca, cb, cg = CONTINUATIONS
    return [
        AgentProgramDescriptor(a, ProgramOwnership.HARNESS, True, (ContinuationRequirement(ca, a),), ca),
        AgentProgramDescriptor(a, ProgramOwnership.HARNESS),
        AgentProgramDescriptor(b, ProgramOwnership.PROVIDER, False, (ContinuationRequirement(cb, b),), cb),
        AgentProgramDescriptor(
            b,
            ProgramOwnership.NET,
            True,
            (ContinuationRequirement(ca, a), ContinuationRequirement(cb, b)),
            cb,
            True,
            False,
        ),
        AgentProgramDescriptor(g, ProgramOwnership.NET, True, (ContinuationRequirement(cg, a),), cg, False, True),
        AgentProgramDescriptor(g, ProgramOwnership.PROVIDER, True, (), cg),
    ]


PROGRAM_POOL = program_pool()
BUDGETS = [(1, 1), (2, 2), (3, 2), (2, 5), (4, 4), (1, 3)]
TURN_OUTCOMES = list(TurnOutcome)
EPISODE_OUTCOMES = list(EpisodeOutcome)


class Session:
    def __init__(self, rng: random.Random, index: int) -> None:
        self.rng = rng
        self.index = index
        self.thread_id = f"thread-{index}"
        self.continuation_counter = 0
        self.turn_counter = 0
        self.episode_counter = 0

    def new_continuation_id(self) -> str:
        if self.continuation_counter and self.rng.random() < 0.08:
            return f"cont-{self.index}-{self.rng.randrange(self.continuation_counter)}"
        self.continuation_counter += 1
        return f"cont-{self.index}-{self.continuation_counter - 1}"

    def continuation(self, thread: Thread | None, *, initial: bool = False) -> Continuation | None:
        rng = self.rng
        if rng.random() < (0.5 if initial else 0.25):
            return None
        expected = None
        program = None
        if thread is not None and thread.episodes:
            last = thread.episodes[-1]
            expected = last.expected_continuation
            program = last.program
        identity = expected if expected is not None and rng.random() < 0.8 else rng.choice(CONTINUATIONS)
        producer = program if program is not None and rng.random() < 0.85 else rng.choice(PROGRAMS)
        thread_id = self.thread_id if rng.random() < 0.93 else "thread-elsewhere"
        state = ContinuationState.AVAILABLE if rng.random() < 0.9 else rng.choice(list(ContinuationState))
        reference = rng.choice(["opaque:ref-1", "opaque:ref-2", "store:key"])
        return Continuation(
            ContinuationId(self.new_continuation_id()),
            ThreadId(thread_id),
            ContinuationDescriptor(identity, producer),
            reference,
            state,
        )

    def step(self, thread: Thread) -> tuple[dict[str, Any], Thread]:
        rng = self.rng
        episodes = thread.episodes
        active = bool(episodes) and episodes[-1].state.value != "settled"
        current_turn = None
        if episodes and episodes[-1].turns:
            current_turn = episodes[-1].turns[-1].id.value
        running_turn = (
            current_turn
            if episodes and episodes[-1].turns and episodes[-1].turns[-1].state.value == "running"
            else None
        )
        turn_roll = rng.random()
        if running_turn is not None and turn_roll < 0.85:
            turn_choice = running_turn
        elif turn_roll < 0.93:
            self.turn_counter += 1
            turn_choice = f"turn-{self.turn_counter}"
        else:
            turn_choice = current_turn if current_turn is not None else f"turn-{rng.randrange(4)}"
        weights = {
            "start_episode": 6 if not active else 1,
            "start_turn": 5 if active else 0.3,
            "accept_append": 5 if active else 0.3,
            "settle_turn": 5 if active else 0.3,
            "request_cancellation": 2,
            "settle_episode": 4 if active else 0.3,
            "close": 0.25,
            "episode_settle": 1 if episodes else 0,
            "episode_cancel": 1 if episodes else 0,
        }
        op = rng.choices(list(weights), weights=list(weights.values()))[0]
        record: dict[str, Any] = {"op": op}
        new_thread = thread
        if op == "start_episode":
            offered = None if thread.continuation is None else thread.continuation.descriptor
            fitting = [
                candidate
                for candidate in PROGRAM_POOL
                if check_continuation_compatibility(candidate, offered).compatible
            ]
            program = rng.choice(fitting) if fitting and rng.random() < 0.85 else rng.choice(PROGRAM_POOL)
            runtime = rng.choice(RUNTIMES) if rng.random() < 0.95 else rng.choice(PROGRAMS)
            budget = rng.choice(BUDGETS)
            self.episode_counter += 1
            episode_id = (
                f"episode-{self.episode_counter}"
                if rng.random() < 0.9
                else f"episode-{rng.randrange(self.episode_counter)}"
            )
            record.update(
                episode=episode_id,
                program=program.to_data(),
                runtime=runtime.to_data(),
                budget=list(budget),
            )

            def act():
                return thread.start_episode(EpisodeId(episode_id), program, runtime, EpisodeBudget(*budget))

        elif op in ("start_turn", "accept_append"):
            record.update(turn=turn_choice)

            def act():
                return getattr(thread, op)(TurnId(turn_choice))

        elif op == "settle_turn":
            outcome = rng.choice(TURN_OUTCOMES)
            record.update(turn=turn_choice, outcome=outcome.value)

            def act():
                return thread.settle_turn(TurnId(turn_choice), outcome)

        elif op == "request_cancellation":

            def act():
                result = thread.request_cancellation()
                record["disposition"] = result.disposition.value
                return result.thread

        elif op == "settle_episode":
            outcome = rng.choice(EPISODE_OUTCOMES)
            continuation = self.continuation(thread)
            record.update(
                outcome=outcome.value,
                continuation=None if continuation is None else continuation.to_data(),
            )

            def act():
                result = thread.settle_episode(outcome, continuation)
                record["disposition"] = result.disposition.value
                return result.thread

        elif op == "close":

            def act():
                return thread.close()

        elif op == "episode_settle":
            outcome = rng.choice(EPISODE_OUTCOMES)
            continuation = self.continuation(thread)
            record.update(
                outcome=outcome.value,
                continuation=None if continuation is None else continuation.to_data(),
            )
            try:
                settlement = episodes[-1].settle(outcome, continuation)
                record["result"] = {
                    "ok": dumps(settlement.episode.to_data()),
                    "disposition": settlement.disposition.value,
                }
            except (ValueError, TypeError) as error:
                record["result"] = {"error": refusal(error)}
            return record, thread
        else:  # episode_cancel
            cancellation = episodes[-1].request_cancellation()
            record["result"] = {
                "ok": dumps(cancellation.episode.to_data()),
                "disposition": cancellation.disposition.value,
            }
            return record, thread

        try:
            new_thread = act()
            result: dict[str, Any] = {"ok": dumps(new_thread.to_data())}
            if "disposition" in record:
                result["disposition"] = record.pop("disposition")
            record["result"] = result
        except (ValueError, TypeError) as error:
            record.pop("disposition", None)
            record["result"] = {"error": refusal(error)}
            new_thread = thread
        return record, new_thread


def traces(rng: random.Random, documents: dict[str, list[object]]) -> list[dict[str, Any]]:
    sessions = []
    for index in range(260):
        session = Session(rng, index)
        initial = session.continuation(None, initial=True)
        entry: dict[str, Any] = {
            "thread": session.thread_id,
            "continuation": None if initial is None else initial.to_data(),
        }
        try:
            thread = Thread(ThreadId(session.thread_id), continuation=initial)
        except (ValueError, TypeError) as error:
            entry["result"] = {"error": refusal(error)}
            entry["steps"] = []
            sessions.append(entry)
            continue
        entry["result"] = {"ok": dumps(thread.to_data())}
        steps = []
        for _ in range(rng.randrange(10, 45)):
            record, thread = session.step(thread)
            steps.append(record)
            if rng.random() < 0.12:
                harvest(thread, documents)
        entry["steps"] = steps
        sessions.append(entry)
        harvest(thread, documents)
    return sessions


def harvest(thread: Thread, documents: dict[str, list[object]]) -> None:
    documents["thread"].append(thread.to_data())
    for episode in thread.episodes:
        documents["episode"].append(episode.to_data())
        documents["budget"].append(episode.budget.to_data())
        for turn in episode.turns:
            documents["turn"].append(turn.to_data())
        for continuation in (episode.continuation, episode.next_continuation):
            if continuation is not None:
                documents["continuation"].append(continuation.to_data())
                documents["continuation_descriptor"].append(continuation.descriptor.to_data())


SCALARS: list[object] = [
    None,
    True,
    False,
    0,
    1,
    -1,
    2,
    7,
    1.0,
    "",
    " x",
    "x",
    "a\u0085",
    "open",
    "closed",
    "running",
    "settled",
    "cancelling",
    "available",
    "in-use",
    "retired",
    "completed",
    "failed",
    "cancelled",
    "budget-exhausted",
    "indeterminate",
    "program",
    "runtime",
    "continuation",
    "provider-owned",
    [],
    {},
]


def paths(value: object, prefix: tuple = ()) -> list[tuple]:
    found = [prefix]
    if isinstance(value, dict):
        for key, item in value.items():
            found.extend(paths(item, (*prefix, key)))
    elif isinstance(value, list):
        for position, item in enumerate(value):
            found.extend(paths(item, (*prefix, position)))
    return found


def get(value: object, path: tuple) -> object:
    for step in path:
        value = value[step]  # type: ignore[index]
    return value


def put(root: object, path: tuple, new: object) -> object:
    if not path:
        return new
    parent = get(root, path[:-1])
    parent[path[-1]] = new  # type: ignore[index]
    return root


SEMANTIC: dict[str, list[object]] = {
    "state": ["open", "closed", "running", "cancelling", "settled", "available", "in-use", "retired"],
    "settlement": [None, "completed", "failed", "cancelled", "budget-exhausted", "indeterminate"],
    "outcome": [None, "completed", "failed", "cancelled", "indeterminate"],
    "accepted_appends": [0, 1, 2, 3],
    "ordinal": [1, 2, 3],
    "max_turns": [1, 2],
    "max_accepted_appends": [1, 2],
    "continuation": [None],
    "next_continuation": [None],
    "expected_continuation": [None],
    "id": [],
    "thread": [],
    "episode": [],
    "turns": [[]],
    "episodes": [[]],
}


def semantic_mutation(rng: random.Random, document: object) -> object:
    candidates = [path for path in paths(document) if path and path[-1] in SEMANTIC]
    if not candidates:
        return document
    path = rng.choice(candidates)
    key = path[-1]
    same_key = [get(document, other) for other in candidates if other[-1] == key and other != path]
    pool = [*SEMANTIC[key], *same_key]
    if not pool:
        return document
    return put(document, path, copy.deepcopy(rng.choice(pool)))


def mutate(rng: random.Random, document: object) -> object:
    document = copy.deepcopy(document)
    if rng.random() < 0.55:
        for _ in range(rng.choice((1, 1, 2))):
            document = semantic_mutation(rng, document)
        return document
    for _ in range(rng.choice((1, 1, 1, 2))):
        all_paths = paths(document)
        path = rng.choice(all_paths)
        node = get(document, path)
        roll = rng.random()
        if roll < 0.4:
            document = put(document, path, copy.deepcopy(rng.choice(SCALARS)))
        elif roll < 0.65:
            donor = copy.deepcopy(get(document, rng.choice(all_paths)))
            document = put(document, path, donor)
        elif roll < 0.75 and isinstance(node, dict) and node:
            del node[rng.choice(list(node))]
        elif roll < 0.82 and isinstance(node, dict):
            node["extra"] = 1
        elif roll < 0.9 and isinstance(node, list) and node:
            node.append(copy.deepcopy(rng.choice(node)))
        elif isinstance(node, list) and len(node) > 1:
            if rng.random() < 0.5:
                node.reverse()
            else:
                node.pop(rng.randrange(len(node)))
        else:
            document = put(document, path, copy.deepcopy(rng.choice(SCALARS)))
    return document


DECODERS = {
    "thread": Thread.from_data,
    "episode": Episode.from_data,
    "turn": Turn.from_data,
    "budget": EpisodeBudget.from_data,
    "continuation": Continuation.from_data,
    "continuation_descriptor": ContinuationDescriptor.from_data,
    "program": AgentProgramDescriptor.from_data,
    "thread_id": ThreadId.from_data,
    "episode_id": EpisodeId.from_data,
    "turn_id": TurnId.from_data,
    "continuation_id": ContinuationId.from_data,
}


def decode_cases(rng: random.Random, documents: dict[str, list[object]]) -> list[dict[str, Any]]:
    documents["program"].extend(program.to_data() for program in PROGRAM_POOL)
    for name in ("thread_id", "episode_id", "turn_id", "continuation_id"):
        documents[name].extend(["x", " x", "x ", "", "a" * 256, "é" * 129, "a ", "a\x1f", "a\x7f", 1, None, True])
    cases = []
    for kind, pool in documents.items():
        unique = {dumps(item): item for item in pool}
        originals = list(unique.values())
        rng.shuffle(originals)
        originals = originals[:120]
        mutation_budget = {"thread": 700, "episode": 900, "turn": 300, "budget": 120}.get(kind, 200)
        inputs = list(originals)
        inputs.extend(document for target, document in targeted_documents() if target == kind)
        if originals and kind not in ("thread_id", "episode_id", "turn_id", "continuation_id"):
            inputs.extend(mutate(rng, rng.choice(originals)) for _ in range(mutation_budget))
        for item in inputs:
            item = json.loads(json.dumps(item))
            decoder = DECODERS[kind]

            def act(item=item, decoder=decoder):
                value = decoder(item)
                return dumps(value.to_data())

            cases.append({"kind": kind, "input": item, "result": attempt(act)})
    return cases


def targeted_documents() -> list[tuple[str, object]]:
    """Valid-shaped documents for the cross-Episode invariants random
    mutation rarely reaches."""

    a = PROGRAM_POOL[0]
    plain = PROGRAM_POOL[1]
    runtime = RUNTIMES[0]
    budget = EpisodeBudget(3, 3)
    descriptor = ContinuationDescriptor(CONTINUATIONS[0], PROGRAMS[0])

    def produced(thread: Thread, name: str) -> Continuation:
        return Continuation(ContinuationId(name), thread.id, descriptor, f"opaque:{name}")

    out: list[tuple[str, object]] = []
    # Two settled Episodes that each publish a result Continuation.
    t = Thread(ThreadId("thread-targeted"))
    t = t.start_episode(EpisodeId("e-1"), a, runtime, budget)
    t = t.settle_episode(EpisodeOutcome.COMPLETED, produced(t, "c-1")).thread
    t = t.start_episode(EpisodeId("e-2"), a, runtime, budget)
    t = t.settle_episode(EpisodeOutcome.COMPLETED, produced(t, "c-2")).thread
    data = t.to_data()
    out.append(("thread", data))
    dup = copy.deepcopy(data)
    dup["episodes"][1]["next_continuation"]["id"] = "c-1"
    dup["continuation"]["id"] = "c-1"
    out.append(("thread", dup))
    closed = t.close().to_data()
    out.append(("thread", closed))
    lost = copy.deepcopy(closed)
    lost["continuation"] = None
    out.append(("thread", lost))
    other = copy.deepcopy(closed)
    other["continuation"]["state_reference"] = "opaque:other"
    out.append(("thread", other))

    # An earlier Episode left active.
    t = Thread(ThreadId("thread-active-early"))
    t = t.start_episode(EpisodeId("e-1"), plain, runtime, budget)
    t = t.settle_episode(EpisodeOutcome.FAILED).thread
    t = t.start_episode(EpisodeId("e-2"), plain, runtime, budget)
    t = t.settle_episode(EpisodeOutcome.FAILED).thread
    data = t.to_data()
    early = copy.deepcopy(data)
    early["episodes"][0]["state"] = "running"
    early["episodes"][0]["settlement"] = None
    out.append(("thread", early))
    both = copy.deepcopy(early)
    both["episodes"][1]["state"] = "cancelling"
    both["episodes"][1]["settlement"] = None
    out.append(("thread", both))

    # A closed Thread with an active Episode, and an open one.
    t = Thread(ThreadId("thread-closed-active"))
    t = t.start_episode(EpisodeId("e-1"), plain, runtime, budget).start_turn(TurnId("u-1"))
    data = t.to_data()
    out.append(("thread", data))
    closed_active = copy.deepcopy(data)
    closed_active["state"] = "closed"
    out.append(("thread", closed_active))

    # An earlier Turn left running.
    t = t.settle_turn(TurnId("u-1"), TurnOutcome.FAILED).start_turn(TurnId("u-2"))
    t = t.settle_turn(TurnId("u-2"), TurnOutcome.COMPLETED)
    episode = t.episodes[-1].to_data()
    out.append(("episode", episode))
    early_turn = copy.deepcopy(episode)
    early_turn["turns"][0]["state"] = "running"
    early_turn["turns"][0]["outcome"] = None
    out.append(("episode", early_turn))
    two_running = copy.deepcopy(early_turn)
    two_running["turns"][1]["state"] = "running"
    two_running["turns"][1]["outcome"] = None
    out.append(("episode", two_running))
    return out


def compatibility_cases(rng: random.Random) -> list[dict[str, Any]]:
    cases = []
    descriptors = [None] + [ContinuationDescriptor(c, p) for c in CONTINUATIONS for p in PROGRAMS]
    extra = [
        AgentProgramDescriptor(PROGRAMS[0], ProgramOwnership.PROVIDER, accepts_fresh_start=False),
        AgentProgramDescriptor(
            PROGRAMS[2],
            ProgramOwnership.HARNESS,
            False,
            (ContinuationRequirement(CONTINUATIONS[0], PROGRAMS[1]), ContinuationRequirement(CONTINUATIONS[0], PROGRAMS[2])),
        ),
    ]
    for program in PROGRAM_POOL + extra:
        for descriptor in descriptors:
            result = check_continuation_compatibility(program, descriptor)
            cases.append(
                {
                    "program": program.to_data(),
                    "continuation": None if descriptor is None else descriptor.to_data(),
                    "result": dumps(result.to_data()),
                }
            )
    return cases


TEXTS = ["ok", "linux", "x86_64", "", " pad", "pad ", "a" * 256, "a" * 257, "é" * 128, "é" * 129, "a\n", "a\x7f"]
TOKENS = ["ok", "runtime.cancel", "x.y-z", "a" * 128, "a" * 129, "Bad", "a b", "", "1a", "é", "a_b", "z9"]
REFERENCES = [None, "opaque", "a" * 512, "a" * 513, "é" * 256, "", " x", "a\t"]


def runtime_cases(rng: random.Random) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {
        "components": [],
        "issues": [],
        "installations": [],
        "probes": [],
        "settlements": [],
        "cleanups": [],
        "protocol_errors": [],
        "termination_codes": [],
    }
    for _ in range(150):
        args = [rng.choice(TEXTS) for _ in range(3)]
        out["components"].append(
            {"args": args, "result": attempt(lambda args=args: [*vars(InstalledComponent(*args)).values()])}
        )
    for _ in range(150):
        args = [rng.choice(TOKENS), rng.choice([None, *TEXTS])]
        out["issues"].append(
            {"args": args, "result": attempt(lambda args=args: [ProbeIssue(*args).code, ProbeIssue(*args).component])}
        )
    valid_components = [["c-" + str(i), "1." + str(i), "pkg:c@" + str(i)] for i in range(4)] + [["c-0", "9", "pkg:other"]]
    runtimes = [RUNTIMES[0], RUNTIMES[1], PROGRAMS[0]]

    def installation_spec() -> dict[str, Any]:
        return {
            "runtime": rng.choice(runtimes).to_data(),
            "version": rng.choice([1, 1, 1, 2, 0, -1]),
            "components": rng.sample(valid_components, rng.randrange(0, 4)) if rng.random() < 0.95 else [],
            "platform": rng.choice(TEXTS) if rng.random() < 0.2 else "linux",
            "architecture": rng.choice(TEXTS) if rng.random() < 0.2 else "x86_64",
            "capabilities": rng.sample(TOKENS, rng.randrange(0, 3)) if rng.random() < 0.3 else ["runtime.cancel"],
        }

    def build_installation(spec: dict[str, Any]) -> RuntimeInstallation:
        return RuntimeInstallation(
            DescriptorIdentity.from_data(spec["runtime"]),
            spec["version"],
            tuple(InstalledComponent(*c) for c in spec["components"]),
            spec["platform"],
            spec["architecture"],
            frozenset(spec["capabilities"]),
        )

    def installation_view(installation: RuntimeInstallation) -> dict[str, Any]:
        return {
            "components": [[c.name, c.version, c.source_identity] for c in installation.components],
            "capabilities": sorted(installation.capabilities),
        }

    for _ in range(250):
        spec = installation_spec()
        out["installations"].append(
            {"args": spec, "result": attempt(lambda spec=spec: installation_view(build_installation(spec)))}
        )
    good_installations = [
        {"runtime": RUNTIMES[0].to_data(), "version": 1, "components": [valid_components[0]], "platform": "linux", "architecture": "arm64", "capabilities": []},
        {"runtime": RUNTIMES[1].to_data(), "version": 2, "components": valid_components[1:3], "platform": "darwin", "architecture": "arm64", "capabilities": ["runtime.cancel"]},
    ]
    issue_pool = [["version-mismatch", "c-0"], ["client-not-installed", "c-1"], ["service-unavailable", None], ["a.b", "z"]]
    for _ in range(300):
        runtime = rng.choice(runtimes[:2] + [RUNTIMES[2]])
        disposition = rng.choice(list(ProbeDisposition))
        installation = rng.choice([None, *good_installations])
        issues = rng.sample(issue_pool, rng.randrange(0, 3))
        if rng.random() < 0.1 and issues:
            issues.append(issues[0])
        spec = {
            "runtime": runtime.to_data(),
            "disposition": disposition.value,
            "installation": installation,
            "issues": issues,
        }

        def probe(spec=spec):
            result = RuntimeProbeResult(
                DescriptorIdentity.from_data(spec["runtime"]),
                ProbeDisposition(spec["disposition"]),
                None if spec["installation"] is None else build_installation(spec["installation"]),
                tuple(ProbeIssue(*issue) for issue in spec["issues"]),
            )
            return {
                "issues": [[issue.code, issue.component] for issue in result.issues],
                "installation": result.installation is not None,
            }

        out["probes"].append({"args": spec, "result": attempt(probe)})
    for _ in range(250):
        spec = {
            "outcome": rng.choice(TURN_OUTCOMES).value,
            "accepted_appends": rng.choice([0, 1, 1, 2, -1]),
            "termination_code": rng.choice(TOKENS),
            "output_reference": rng.choice(REFERENCES),
            "continuation_reference": rng.choice(REFERENCES),
        }

        def settlement(spec=spec):
            result = RuntimeTurnSettlement(
                EpisodeId("episode-1"),
                TurnId("turn-1"),
                TurnOutcome(spec["outcome"]),
                spec["accepted_appends"],
                spec["termination_code"],
                spec["output_reference"],
                spec["continuation_reference"],
            )
            return [result.termination_code, result.output_reference, result.continuation_reference]

        out["settlements"].append({"args": spec, "result": attempt(settlement)})
    for _ in range(150):
        spec = {
            "operation_id": rng.choice(TEXTS),
            "disposition": rng.choice(list(RuntimeCleanupDisposition)).value,
            "code": rng.choice(TOKENS),
            "physical_erasure_guaranteed": rng.random() < 0.5,
        }

        def cleanup(spec=spec):
            result = RuntimeOperationCleanup(
                spec["operation_id"],
                RuntimeCleanupDisposition(spec["disposition"]),
                spec["code"],
                spec["physical_erasure_guaranteed"],
            )
            return result.verified

        out["cleanups"].append({"args": spec, "result": attempt(cleanup)})
    for code in TOKENS:
        out["protocol_errors"].append({"code": code, "result": attempt(lambda code=code: str(RuntimeProtocolError(code)))})
        out["termination_codes"].append({"code": code, "result": attempt(lambda code=code: safe_termination_code(code))})
    return out


def main() -> None:
    rng = random.Random(SEED)
    documents: dict[str, list[object]] = {kind: [] for kind in DECODERS}
    corpus = {
        "seed": SEED,
        "traces": traces(rng, documents),
    }
    corpus["decode"] = decode_cases(rng, documents)
    corpus["compatibility"] = compatibility_cases(rng)
    corpus["runtime"] = runtime_cases(rng)
    out = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent) / OUT_NAME
    out.write_text(json.dumps(corpus, ensure_ascii=True) + "\n")
    steps = sum(len(trace["steps"]) for trace in corpus["traces"])
    refused = sum(
        1 for trace in corpus["traces"] for step in trace["steps"] if "error" in step["result"]
    )
    print(f"traces={len(corpus['traces'])} steps={steps} refused={refused} decode={len(corpus['decode'])}")


if __name__ == "__main__":
    main()
