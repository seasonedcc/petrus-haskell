"""Generate the topology corpora for hamsterdan-readiness.

Run from the repository root against the pinned upstream environment:

    upstream/hamsterdan/.venv/bin/python -I -B \
        packages/hamsterdan-readiness/scripts/gen_topology_corpus.py

Writes test/corpus/:

net_definition.json    serialize_net_definition(project_net_definition(build_net_v5().net)),
                       the exact bytes the Haskell build must reproduce.
net_definition.sha256  its sha256, the fingerprint gate.
seed_marking.jsonl     {"subject", "delay"?, "marking"} | {"subject", "delay"?, "error"}
                       marking: [[place, [[color, data], ...]], ...] in marking order.
gates.json             {"gates": [[path, activity, [variants...]], ...], "derived": [...]}
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from petrus.impetus.net_definition import project_net_definition, serialize_net_definition

from hamsterdan.readiness.net_v5 import build_net_v5, seed_marking
from hamsterdan.readiness.net_v5.topology import DERIVED, GATES

OUT = Path(__file__).resolve().parents[1] / "test" / "corpus"


def dumps(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    document = serialize_net_definition(project_net_definition(build_net_v5().net))
    raw = document.encode() if isinstance(document, str) else document
    (OUT / "net_definition.json").write_bytes(raw)
    (OUT / "net_definition.sha256").write_text(hashlib.sha256(raw).hexdigest() + "\n")

    subjects = [
        ("acme/widgets#42", None),
        ("acme/widgets#42", 60),
        ("acme/widgets#42", 0),
        ("o/r#1", 7 * 24 * 60 * 60),
        ("with space", None),
        ("~!@#$%^&*()_+{}|:<>?`-=[]\\;',./\"", None),
        ("x" * 900, None),
        ("x" * 901, None),
        ("", None),
        ("tab\there", None),
        ("new\nline", None),
        ("del\x7f", None),
        ("café", None),
        (" ", None),
        ("emoji\U0001f600", None),
        ("nul\x00", None),
    ]
    with (OUT / "seed_marking.jsonl").open("w") as out:
        for subject, delay in subjects:
            row: dict = {"subject": subject}
            if delay is not None:
                row["delay"] = delay
            try:
                marking = seed_marking(subject) if delay is None else seed_marking(subject, reminder_delay_s=delay)
            except ValueError as error:
                row["error"] = str(error)
            else:
                row["marking"] = [
                    [str(path), [[token.color, token.data] for token in queue]] for path, queue in marking
                ]
            out.write(dumps(row) + "\n")

    gates = [[path, activity, list(variants)] for path, (activity, variants) in GATES.items()]
    (OUT / "gates.json").write_text(dumps({"gates": gates, "derived": list(DERIVED.items())}) + "\n")


if __name__ == "__main__":
    main()
