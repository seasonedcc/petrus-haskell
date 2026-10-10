"""Record the artifacts the reference's Engine-backed stories author.

Each ``build_*_artifact`` of the non-joined ``tests/dst/*_world.py`` modules
authors one artifact from a fresh History (and Dispatch) path. Most of them
equal a committed fixture byte for byte, but some fixtures are retained
older versions (the v2 failure fixtures, the v1 projection fixture) while
the builders now author version 3. The Haskell stories in
``packages/petrus-dst/engine`` must author exactly these bytes.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/engine_authored.py \
        ../../packages/petrus-dst/test/data/engine-authored.json
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

from petrus.testing.dst import encode_artifact
from tests.dst import (
    delayed_world,
    delivery_world,
    engine_world,
    generated_runtime_world,
    lifecycle_world,
    retry_world,
    timer_world,
)

ONE_PATH = [
    (engine_world, "build_projection_artifact"),
    (engine_world, "build_seeded_projection_artifact"),
    (engine_world, "build_resource_bounded_artifact"),
    (engine_world, "build_resource_budget_failure_artifact"),
    (engine_world, "build_history_refusal_artifact"),
    (engine_world, "build_history_ack_loss_artifact"),
    (engine_world, "build_dispatch_refusal_artifact"),
    (engine_world, "build_invariant_failure_artifact"),
    (engine_world, "build_budget_failure_artifact"),
    (delayed_world, "build_delayed_artifact"),
    (delivery_world, "build_delivery_artifact"),
    (lifecycle_world, "build_lifecycle_artifact"),
    (lifecycle_world, "build_lifecycle_cancellation_artifact"),
    (timer_world, "build_timer_artifact"),
]

TWO_PATHS = [
    (retry_world, "build_retry_artifact"),
    (retry_world, "build_delayed_retry_artifact"),
    (retry_world, "build_terminal_artifact"),
    (generated_runtime_world, "build_generated_runtime_artifact"),
]


def main() -> None:
    out = Path(sys.argv[1])
    vectors = []
    for module, name in ONE_PATH + TWO_PATHS:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            build = getattr(module, name)
            if (module, name) in TWO_PATHS:
                artifact = build(directory / "history.jsonl", directory / "dispatch.sqlite3")
            else:
                artifact = build(directory / "history.jsonl")
            vectors.append(
                {
                    "artifact": encode_artifact(artifact).decode("utf-8"),
                    "builder": f"{module.__name__.rsplit('.', 1)[-1]}.{name}",
                }
            )
    out.write_text(json.dumps({"vectors": vectors}, indent=1, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
