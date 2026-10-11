"""Raise recorded failures the way the replay seams do.

    python -I -B raise_check.py FAILURES.jsonl

Runs in the reference's environment. Each line of FAILURES is a recorded
``error`` member; each output line describes what
``host_seams.raise_recorded`` raised for it: the class, ``str(error)`` and
the attributes the host reads, or ``{"refused": true}`` when the record
itself was refused (a missing member or a value the reference cannot take).
The Haskell twin (``Hamsterdan.E2E.Replay.raiseRecorded``) must describe
the same exceptions; the test suite checks it.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import host_seams  # noqa: E402


RAISED = ("AgentProtocolError", "GitPublishError", "GitHubBoundaryError", "GitHubObjectWriteError", "RuntimeError")


def value(item):
    return getattr(item, "value", item)


def describe(error: Exception) -> dict[str, object]:
    kind = type(error).__name__
    out: dict[str, object] = {"class": kind, "str": str(error)}
    if kind == "AgentProtocolError":
        out.update(
            canceled=error.canceled,
            timed_out=error.timed_out,
            result_category=value(error.result_category),
            cleanup_category=value(error.cleanup_category),
        )
    elif kind == "GitPublishError":
        out["category"] = value(error.category)
    elif kind in ("GitHubBoundaryError", "GitHubObjectWriteError"):
        out.update(
            failure_class=value(error.failure_class),
            provider_status=error.provider_status,
            provider_detail=error.provider_detail,
        )
    return out


def main() -> None:
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
        out: dict[str, object] = {"raised": False}
        try:
            host_seams.raise_recorded(json.loads(line))
        except Exception as error:  # noqa: BLE001 - described
            out = describe(error) if type(error).__name__ in RAISED else {"refused": True}
        sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
