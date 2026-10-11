"""A scripted ``gh`` for testing the tier C operators offline.

    FAKE_GH_SCRIPT=answers.json FAKE_GH_LOG=calls.jsonl python3 fake_gh.py ARG...

Standard library only. Put a ``gh`` wrapper that execs it first on PATH.
It appends its argument vector to FAKE_GH_LOG as one JSON line and answers
from FAKE_GH_SCRIPT, a JSON object from the space-joined argument vector to
a list of answers ``{"stdout": TEXT, "code": N}``: the nth call of a command
line gets the nth answer, the last one repeating (the count is kept in
``FAKE_GH_LOG``). An unscripted command line exits 1 with ``unscripted`` on
standard error. It never reaches GitHub.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> int:
    arguments = sys.argv[1:]
    key = " ".join(arguments)
    log = Path(os.environ["FAKE_GH_LOG"])
    seen = 0
    if log.exists():
        seen = sum(1 for line in log.read_text(encoding="utf-8").splitlines() if json.loads(line) == arguments)
    with log.open("a", encoding="utf-8") as output:
        output.write(json.dumps(arguments, ensure_ascii=False) + "\n")
    answers = json.loads(Path(os.environ["FAKE_GH_SCRIPT"]).read_text(encoding="utf-8")).get(key)
    if not answers:
        sys.stderr.write(f"unscripted: gh {key}\n")
        return 1
    answer = answers[min(seen, len(answers) - 1)]
    sys.stdout.write(answer.get("stdout", ""))
    return int(answer.get("code", 0))


if __name__ == "__main__":
    raise SystemExit(main())
