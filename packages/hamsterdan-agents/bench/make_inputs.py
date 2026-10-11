"""Generate inputs.json for the hamsterdan-agents benchmarks.

    upstream/hamsterdan/.venv/bin/python -I -B \
        packages/hamsterdan-agents/bench/make_inputs.py

* ``request``: a review request with the V5 host's lenses, a policy digest,
  context paths, Actions evidence and three prior comments;
* ``result``: the final text of a blocking review of that request with
  eight findings (each with a related location) and their lineage;
* ``archive``: a settled workspace archive (ustar, base64) of 200 files of
  1 KiB in ten directories, the shape ``_validated_entries`` admits.

Both benchmark sides read the same file.
"""

from __future__ import annotations

import base64
import io
import json
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

REQUEST = {
    "repository": "owner/one",
    "pull_request": 7,
    "epoch": 3,
    "head": "a" * 40,
    "base": "b" * 40,
    "diff_path": "diff.patch",
    "policy": {"digest": "1b9644588188936d5c034276e2bec644a45cece97027f391ef3d99db2cdb0413"},
    "review_lenses": ["correctness", "security", "tests", "maintainability", "developer experience"],
    "context_paths": ["src/service.py", "src/routes.py", "tests/test_service.py"],
    "actions_evidence": [
        {"name": "ci", "conclusion": "success", "url": "https://example.test/runs/1"},
        {"name": "lint", "conclusion": "failure", "url": "https://example.test/runs/2"},
    ],
    "prior_findings": [],
    "prior_comments": [
        {
            "author": "reviewer",
            "body": f"Comment {n}: please keep the guards aligned and add a regression test for the edge case.",
            "id": n,
            "url": f"https://example.test/comments/{n}",
        }
        for n in range(1, 4)
    ],
    "prior_replies": [],
    "applied_changes": [],
}


def finding(n: int) -> dict[str, object]:
    return {
        "id": f"F{n}",
        "path": f"src/module{n}.py",
        "line": 10 + n,
        "related_locations": [{"path": f"src/helper{n}.py", "line": 20 + n}],
        "title": f"Keep guard {n} aligned",
        "body": "These guards enforce one invariant but currently disagree.",
        "severity": "high",
        "confidence": 0.9,
        "evidence": "The primary path allows the state rejected by the related path.",
        "blocking": True,
        "suggestion": "if state.is_ready:",
    }


RESULT = {
    **{name: REQUEST[name] for name in ("repository", "pull_request", "epoch", "head", "base")},
    "status": "blocking",
    "findings": [finding(n) for n in range(1, 9)],
    "lineage": [{"finding_id": f"F{n}", "state": "new", "supersedes": None} for n in range(1, 9)],
}


def archive() -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for d in range(10):
            directory = tarfile.TarInfo(f"dir{d}")
            directory.type, directory.mode, directory.mtime = tarfile.DIRTYPE, 0o755, 0
            tar.addfile(directory)
            for f in range(20):
                content = (f"line {f} of dir{d}/file{f}.txt\n" * 64)[:1024].encode()
                member = tarfile.TarInfo(f"dir{d}/file{f}.txt")
                member.size, member.mode, member.mtime = len(content), 0o644, 0
                tar.addfile(member, io.BytesIO(content))
    return buffer.getvalue()


def main() -> None:
    document = {
        "request": REQUEST,
        "result": json.dumps(RESULT, sort_keys=True),
        "archive": base64.b64encode(archive()).decode(),
    }
    (HERE / "inputs.json").write_text(json.dumps(document, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
