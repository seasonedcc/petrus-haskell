"""Generate the agent-protocol differential corpus for hamsterdan-contracts.

Run from the repository root against the pinned upstream environment:

    uv run --project upstream/hamsterdan --frozen --python 3.14 \
        python packages/hamsterdan-contracts/scripts/gen_protocol_corpus.py

Writes test/corpus/protocol.jsonl, one row per constructed value:

    {"type", "input", "asdict", "identity"}
    input:    the JSON text of the keyword arguments given to the dataclass
              (defaulted fields are sometimes omitted).
    asdict:   json.dumps(asdict(value), ensure_ascii=False, separators=(",", ":"))
    identity: json.dumps(asdict(value), sort_keys=True, separators=(",", ":"))
              (host/v5/review.py's request identity spelling).

The generator is seeded, so reruns are reproducible.
"""

from __future__ import annotations

import dataclasses
import json
import random
from pathlib import Path

from hamsterdan.agents import protocol

OUT = Path(__file__).resolve().parents[1] / "test" / "corpus" / "protocol.jsonl"
rng = random.Random(20261011)
CHARS = list("abcxyz_-./ 019") + ["'", '"', "\\", "\n", "\t", "\x00", "é", "中", "\U0001f600", " ", "\x7f"]


def text(limit: int = 10) -> str:
    return "".join(rng.choice(CHARS) for _ in range(rng.randint(0, limit)))


def scalar() -> object:
    return rng.choice(
        [
            None,
            True,
            False,
            rng.randint(-5, 5),
            rng.randint(-(2**70), 2**70),
            rng.uniform(-1e6, 1e6),
            rng.choice([0.0, -0.0, 1e-7, 1e22, 0.1]),
            text(),
        ]
    )


def value(depth: int = 0) -> object:
    roll = rng.random()
    if depth > 2 or roll < 0.6:
        return scalar()
    if roll < 0.8:
        return [value(depth + 1) for _ in range(rng.randint(0, 3))]
    return json_dict(depth + 1)


def json_dict(depth: int = 0) -> dict:
    return {text(6): value(depth) for _ in range(rng.randint(0, 4))}


def dicts() -> list:
    return [json_dict() for _ in range(rng.randint(0, 3))]


def texts() -> list:
    return [text() for _ in range(rng.randint(0, 3))]


def integer() -> int:
    return rng.choice([0, 1, 7, 2**40, rng.randint(0, 10**6)])


def common() -> dict:
    return {
        "repository": text(),
        "pull_request": integer(),
        "epoch": integer(),
        "head": text(),
        "base": text(),
    }


GENERATORS = {
    "ReviewRequest": lambda: {
        **common(),
        "diff_path": text(),
        "policy": json_dict(),
        "review_lenses": texts(),
        "context_paths": texts(),
        "actions_evidence": dicts(),
        "prior_findings": dicts(),
        "prior_comments": dicts(),
        "prior_replies": dicts(),
        "applied_changes": dicts(),
    },
    "ReviewResult": lambda: {**common(), "status": text(), "findings": dicts(), "lineage": dicts()},
    "ConversationRequest": lambda: {
        **common(),
        "comment_context": json_dict(),
        "actor": json_dict(),
        "dashboard": json_dict(),
        "gates": dicts(),
        "findings": dicts(),
        "allowed_intents": dicts(),
    },
    "ConversationResult": lambda: {**common(), "intents": dicts()},
    "CodingRequest": lambda: {
        "kind": rng.choice(["change", "repair", text()]),
        **common(),
        "ref": text(),
        "selected_work": dicts(),
        "failure_evidence": dicts(),
        "fingerprint": text(),
        "lineage": dicts(),
        "reproduction_status": text(),
        "merge_base": rng.random() < 0.5,
    },
    "CodingResult": lambda: {
        "kind": text(),
        **common(),
        "ref": text(),
        "status": text(),
        "reproduction_status": text(),
        "diff": text(30),
        "changed_files": texts(),
        "validation_evidence": dicts(),
        "proposed_commit_message": text(),
    },
}


def main() -> None:
    rows = []
    for name, generate in GENERATORS.items():
        cls = getattr(protocol, name)
        defaulted = {
            f.name
            for f in dataclasses.fields(cls)
            if f.default is not dataclasses.MISSING or f.default_factory is not dataclasses.MISSING
        }
        for _ in range(100):
            kwargs = generate()
            if defaulted and rng.random() < 0.3:
                for omitted in rng.sample(sorted(defaulted), rng.randint(1, len(defaulted))):
                    del kwargs[omitted]
            instance = cls(**kwargs)
            plain = dataclasses.asdict(instance)
            rows.append(
                {
                    "type": name,
                    "input": json.dumps(kwargs, ensure_ascii=False),
                    "asdict": json.dumps(plain, ensure_ascii=False, separators=(",", ":")),
                    "identity": json.dumps(plain, sort_keys=True, separators=(",", ":")),
                }
            )
    with OUT.open("w", encoding="utf-8") as out:
        for row in rows:
            out.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"wrote {len(rows)} rows to {OUT}")


if __name__ == "__main__":
    main()
