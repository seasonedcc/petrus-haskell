"""Answer agent calls from a tape the way a tier C host would.

    python -I -B carry_check.py TAPE CALLS.jsonl

Runs in the reference's environment. Each line of CALLS is ``{"kind",
"operation", "attempt", "request"}``; each output line is what
``host_seams.CarriedRunner.answer`` returns for it (``{"result": ...}`` or
``{"error": ...}``), and the last line is ``{"unknown": [...]}``. The
Haskell twin (``Hamsterdan.E2E.Agents.carriedRunner``) must print the same
values for the same calls; the test suite checks it.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import host_seams  # noqa: E402
import tape as tapes  # noqa: E402


def main() -> None:
    runner = host_seams.CarriedRunner(Path(sys.argv[1]))
    for call in tapes.read(Path(sys.argv[2]).parent, Path(sys.argv[2]).name):
        answer = runner.answer(call["kind"], call["operation"], call["attempt"], call["request"])
        sys.stdout.write(json.dumps(answer, ensure_ascii=False) + "\n")
    sys.stdout.write(json.dumps({"unknown": runner.unknown}) + "\n")


if __name__ == "__main__":
    main()
