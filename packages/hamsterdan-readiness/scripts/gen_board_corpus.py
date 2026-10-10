"""Generate the board corpus for hamsterdan-readiness.

Run from the repository root against the pinned upstream environment:

    PYTHONDONTWRITEBYTECODE=1 upstream/hamsterdan/.venv/bin/python -I \
        packages/hamsterdan-readiness/scripts/gen_board_corpus.py

Writes test/corpus/board.jsonl, one row per entry log:

    {"entries": [...], "board": render_board(entries) | "board_error": text,
     "facts": repr(gate_facts(entries)) | "facts_error": text}

where text is petrus's firing_failure_text(exc), the string the dashboard
gate would record. The logs are the upstream test scenarios plus seeded
random logs mixing well-formed facts, hostile field values (wrong types,
numeric strings, floats, nested containers, unicode), and unparseable
entries.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

from petrus.impetus.instance import firing_failure_text

from hamsterdan.readiness.net_v5.board import gate_facts, render_board

OUT = Path(__file__).resolve().parents[1] / "test" / "corpus" / "board.jsonl"
RANDOM_LOGS = 1500

HEAD = "3ff7d1067d8437340e39d2ad38c06ab4631a7c4f"
BASE = "a83e9223f7ffc6b0af919b0b8261fa2578261b41"
POLICY = "196b38f86f32afff0e606bcb9a3e36647bc0bdd1b82a3818fe412c38a2ccc25b"

FIELDS = {
    "state": ["phase", "head", "base", "mergeable", "policy", "strict_base", "base_current"],
    "checks": ["status"],
    "review": ["head", "status", "category"],
    "findings": ["head", "blocking", "count"],
    "human": ["approval", "changes_requested", "unresolved"],
    "announced": ["head"],
    "fault": ["where", "op", "status", "reason"],
    "mutation_pending": ["op", "op_key"],
    "mutation_settled": ["op", "op_key", "outcome"],
    "human_needed": ["fingerprint", "head"],
    "dash": ["entries"],
}

TYPICAL = {
    "phase": ["running", "quiescent", "terminal", "starting"],
    "head": [HEAD, "h1", "h2", ""],
    "base": [BASE, "b1", ""],
    "policy": [POLICY, "p1"],
    "status": ["pending", "queued", "in_progress", "success", "failure", "clear", "blocking", "unable", "faulted", "resolved", "cancelled", "weird"],
    "category": ["unable", "", "timeout", "refused"],
    "where": ["review", "mutation", "rerun", "announce"],
    "op": ["op-1", "op-2", "repair", "change", "rerun:L1:fp1"],
    "op_key": ["k1", "k2", "push:comment:c1:h1:i1"],
    "outcome": ["landed", "moved"],
    "reason": ["timeout", "unknown provider terminal", ""],
    "fingerprint": ["deadbeef99", "fp1", ""],
}

HOSTILE = [
    None,
    True,
    False,
    0,
    1,
    2,
    3,
    -1,
    10**20,
    1.5,
    0.0,
    -2.25,
    1e300,
    "",
    "0",
    "3",
    " 4 ",
    "1_0",
    "+5",
    "x",
    "1.5",
    "٣",
    "é",
    "emoji\U0001f600",
    "tab\there",
    "quote'\"",
    [],
    [1, "a"],
    (),
    (1, 2),
    {},
    {"nested": 1},
    {1: "int key"},
]


def value_for(field: str, rng: random.Random):
    if rng.random() < 0.7:
        if field in TYPICAL:
            return rng.choice(TYPICAL[field])
        if field in ("mergeable", "strict_base", "base_current", "approval", "changes_requested"):
            return rng.choice([True, False])
        if field in ("blocking", "count", "unresolved"):
            return rng.choice([0, 1, 2, 3])
    return rng.choice(HOSTILE)


def body_for(kind: str, rng: random.Random) -> dict:
    fields = FIELDS.get(kind, ["head", "status"])
    chosen = [f for f in fields if rng.random() < 0.85]
    if rng.random() < 0.1:
        chosen.append(rng.choice(["extra", "status", "head", 7]))
    rng.shuffle(chosen) if rng.random() < 0.2 else None
    return {f: value_for(f, rng) if isinstance(f, str) else "x" for f in chosen}


MALFORMED = [
    "garbage-without-structure",
    "",
    ":",
    "state:",
    "state:not a literal",
    "state:[1, 2]",
    "state:(1,)",
    "state:'text'",
    "state:{1, 2}",
    "state:b'bytes'",
    "state:{'head': 'h1',}",
    "state: {'head': 'h1'}",
    "checks:{'status': 'success'} # comment",
    "checks:{\"status\": \"failure\"}",
    "state:{'head': 0x1f}",
    "state:{[1]: 2}",
    "state:{'a': {[1]: 2}}",
    "findings:{'blocking': 1_000, 'count': 2}",
    "human:{'unresolved': -0}",
    "review:{'status': 'clear', 'status': 'blocking'}",
    "fault:{'where': 'review', 'op': 'o', 'reason': 'r\\n'}",
    "state:{'phase': 'running', 'head': 'h' 'concat'}",
    "x:y:{'status': 'success'}",
]


def entry(kind: str, body: dict) -> str:
    return f"{kind}:{body}"


def random_log(rng: random.Random) -> list[str]:
    kinds = list(FIELDS) + ["unknown"]
    log = []
    if rng.random() < 0.8:
        log.append(entry("state", body_for("state", rng)))
    for _ in range(rng.randint(0, 9)):
        if rng.random() < 0.08:
            log.append(rng.choice(MALFORMED))
        else:
            kind = rng.choice(kinds)
            log.append(entry(kind, body_for(kind, rng)))
    return log


def state(**overrides) -> str:
    body = {
        "phase": "running",
        "head": HEAD,
        "base": BASE,
        "mergeable": True,
        "policy": POLICY,
        "strict_base": True,
        "base_current": True,
    }
    body.update(overrides)
    return f"state:{body}"


def scenarios() -> list[list[str]]:
    human = lambda a=False, c=False, u=0: f"human:{ {'approval': a, 'changes_requested': c, 'unresolved': u} }"  # noqa: E731
    checks = lambda s: f"checks:{ {'status': s} }"  # noqa: E731
    fault = f"fault:{ {'where': 'review', 'op': 'op-1', 'status': 'faulted', 'reason': 'timeout'} }"
    resolved = f"fault:{ {'where': 'review', 'op': 'op-1', 'status': 'resolved'} }"
    escalation = f"human_needed:{ {'fingerprint': 'deadbeef99', 'head': HEAD} }"
    pending = f"mutation_pending:{ {'op': 'repair', 'op_key': 'k1'} }"
    settled = f"mutation_settled:{ {'op': 'repair', 'op_key': 'k1'} }"
    return [
        [],
        [state()],
        [state(), human(), checks("pending"), checks("queued"), checks("in_progress")],
        [state(), checks("failure")],
        [
            state(),
            checks("success"),
            f"findings:{ {'head': HEAD, 'blocking': 2, 'count': 3} }",
            f"review:{ {'head': HEAD, 'status': 'blocking'} }",
        ],
        [state(), checks("success"), human(c=True, u=2)],
        [state(), checks("success"), human(a=True, u=1)],
        [state(base_current=False), checks("success")],
        [state(mergeable=False), checks("success")],
        [
            state(),
            human(a=True),
            checks("success"),
            f"findings:{ {'head': HEAD, 'blocking': 0, 'count': 0} }",
            f"review:{ {'head': HEAD, 'status': 'clear'} }",
            f"announced:{ {'head': HEAD} }",
        ],
        [state(phase="quiescent")],
        [state(phase="terminal")],
        [state(), fault],
        [state(), fault, resolved],
        [state(), checks("failure"), escalation],
        [state(), checks("failure"), escalation, checks("success")],
        [state(), pending],
        [state(), pending, settled],
        [state(), "garbage-without-structure"],
        [state(), checks("pending"), checks("success"), human(a=True)],
        [state(), f"review:{ {'head': HEAD, 'status': 'unable', 'category': 'timeout'} }"],
        [state(), checks("success"), f"review:{ {'head': HEAD, 'status': 'clear'} }"],
        [state(), checks("success"), f"review:{ {'head': HEAD, 'status': 'clear'} }", human()],
        *([m] for m in MALFORMED),
        *([state(), m] for m in MALFORMED),
    ]


def outcome(row: dict, key: str, compute) -> None:
    try:
        row[key] = compute()
    except Exception as error:  # the gate records exactly this text
        row[f"{key}_error"] = firing_failure_text(error)


def main() -> None:
    rng = random.Random("hamsterdan-readiness board corpus")
    logs = scenarios() + [random_log(rng) for _ in range(RANDOM_LOGS)]
    with OUT.open("w") as out:
        for log in logs:
            row: dict = {"entries": log}
            outcome(row, "board", lambda: render_board(log))
            outcome(row, "facts", lambda: repr(gate_facts(log)))
            out.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
