"""Golden vectors for the sha256-counter-v1 choice streams.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/choice_vectors.py \
        ../../packages/petrus-dst/test/data/choice-vectors.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from pydantic import ValidationError

from petrus.testing.dst import ChoiceAuthority, ChoiceProvenance, ChoiceStreams

SEEDS = [0, 1, 7, 1729, 2**31, 2**53 - 1]
AUTHORITIES = [ChoiceAuthority.WORKLOAD, ChoiceAuthority.FAULT, ChoiceAuthority.EVENT_ORDER]
STOPS = [1, 2, 3, 10, 17, 1000, 2**32 + 15, 2**53 - 1]
NAMESPACES = ["scenario", "queue", "a.b-c_d:e", "Z"]


def error(call):
    try:
        call()
    except (ValueError, TypeError) as caught:
        return {"type": type(caught).__name__, "message": str(caught)}
    return None


def scripts(seed: int) -> dict:
    # One interleaved script per seed: every authority and stop, plus
    # identifiers, in a fixed order; each draw records its value.
    streams = ChoiceStreams(seed)
    draws = []
    for round_ in range(3):
        for authority in AUTHORITIES:
            for stop in STOPS:
                draws.append(["index", authority.value, stop, streams.index(authority, stop)])
        for namespace in NAMESPACES:
            draws.append(["identifier", namespace, None, streams.identifier(namespace)])
    return {"seed": seed, "draws": draws, "provenance": streams.provenance().model_dump(mode="json")}


def main() -> int:
    streams = ChoiceStreams(1729)
    out = {
        "scripts": [scripts(seed) for seed in SEEDS],
        "errors": {
            "seed_negative": error(lambda: ChoiceStreams(-1)),
            "seed_too_large": error(lambda: ChoiceStreams(2**53)),
            "stop_zero": error(lambda: streams.index(ChoiceAuthority.WORKLOAD, 0)),
            "stop_too_large": error(lambda: streams.index(ChoiceAuthority.WORKLOAD, 2**53)),
            "identifier_authority": error(lambda: streams.index(ChoiceAuthority.IDENTIFIER, 2)),
            "namespace_empty": error(lambda: streams.identifier("")),
            "namespace_space": error(lambda: streams.identifier("bad name")),
        },
        "provenance": [],
    }
    for draws in [
        {"workload": 2**53},
        {"workload": 0},
        {"workload": -1},
        {"identifier:": 1},
        {"identifier:bad name": 1},
        {"other": 1},
        {"identifier:scenario": 2, "workload": 1},
        {"event_order": 1, "fault": 3},
    ]:
        value = {"algorithm": "sha256-counter-v1", "seed": 1729, "draws": draws}
        try:
            ChoiceProvenance.model_validate(value, strict=True)
            verdict = None
        except ValidationError as caught:
            verdict = [[list(e["loc"]), e["type"], e["msg"]] for e in caught.errors()]
        out["provenance"].append({"value": value, "errors": verdict})
    Path(sys.argv[1]).write_text(json.dumps(out, sort_keys=True, indent=1, ensure_ascii=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
