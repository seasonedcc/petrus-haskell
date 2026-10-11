"""Python side of the hamsterdan-agents benchmarks (same operations as Main.hs).

    upstream/hamsterdan/.venv/bin/python -I -B \
        packages/hamsterdan-agents/bench/bench.py

Rows (inputs from ``inputs.json``, made by ``make_inputs.py``):

* prompt: ``encode_prompt("review", url, request)``, the exact envelope of
  a review request with lenses, context, evidence and prior comments;
* result: ``_parse_result`` and ``_validate_result("review", ...)`` of an
  eight-finding blocking review;
* archive admission: ``_validated_entries`` of a 200-file settled
  workspace archive;
* sealed key: ``PersistentKeyOperations.seal`` then ``open`` of connection
  state under one context (the key is loaded from its file each time);
* route claim: ``AgentRouteStore.claim`` of a new operation then
  ``settle``, on one long-lived store;
* agent turn: one scripted Pi review through ``PiNativeRunner``, from a
  fresh state directory: ``_compose_agent_runtime`` (the workspace receiver
  and ``compose_owned_pi_a2`` over ``compose_pi_a2_scripted_runtime``), the
  review (clone of a local repository, review inputs, workspace archive,
  prompt, the scripted turn, result validation, bodies and ledger), close,
  remove the directory.

Prints the wall time per pass (best of 5 timeit repeats; each repeat runs
the pass enough times to take about half a second).
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import timeit
from dataclasses import replace
from pathlib import Path

from petrus.agenticus.connection.key import KeyContext
from petrus.agenticus.runtime.pi_a2_host import PiA2ScriptedTurn, compose_pi_a2_scripted_runtime

from hamsterdan.agents.pi import PiNativeRunner, _parse_result, encode_prompt
from hamsterdan.agents.protocol import ReviewRequest, _validate_result
from hamsterdan.host import __main__ as host_main
from hamsterdan.host import pi_a2 as pi_a2_module
from hamsterdan.host.agenticus import AgentRouteStore, compose_agent
from hamsterdan.host.pi_a2 import PersistentKeyOperations, PiA2InstallationConfig
from hamsterdan.host.pi_workspace import _validated_entries

HERE = Path(__file__).resolve().parent
INPUTS = json.loads((HERE / "inputs.json").read_text())
REQUEST = ReviewRequest(**INPUTS["request"])
RESULT = INPUTS["result"]
ARCHIVE = base64.b64decode(INPUTS["archive"])
URL = "https://github.com/owner/one.git"
SCRATCH = Path(tempfile.mkdtemp(prefix="hamsterdan-agents-bench-"))
INSTALLATION = PiA2InstallationConfig(
    "anthropic",
    "claude-sonnet-4-5",
    "synthetic-direct-authority",
    Path("/opt/pi/cli.js"),
    Path("/opt/pi/node"),
    Path("/opt/pi/package"),
)


def deterministic_repository(repo: Path) -> tuple[str, str, str]:
    """``Hamsterdan.Host.Scripted.deterministicRepository``."""
    environment = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Author",
        "GIT_AUTHOR_EMAIL": "author@example.test",
        "GIT_COMMITTER_NAME": "Author",
        "GIT_COMMITTER_EMAIL": "author@example.test",
        "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
        "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }

    def git(*arguments: str) -> str:
        return subprocess.run(
            ("git", *arguments), env=environment, check=True, capture_output=True, text=True
        ).stdout.strip()

    def commit(message: str, content: str) -> None:
        (repo / "README.md").write_text(content)
        git("-C", str(repo), "add", "README.md")
        git("-C", str(repo), "commit", "-q", "-m", message)

    git("init", "-q", "-b", "main", str(repo))
    commit("base", "hello\n")
    git("-C", str(repo), "checkout", "-q", "-b", "feature")
    commit("first", "hello\nworld\n")
    commit("second", "hello\nworld\nagain\n")
    return (
        git("-C", str(repo), "rev-parse", "main"),
        git("-C", str(repo), "rev-parse", "feature~1"),
        git("-C", str(repo), "rev-parse", "feature"),
    )


class LocalClone:
    """``Hamsterdan.Host.Scripted.localClone``."""

    def __init__(self, workspaces, repository: Path) -> None:
        self.workspaces, self.repository = workspaces, str(repository)

    def open(self, kind, repository_url, request, operation_id):
        return self.workspaces.open(kind, self.repository, request, operation_id)


def clear_review_text(request: ReviewRequest) -> str:
    """``Hamsterdan.Host.Scripted.clearReviewText``."""
    return json.dumps(
        {
            "repository": request.repository,
            "pull_request": request.pull_request,
            "epoch": request.epoch,
            "head": request.head,
            "base": request.base,
            "status": "clear",
            "findings": [],
            "lineage": [],
        },
        separators=(",", ":"),
    )


def prompt() -> None:
    encode_prompt("review", URL, REQUEST)


def result() -> None:
    _validate_result("review", _parse_result(RESULT), REQUEST)


def archive() -> None:
    _validated_entries(ARCHIVE)


def key_case():
    keys = PersistentKeyOperations(SCRATCH / "keys")
    context = KeyContext("hamsterdan-pi-a2", 1, 1)
    plain = b"opaque connection state of a Pi A2 direct authority"

    def run() -> None:
        sealed = keys.seal(context, bytearray(plain))
        assert keys.open(context, sealed) == plain

    return run


def route_case():
    composition = compose_agent()
    store = AgentRouteStore(SCRATCH / "routes" / "agent-routes.sqlite3")
    store.activate(composition, SCRATCH / "routes" / "applications")
    counter = [0]

    def run() -> None:
        counter[0] += 1
        operation = f"review:bench:{counter[0]}"
        store.claim(operation, composition)
        store.settle([operation])

    return run


def turn_case():
    repository = SCRATCH / "repository"
    base, first, _second = deterministic_repository(repository)
    request = replace(REQUEST, epoch=1, head=first, base=base, prior_comments=[])
    script = (PiA2ScriptedTurn(clear_review_text(request)),)

    def scripted(*, config, authority):
        runtime = compose_pi_a2_scripted_runtime(config=config, authority=authority, script=script)
        assert runtime.scripted_readiness().ready
        return runtime

    pi_a2_module.compose_pi_a2_runtime = scripted

    def run() -> None:
        root = SCRATCH / "turn"
        runtime, workspaces = host_main._compose_agent_runtime(root, INSTALLATION)
        try:
            runner = PiNativeRunner(runtime, LocalClone(workspaces, repository))
            reviewed = runner.review(URL, request, operation="review:bench:turn", attempt=1)
            assert reviewed.status == "clear"
        finally:
            assert runtime.close()
        shutil.rmtree(root)

    return run


def cases() -> dict:
    return {
        "prompt/encode a review prompt": prompt,
        "result/parse and validate an 8-finding review result": result,
        "archive/admit a 200-file settled workspace archive": archive,
        "keys/seal and open connection state": key_case(),
        "routes/claim and settle one operation": route_case(),
        "agent turn/one scripted Pi review through the Pi native runner": turn_case(),
    }


def main() -> None:
    try:
        for name, case in cases().items():
            trial = timeit.timeit(case, number=1)
            number = max(1, int(0.5 / max(trial, 1e-9)))
            best = min(timeit.repeat(case, number=number, repeat=5)) / number
            print(f"{name:72s} {best * 1e3:10.4f} ms", flush=True)
    finally:
        shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
