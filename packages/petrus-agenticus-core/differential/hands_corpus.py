"""Generate the Hands differential corpus from the reference implementation.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/differential/hands_corpus.py

The script writes ``hands_corpus.json`` next to itself (or into the directory given as its first argument). It records:

- ``requests``: ``parse_tool_request`` cases (valid and invalid on every
  axis: envelope shape, version, method, params keys, every bound at its
  limit and one past it in code points and UTF-8 bytes, Unicode whitespace
  and control characters, DEL, NUL, wrong JSON types, floats and booleans
  for integers, path/argv/cwd traversal) with either the normalized request
  or the rejection (category, detail, ``str(error)``) plus the gateway's
  salvaged ``(call_id, episode_id)``;
- ``results``: ``ToolResult``/``ToolError`` construction cases with the
  exact ``json.dumps`` bytes of ``to_data()`` and ``to_model_data()`` or the
  refusal (class and message);
- ``grants``: ``CapabilityGrant`` construction cases with every
  ``permits`` and ``permits_write_path`` decision over a fixed probe set, or
  the refusal;
- ``sessions``: scripted single-threaded gateway sessions over a
  deterministic adapter (fence, grant, clock and target changes interleaved
  with submissions, retransmissions and conflicts) with every step's outcome
  and the final counters and evidence.

``HandsDifferentialSpec`` replays every case in Haskell and asserts the same
bytes, decisions and refusals.
"""

from __future__ import annotations

import hashlib
import json
import sys
import random
from pathlib import Path
from threading import RLock

from petrus.agenticus.hands.contract import (
    RejectionCategory,
    ToolError,
    ToolMethod,
    ToolRequestRejected,
    ToolResult,
    parse_tool_request,
)
from petrus.agenticus.hands.gateway import (
    CallFence,
    HandsGateway,
    ShellOutcome,
    StagedWrite,
    TestOutcome,
    _salvaged_identity,
)
from petrus.agenticus.hands.grants import CapabilityGrant, GrantLedger

HERE = Path(__file__).resolve().parent
METHODS = [method.value for method in ToolMethod]


def refusal(error: BaseException) -> dict[str, str]:
    return {"class": type(error).__name__, "message": str(error)}


def normalized(request) -> dict[str, object]:
    params = request.params
    if request.method is ToolMethod.WORKSPACE_READ:
        data = {"path": params.path}
    elif request.method is ToolMethod.WORKSPACE_SEARCH:
        data = {"query": params.query, "path": params.path}
    elif request.method is ToolMethod.WORKSPACE_SHELL:
        data = {"argv": list(params.argv), "cwd": params.cwd}
    elif request.method is ToolMethod.WORKSPACE_WRITE:
        data = {"path": params.path, "content": params.content}
    else:
        data = {}
    return {
        "version": 1,
        "call_id": request.call_id,
        "episode_id": request.episode_id,
        "attachment_id": request.attachment_id,
        "attachment_epoch": request.attachment_epoch,
        "grant_epoch": request.grant_epoch,
        "method": request.method.value,
        "params": data,
    }


def base(method: str, params: dict[str, object]) -> dict[str, object]:
    return {
        "version": 1,
        "call_id": "call-1",
        "episode_id": "episode-1",
        "attachment_id": "attachment-1",
        "attachment_epoch": 1,
        "grant_epoch": 1,
        "method": method,
        "params": params,
    }


VALID_PARAMS: dict[str, dict[str, object]] = {
    "workspace_read": {"path": "README.md"},
    "workspace_search": {"query": "needle", "path": "src/a.txt"},
    "workspace_shell": {"argv": ["printf", "ok"], "cwd": "."},
    "workspace_write": {"path": "out.txt", "content": "safe"},
    "workspace_test": {},
}

# Text probes: bounds at the limit and one past it, in code points and bytes.
TEXTS = [
    "",
    " ",
    "a",
    " a",
    "a ",
    " a",
    "a ",
    "\u0085a",
    "a　",
    "​a",
    "﻿a",
    "a\tb",
    "a\x1fb",
    "a\x7fb",
    "a\x00b",
    "é" * 8,
    "é" * 9,
    "x" * 8,
    "x" * 9,
    "x" * 63,
    "x" * 64,
    "x" * 65,
    "é" * 64,
    "é" * 65,
    "𝄞" * 64,
    "𝄞" * 65,
    "é" * 128,
    "é" * 129,
    "x" * 256,
    "x" * 257,
    "日本語",
    "a/b",
    "a//b",
    "/a",
    "a/",
    "./a",
    "a/.",
    "a/./b",
    "a/../b",
    "..",
    ".",
    "a\\b",
    ".hidden",
    "...",
    "a/..b",
    "-rf",
]

NON_STRINGS: list[object] = [None, True, False, 0, 1, -1, 1.0, 1.5, [], ["a"], {}, {"a": 1}]
INTEGERS: list[object] = [0, 1, 2, -1, 10**30, 1.0, 2.5, True, False, None, "1", [1]]


def request_cases(rng: random.Random) -> list[tuple[str, object]]:
    cases: list[tuple[str, object]] = []
    for method, params in VALID_PARAMS.items():
        cases.append((f"valid {method}", base(method, dict(params))))
        cases.append((f"extra envelope {method}", {**base(method, dict(params)), "extra": True}))
        cases.append((f"extra param {method}", base(method, {**params, "extra": 1})))
        for key in params:
            cases.append((f"missing param {method}.{key}", base(method, {k: v for k, v in params.items() if k != key})))
        cases.append((f"params not object {method}", base(method, [])))
        cases.append((f"params null {method}", base(method, None)))
    for key in ["version", "call_id", "episode_id", "attachment_id", "attachment_epoch", "grant_epoch", "method", "params"]:
        data = base("workspace_read", {"path": "a"})
        del data[key]
        cases.append((f"missing envelope {key}", data))
    for value in [0, 2, 1.0, True, "1", None]:
        cases.append((f"version {value!r}", {**base("workspace_read", {"path": "a"}), "version": value}))
    for value in ["future_tool", "", "WORKSPACE_READ", "workspace_read ", 1, None, ["workspace_read"]]:
        cases.append((f"method {value!r}", {**base("workspace_read", {"path": "a"}), "method": value}))
    for value in [None, [], "x", 1, True]:
        cases.append((f"envelope {value!r}", value))
    cases.append(("canary envelope", {"call_id": "SECRET-CANARY"}))
    cases.append(("empty envelope", {}))
    for name in ["call_id", "episode_id", "attachment_id"]:
        for text in TEXTS:
            cases.append((f"{name} {text!r}", {**base("workspace_read", {"path": "a"}), name: text}))
        for value in NON_STRINGS:
            cases.append((f"{name} {value!r}", {**base("workspace_read", {"path": "a"}), name: value}))
    for name in ["attachment_epoch", "grant_epoch"]:
        for value in INTEGERS:
            cases.append((f"{name} {value!r}", {**base("workspace_read", {"path": "a"}), name: value}))
    for text in TEXTS:
        cases.append((f"read path {text!r}", base("workspace_read", {"path": text})))
        cases.append((f"search query {text!r}", base("workspace_search", {"query": text, "path": "a"})))
        cases.append((f"search path {text!r}", base("workspace_search", {"query": "q", "path": text})))
        cases.append((f"write path {text!r}", base("workspace_write", {"path": text, "content": "c"})))
        cases.append((f"shell argv part {text!r}", base("workspace_shell", {"argv": ["printf", text], "cwd": "."})))
        cases.append((f"shell cwd {text!r}", base("workspace_shell", {"argv": ["printf"], "cwd": text})))
    for value in NON_STRINGS:
        cases.append((f"read path {value!r}", base("workspace_read", {"path": value})))
        cases.append((f"search query {value!r}", base("workspace_search", {"query": value, "path": "a"})))
        cases.append((f"search query+path {value!r}", base("workspace_search", {"query": value, "path": "../x"})))
        cases.append((f"write content {value!r}", base("workspace_write", {"path": "a", "content": value})))
        cases.append((f"shell argv {value!r}", base("workspace_shell", {"argv": value, "cwd": "."})))
        cases.append((f"shell argv item {value!r}", base("workspace_shell", {"argv": ["a", value], "cwd": "."})))
        cases.append((f"shell cwd {value!r}", base("workspace_shell", {"argv": ["a"], "cwd": value})))
    for count in [0, 1, 4, 5, 9]:
        cases.append((f"shell {count} parts", base("workspace_shell", {"argv": ["x"] * count, "cwd": "."})))
    cases.append(("shell 5 bad parts", base("workspace_shell", {"argv": ["a\x00"] * 5, "cwd": "."})))
    cases.append(("shell bad part and bad cwd", base("workspace_shell", {"argv": ["a/../b"], "cwd": "/"})))
    cases.append(("shell bad part 2", base("workspace_shell", {"argv": ["ok", "x" * 65, "a\x00"], "cwd": "."})))
    for content in ["", "x" * 1024, "x" * 1025, "é" * 1024, "é" * 1025, "𝄞" * 1024, "a\x00b", "\x00" * 2000, "line\nnext\ttab\x7f", "x" * 2000]:
        cases.append((f"write content len {len(content)} {content[:4]!r}", base("workspace_write", {"path": "a", "content": content})))
    cases.append(("write bad path and bad content", base("workspace_write", {"path": "/a", "content": None})))
    cases.append(("search bad query and bad path", base("workspace_search", {"query": "\x00", "path": "/a"})))
    cases.append(("bad params and bad identity", {**base("workspace_read", {"path": "/a"}), "call_id": ""}))
    cases.append(("bad identity and bad epoch", {**base("workspace_read", {"path": "a"}), "call_id": "", "grant_epoch": 0}))
    cases.append(("bad epoch order", {**base("workspace_read", {"path": "a"}), "attachment_epoch": 0, "grant_epoch": 0}))
    cases.append(("unknown method bad params", {**base("future", {"path": "a"}), "params": None}))
    cases.append(("bad version bad method", {**base("future", {}), "version": 2}))
    # Random mixtures: a valid request with one to three random field swaps.
    pool: list[object] = TEXTS + NON_STRINGS + INTEGERS
    for index in range(300):
        method = rng.choice(METHODS)
        data = base(method, dict(VALID_PARAMS[method]))
        for _ in range(rng.randint(1, 3)):
            if rng.random() < 0.6 and isinstance(data["params"], dict) and data["params"]:
                params = dict(data["params"])
                key = rng.choice(sorted(params))
                if key == "argv" and rng.random() < 0.7:
                    params[key] = [rng.choice(TEXTS) for _ in range(rng.randint(0, 6))]
                else:
                    params[key] = rng.choice(pool)
                data["params"] = params
            else:
                key = rng.choice(sorted(data))
                data[key] = rng.choice(pool) if key != "method" else rng.choice(METHODS + ["nope", 3])
        cases.append((f"random {index}", data))
    return cases


def request_corpus(rng: random.Random) -> list[dict[str, object]]:
    out = []
    for label, data in request_cases(rng):
        call_id, episode_id = _salvaged_identity(data)
        try:
            outcome: dict[str, object] = {"request": normalized(parse_tool_request(data))}
        except ToolRequestRejected as rejected:
            outcome = {
                "rejected": {
                    "category": rejected.category.value,
                    "detail": rejected.detail,
                    "message": str(rejected),
                }
            }
        out.append({"label": label, "input": data, "outcome": outcome, "salvage": [call_id, episode_id]})
    return out


def result_corpus(rng: random.Random) -> list[dict[str, object]]:
    datas: list[object] = [
        None,
        {},
        {"content": "safe"},
        {"content": "é" * 2048},
        {"content": "é" * 2049},
        {"content": "x" * 4096},
        {"content": "x" * 4097},
        {"matches": ["a", "b"]},
        {"nested": {"deep": [1, True, None, "x" * 4097]}},
        {"nested": {"deep": [1, 2.5]}},
        {"float": 1.0},
        {"first": 1.5, "second": "x" * 5000},
        {"first": "x" * 5000, "second": 1.5},
        {"unicode": "日本語   \x00 \x7f", "big": 10**40, "neg": -3},
        {"returncode": 0, "stdout": "ok\n", "stderr": "", "truncated": False},
    ]
    errors: list[object] = [
        None,
        ["provider", "provider operation failed"],
        ["schema", "request requires its exact version-1 envelope fields"],
        ["budget", "x" * 128],
        ["budget", "x" * 129],
        ["path", "é" * 64],
        ["path", "é" * 65],
        ["argv", ""],
        ["argv", " padded"],
        ["argv", "tab\there"],
        ["argv", "del\x7fok"],
        ["write", " nbsp"],
    ]
    identities = ["call-1", "", " x", "é" * 128, "é" * 129, "a\x1fb", "a\x7fb", "\u0085x", "unparsed-request"]
    out = []
    cases: list[tuple[str, str, object, bool, object, object]] = []
    for data in datas:
        cases.append(("call-1", "attachment-1", 1, True, data, None))
        cases.append(("call-1", "attachment-1", 1, False, data, None))
    for error in errors:
        cases.append(("call-1", "attachment-1", 1, False, None, error))
        cases.append(("call-1", "attachment-1", 1, True, None, error))
    for _ in range(40):
        cases.append(("call-1", "attachment-1", 1, rng.random() < 0.5, rng.choice(datas), rng.choice(errors)))
    for identity in identities:
        cases.append((identity, "attachment-1", 1, True, {"x": 1}, None))
        cases.append(("call-1", identity, 1, False, None, ["provider", "provider operation failed"]))
    for epoch in [0, -1, 1, 2, 10**20]:
        cases.append(("call-1", "attachment-1", epoch, True, {"x": 1}, None))
    for _ in range(60):
        cases.append(
            (
                rng.choice(identities),
                rng.choice(identities),
                rng.choice([0, 1, 7]),
                rng.random() < 0.5,
                rng.choice(datas),
                rng.choice(errors),
            )
        )
    for call_id, attachment_id, epoch, ok, data, error in cases:
        case = {
            "call_id": call_id,
            "attachment_id": attachment_id,
            "epoch": epoch,
            "ok": ok,
            "data": data,
            "error": error,
        }
        try:
            tool_error = None if error is None else ToolError(RejectionCategory(error[0]), error[1])
            result = ToolResult(call_id, attachment_id, epoch, ok, data, tool_error)
            outcome: dict[str, object] = {
                "to_data": json.dumps(result.to_data()),
                "model": json.dumps(result.to_model_data()),
            }
        except (TypeError, ValueError, AssertionError) as error_:
            outcome = {"error": refusal(error_)}
        out.append({"input": case, "outcome": outcome})
    return out


WRITE_PROBES = [
    "out.txt",
    "src",
    "src/new.txt",
    "src2/new.txt",
    "src/deep/x.txt",
    ".git",
    ".git/config",
    ".gitignore",
    "docs/a.md",
    "a",
    "a/b",
    "ab",
    ".",
    "",
]


def grant_cases(rng: random.Random) -> list[dict[str, object]]:
    good = {
        "attachment_id": "attachment-1",
        "attachment_epoch": 1,
        "grant_epoch": 1,
        "capabilities": ["workspace_read", "workspace_write"],
        "writable_paths": ["out.txt", ".git/config"],
        "allowed_argv": [["printf", "ok"]],
        "deadline": 50.0,
        "max_calls": 3,
        "writable_roots": ["src"],
        "denied_writable_roots": [".git"],
    }
    variants: list[tuple[str, object]] = [
        ("attachment_id", ""),
        ("attachment_id", " a"),
        ("attachment_id", "é" * 129),
        ("attachment_epoch", 0),
        ("grant_epoch", -1),
        ("max_calls", 0),
        ("deadline", "inf"),
        ("deadline", "-inf"),
        ("deadline", "nan"),
        ("deadline", 0),
        ("deadline", -5.5),
        ("deadline", 1e300),
        ("capabilities", []),
        ("capabilities", METHODS),
        ("writable_paths", []),
        ("writable_paths", ["x" * 64]),
        ("writable_paths", ["x" * 65]),
        ("writable_paths", ["é" * 64]),
        ("writable_paths", ["/abs"]),
        ("writable_paths", ["a/../b"]),
        ("writable_paths", ["a//b"]),
        ("writable_paths", ["a\\b"]),
        ("writable_paths", ["."]),
        ("writable_paths", [""]),
        ("writable_paths", [" a"]),
        ("writable_paths", ["a\x7f"]),
        ("writable_paths", ["a\x01"]),
        ("writable_roots", ["."]),
        ("writable_roots", ["src", "docs"]),
        ("writable_roots", ["../foreign"]),
        ("writable_roots", [".."]),
        ("writable_roots", []),
        ("denied_writable_roots", ["."]),
        ("denied_writable_roots", []),
        ("denied_writable_roots", ["src"]),
        ("denied_writable_roots", ["/x"]),
        ("allowed_argv", []),
        ("allowed_argv", [[]]),
        ("allowed_argv", [["a"] * 4]),
        ("allowed_argv", [["a"] * 5]),
        ("allowed_argv", [["x" * 64]]),
        ("allowed_argv", [["x" * 65]]),
        ("allowed_argv", [["a\\b"]]),
        ("allowed_argv", [["a/./b"]]),
        ("allowed_argv", [["a//b"]]),
        ("allowed_argv", [["/bin/cat", "message.txt"]]),
        ("allowed_argv", [["a\x7f"]]),
        ("allowed_argv", [["a\x1f"]]),
        ("allowed_argv", [[""]]),
        ("allowed_argv", [[" padded "]]),
    ]
    cases = [good] + [{**good, key: value} for key, value in variants]
    for _ in range(80):
        case = dict(good)
        for key, value in rng.sample(variants, rng.randint(1, 3)):
            case[key] = value
        cases.append(case)
    return cases


def deadline_value(value: object) -> object:
    return float(value) if isinstance(value, str) else value


def grant_corpus(rng: random.Random) -> list[dict[str, object]]:
    out = []
    for case in grant_cases(rng):
        try:
            grant = CapabilityGrant(
                case["attachment_id"],
                case["attachment_epoch"],
                case["grant_epoch"],
                frozenset(ToolMethod(m) for m in case["capabilities"]),
                frozenset(case["writable_paths"]),
                frozenset(tuple(command) for command in case["allowed_argv"]),
                deadline_value(case["deadline"]),
                case["max_calls"],
                writable_roots=frozenset(case["writable_roots"]),
                denied_writable_roots=frozenset(case["denied_writable_roots"]),
            )
            outcome: dict[str, object] = {
                "permits": [grant.permits(ToolMethod(m)) for m in METHODS],
                "permits_write_path": [grant.permits_write_path(p) for p in WRITE_PROBES],
                "deadline": grant.deadline,
            }
        except (TypeError, ValueError) as error:
            outcome = {"error": refusal(error)}
        out.append({"input": case, "outcome": outcome})
    return {"write_probes": WRITE_PROBES, "cases": out}


# ---------------------------------------------------------------------------
# Gateway sessions


class SessionAdapter:
    """Deterministic adapter; special path prefixes trigger failure modes.

    ``late``, ``closing`` (reads) and ``abort``, ``regrant`` (stages) change
    the clock, fence or grant while the call is inside the adapter, so the
    postcheck sees the change.
    """

    def __init__(self, state: SessionState, ledger: GrantLedger) -> None:
        self.stages: dict[str, str] = {}
        self.state = state
        self.ledger = ledger

    def read(self, path: str) -> str:
        if path.startswith("boom"):
            raise RuntimeError("SECRET")
        if path.startswith("big"):
            return "x" * 5000
        if path.startswith("late"):
            self.state.clock = 500.0
        if path.startswith("closing"):
            fence = self.state.fence
            self.state.fence = CallFence(False, fence.aborted, fence.deadline)
        return f"content:{path}"

    def search(self, query: str, path: str) -> tuple[str, ...]:
        if query == "many":
            return tuple(f"m{i}" for i in range(65))
        if path.startswith("boom"):
            raise RuntimeError("SECRET")
        return (f"{query}@{path}",)

    def shell(self, argv: tuple[str, ...], cwd: str) -> ShellOutcome:
        if argv[0] == "fail":
            raise RuntimeError("SECRET")
        return ShellOutcome(len(argv), " ".join(argv), cwd, False)

    def stage_write(self, call_id: str, path: str, content: str) -> StagedWrite:
        if path.startswith("boom"):
            raise RuntimeError("SECRET")
        digest = hashlib.sha256(content.encode()).hexdigest()
        self.stages[call_id] = content
        if path.startswith("abort"):
            fence = self.state.fence
            self.state.fence = CallFence(fence.open, True, fence.deadline)
        if path.startswith("regrant"):
            grant = self.ledger.current()
            if grant is not None:
                self.ledger.open(
                    grant.capabilities,
                    writable_paths=grant.writable_paths,
                    writable_roots=grant.writable_roots,
                    denied_writable_roots=grant.denied_writable_roots,
                    allowed_argv=grant.allowed_argv,
                    deadline=grant.deadline,
                    max_calls=grant.max_calls,
                )
        if path.startswith("skew"):
            return StagedWrite(call_id, path + "x", digest)
        return StagedWrite(call_id, path, digest)

    def commit_write(self, staged: StagedWrite) -> str:
        if staged.path.startswith("crash") or staged.path.startswith("nodiscard"):
            raise RuntimeError("SECRET")
        self.stages.pop(staged.call_id, None)
        if staged.path.startswith("bad"):
            return "0" * 64
        return staged.digest

    def discard_write(self, staged: StagedWrite) -> None:
        if staged.path.startswith("nodiscard"):
            raise RuntimeError("SECRET")
        self.stages.pop(staged.call_id, None)

    def run_test(self) -> TestOutcome:
        return TestOutcome(len(self.stages) == 0, "e" * 64)

    def discard_all_stages(self) -> int:
        count = len(self.stages)
        self.stages.clear()
        return count


class SessionState:
    def __init__(self) -> None:
        self.fence = CallFence(True, False, 100.0)
        self.clock = 1.0
        self.target = True

    def snapshot(self) -> CallFence:
        return self.fence

    def is_current(self) -> bool:
        return self.target


class SessionAdmission:
    def admit(self, call_id: str) -> bool:
        return "deny" not in call_id


SESSION_PATHS = [
    "out.txt",
    "src/a.txt",
    "src2/b.txt",
    ".git/config",
    "docs/x.md",
    "boom/x",
    "big/x",
    "skew/x",
    "bad/x",
    "crash/x",
    "nodiscard/x",
    "late/x",
    "closing/x",
    "abort/x",
    "regrant/x",
    "../escape",
]
SESSION_ARGV = [["printf", "ok"], ["/bin/cat", "message.txt"], ["fail"], ["printf", "no"]]
CALL_IDS = ["c1", "c2", "c3", "c4", "deny-1", "c5", "c6", "c7", "c8", "c9"]


def session_request(rng: random.Random, grant_epoch: int, history: list[object], serial: list[int]) -> object:
    roll = rng.random()
    if history and roll < 0.15:
        return json.loads(json.dumps(rng.choice(history)))
    method = rng.choice(METHODS)
    path = rng.choice(SESSION_PATHS)
    if method == "workspace_read":
        params: dict[str, object] = {"path": path}
    elif method == "workspace_search":
        params = {"query": rng.choice(["needle", "needle", "many"]), "path": path}
    elif method == "workspace_shell":
        params = {"argv": list(rng.choice(SESSION_ARGV)), "cwd": rng.choice([".", ".", "src", "a/../b"])}
    elif method == "workspace_write":
        params = {"path": rng.choice([path, "out.txt", "skew/x", "bad/x", "crash/x", "nodiscard/x", "src/w.txt", "abort/x", "regrant/x"]), "content": rng.choice(["v1", "v2", "é" * 3])}
    else:
        params = {}
    if history and roll < 0.2:
        call_id = rng.choice(history)["call_id"]
    else:
        serial[0] += 1
        call_id = f"c{serial[0]}" if rng.random() < 0.95 else f"deny-{serial[0]}"
    data = {
        "version": 1,
        "call_id": call_id,
        "episode_id": "episode-1" if rng.random() < 0.95 else "episode-2",
        "attachment_id": "attachment-1" if rng.random() < 0.97 else "attachment-2",
        "attachment_epoch": 3 if rng.random() < 0.97 else 4,
        "grant_epoch": grant_epoch if rng.random() < 0.9 else max(1, grant_epoch - 1),
        "method": method,
        "params": params,
    }
    roll = rng.random()
    if roll < 0.03:
        data["version"] = 2
    elif roll < 0.05:
        data["method"] = "nope"
    elif roll < 0.06:
        return ["not", "an", "object"]
    history.append(data)
    return data


def grant_op(rng: random.Random) -> dict[str, object]:
    return {
        "op": "grant",
        "capabilities": sorted(rng.sample(METHODS, rng.choice([0, 2, 4, 5, 5, 5, 5, 5]))),
        "writable_paths": rng.sample(["out.txt", "skew/x", "bad/x", "crash/x", "nodiscard/x", "boom/x"], rng.randint(0, 4)),
        "writable_roots": rng.choice([[], ["src"], ["."], ["."], ["."]]),
        "denied_writable_roots": rng.choice([[], [".git"], ["src"]]),
        "allowed_argv": rng.sample(SESSION_ARGV, rng.randint(0, 4)),
        "deadline": rng.choice([50, 90.5, 90.5, 2]),
        "max_calls": rng.choice([1, 5, 40, 40, 40]),
    }


def counters_data(counters) -> dict[str, object]:
    return {
        "requests": counters.requests,
        "rejections": dict(sorted(counters.rejections.items())),
        "adapter_entries": counters.adapter_entries,
        "stages": counters.stages,
        "commits": counters.commits,
        "stage_discards": counters.stage_discards,
        "stage_discard_failures": counters.stage_discard_failures,
        "target_mutations": counters.target_mutations,
        "results_admitted": counters.results_admitted,
    }


def evidence_data(evidence) -> list[dict[str, object]]:
    return [
        {
            "sequence": item.sequence,
            "call_id": item.call_id,
            "episode_id": item.episode_id,
            "method": None if item.method is None else item.method.value,
            "ok": item.ok,
            "category": None if item.category is None else item.category.value,
            "epoch": item.epoch,
        }
        for item in evidence
    ]


def run_session(rng: random.Random, index: int) -> dict[str, object]:
    state = SessionState()
    ledger = GrantLedger("attachment-1", 3)
    config = {
        "max_calls": rng.choice([8, 256, 256, 256]),
        "max_evidence": rng.choice([3, 10, 256]),
        "admission": rng.random() < 0.5,
        "target": rng.random() < 0.5,
    }
    gateway = HandsGateway(
        episode_id="episode-1",
        adapter=SessionAdapter(state, ledger),
        grants=ledger,
        fence=state,
        barrier=RLock(),
        admission=SessionAdmission() if config["admission"] else None,
        target=state if config["target"] else None,
        clock=lambda: state.clock,
        max_evidence=config["max_evidence"],
        max_calls=config["max_calls"],
    )
    steps = []
    grant_epoch = 0
    history: list[object] = []
    serial = [0]
    for position in range(45):
        roll = 0.65 if position == 0 else rng.random()
        if roll < 0.62:
            current = ledger.current()
            if current is not None:
                grant_epoch = current.grant_epoch
            op: dict[str, object] = {"op": "submit", "request": session_request(rng, grant_epoch, history, serial)}
            try:
                outcome: object = {"result": json.dumps(gateway.submit(op["request"]).to_data())}
            except Exception as error:  # noqa: BLE001 - recorded as the refusal
                outcome = {"error": refusal(error)}
        elif roll < 0.72:
            op = grant_op(rng)
            try:
                grant = ledger.open(
                    [ToolMethod(m) for m in op["capabilities"]],
                    writable_paths=op["writable_paths"],
                    writable_roots=op["writable_roots"],
                    denied_writable_roots=op["denied_writable_roots"],
                    allowed_argv=[tuple(a) for a in op["allowed_argv"]],
                    deadline=op["deadline"],
                    max_calls=op["max_calls"],
                )
                grant_epoch = grant.grant_epoch
                outcome = {"grant_epoch": grant.grant_epoch}
            except Exception as error:  # noqa: BLE001
                outcome = {"error": refusal(error)}
        elif roll < 0.80:
            op = {
                "op": "fence",
                "open": rng.random() < 0.85,
                "aborted": rng.random() < 0.1,
                "deadline": rng.choice([100.0, 100.0, 100.0, 3, 0.5]),
            }
            state.fence = CallFence(op["open"], op["aborted"], op["deadline"])
            outcome = None
        elif roll < 0.86:
            op = {"op": "clock", "value": rng.choice([1.0, 1.0, 2.5, 60.0, 95])}
            state.clock = op["value"]
            outcome = None
        elif roll < 0.90:
            op = {"op": "target", "current": rng.random() < 0.6}
            state.target = op["current"]
            outcome = None
        elif roll < 0.92:
            op = {"op": "close"}
            ledger.close()
            outcome = None
        else:
            op = {"op": "cleanup"}
            outcome = {"removed": gateway.cleanup_stages()}
        steps.append({"step": op, "outcome": outcome})
    return {
        "label": f"session {index}",
        "config": config,
        "steps": steps,
        "counters": counters_data(gateway.counters()),
        "evidence": evidence_data(gateway.evidence()),
    }


def main() -> None:
    rng = random.Random(49)
    corpus = {
        "format": "petrus-haskell.agenticus.hands-differential",
        "version": 1,
        "requests": request_corpus(rng),
        "results": result_corpus(rng),
        "grants": grant_corpus(rng),
        "sessions": [run_session(rng, index) for index in range(50)],
    }
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE
    (out / "hands_corpus.json").write_text(json.dumps(corpus, indent=1, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
