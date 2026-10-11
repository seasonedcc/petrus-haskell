"""Python side of the hamsterdan-host benchmarks (same operations as Main.hs).

    upstream/hamsterdan/.venv/bin/python -I -B \
        packages/hamsterdan-host/bench/bench.py

Rows:

* webhook ingest: 100 signed ``pull_request`` deliveries, each a
  ``POST /github/webhooks`` through the FastAPI application called in
  process (one ASGI call per request: header and body checks, signature,
  routing, durable custody), into one long-lived host;
* reconciliation step: one webhook to quiescence on a fresh Instance: open
  the host on a fresh state directory, take the delivery into custody,
  process it through the real V5 application against the ``V5Provider``
  double (the PR reads, the review, the dashboard), pump until nothing is
  runnable, close, remove the directory;
* agent turn: the same step with ``main()``'s composed agent in place of the
  clear-review runner (``state_reference.compose_real_agent``: the Pi A2
  installation from the environment, ``agent-routes.sqlite3``, the
  workspace receiver, ``compose_owned_pi_a2`` over the scripted Pi runtime,
  ``PiNativeRunner``), so the review is one scripted Pi turn over a clone of
  a local repository, with its route claimed and settled;
* gate classification: ``reply_gate``, ``reminder_gate`` and ``dash_gate``
  under each of the eight publisher outcomes of ``test_v5_gates.py``
  (created, existing, boundary, collision, unknown, capability denial,
  unclassified status, already held), 24 classifications;
* timer rebuild: ``V5TimerStore.open`` of a fresh store from the 333-fact
  timer History in ``inputs.json`` (made by ``make_inputs.py``), then close
  and remove the database; and, to separate the file work from the
  replay, the same open of a fresh store with no History.

The doubles are ``differential/state_reference.py``'s, the ones the state
interop tests run. Worker progress lines go to /dev/null on both sides.

Prints the time per pass (best of 5 timeit repeats; each repeat runs the
pass enough times to take about half a second).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import timeit
from pathlib import Path

from pydantic import TypeAdapter

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "differential"))

import state_reference as doubles  # noqa: E402

from hamsterdan.contracts.readiness_v5 import (  # noqa: E402
    DashReq,
    RemReq,
    ReplyReq,
    TimerCommandApplied,
    TimerDue,
)
from hamsterdan.github_app.models import CommentReference, GitHubBoundaryError, PublicationResult  # noqa: E402
from hamsterdan.host import __main__ as host_main  # noqa: E402
from hamsterdan.host import service as service_module  # noqa: E402
from hamsterdan.host.agenticus import AgentRouteStore, compose_agent  # noqa: E402
from hamsterdan.host.api import create_app  # noqa: E402
from hamsterdan.host.service import HostService  # noqa: E402
from hamsterdan.host.v5.claim import CurrentClaim  # noqa: E402
from hamsterdan.host.v5.gates import V5PublicationGates  # noqa: E402
from hamsterdan.host.v5.timers import V5TimerStore  # noqa: E402

SYNCHRONIZE = (
    b'{"action": "synchronize", "installation": {"id": 44, "account": {"id": 23}}, '
    b'"repository": {"id": 31, "full_name": "owner/one"}, "pull_request": {"number": 7}}'
)
# Resolved: the host refuses a state root with a symbolic link among its
# ancestors, and the temporary directory is under one on macOS (/var).
SCRATCH = Path(tempfile.mkdtemp(prefix="hamsterdan-host-bench-")).resolve()
DEVNULL = open(os.devnull, "w")  # noqa: SIM115 - lives for the whole run


def open_host(root: Path, runner: object) -> HostService:
    composition = compose_agent()
    routes = AgentRouteStore(root / "test-agent-routes.sqlite3")
    routes.activate(composition, root / "applications")
    host = HostService(
        doubles.config(root),
        clients=doubles.Clients(),
        runner=runner,
        agent_composition=composition,
        agent_routes=routes,
    )
    assert host.registry.installation("created", 44, 23)
    assert host.registry.repositories("added", 44, 23, ((31, "owner/one"),))
    return host


# ---------------------------------------------------------------------------
# Webhook ingest


def ingest_case():
    host = open_host(SCRATCH / "ingest", object())
    app = create_app(host, reconcile_startup=False)
    loop = asyncio.new_event_loop()
    counter = [0]

    async def post(delivery: str) -> int:
        headers = doubles.signed(SYNCHRONIZE, delivery, "pull_request")
        scope = {
            "type": "http",
            "asgi": {"version": "3.0"},
            "http_version": "1.1",
            "method": "POST",
            "scheme": "http",
            "path": "/github/webhooks",
            "raw_path": b"/github/webhooks",
            "query_string": b"",
            "root_path": "",
            "headers": [(name.encode(), value.encode()) for name, value in headers.items()],
            "client": ("127.0.0.1", 50000),
            "server": ("127.0.0.1", 8000),
        }
        sent = [False]
        status = [0]

        async def receive():
            if not sent[0]:
                sent[0] = True
                return {"type": "http.request", "body": SYNCHRONIZE, "more_body": False}
            return {"type": "http.disconnect"}

        async def send(message):
            if message["type"] == "http.response.start":
                status[0] = message["status"]

        await app(scope, receive, send)
        return status[0]

    async def batch() -> None:
        for _ in range(100):
            counter[0] += 1
            delivery = f"{counter[0]:08x}-0000-4000-8000-000000000000"
            assert await post(delivery) == 202

    return lambda: loop.run_until_complete(batch())


# ---------------------------------------------------------------------------
# Reconciliation step


def reconcile_once() -> None:
    root = Path(tempfile.mkdtemp(dir=SCRATCH))
    provider = doubles.V5Provider("a" * 40, [])
    service_module.GitHubKitTransport = lambda client: provider
    with contextlib.redirect_stdout(DEVNULL):
        host = open_host(root, doubles.V5Runner())
        try:
            delivery = "11111111-1111-4111-8111-111111111111"
            receipt = host.custody.receive(doubles.signed(SYNCHRONIZE, delivery, "pull_request").items(), SYNCHRONIZE)
            assert receipt.disposition == "accepted"
            host.process(host.custody.pending()[0])
            while host.pump() != 0:
                pass
        finally:
            host.close()
    assert len(provider.comments) == 1
    shutil.rmtree(root)


# ---------------------------------------------------------------------------
# Agent turn


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


def agent_case():
    repository = SCRATCH / "repository"
    base, first, _second = deterministic_repository(repository)
    text = json.dumps(
        {
            "repository": "owner/one",
            "pull_request": 7,
            "epoch": 1,
            "head": first,
            "base": base,
            "status": "clear",
            "findings": [],
            "lineage": [],
        },
        separators=(",", ":"),
    )
    agent = {
        "turns": [text],
        "repository": str(repository),
        "cli": "/opt/pi/cli.js",
        "node": "/opt/pi/node",
        "package": "/opt/pi/package",
    }

    def run() -> None:
        root = Path(tempfile.mkdtemp(dir=SCRATCH))
        provider = doubles.V5Provider(first, [], base)
        service_module.GitHubKitTransport = lambda client: provider
        with contextlib.redirect_stdout(DEVNULL):
            runner, composition, routes, runtime = doubles.compose_real_agent(root, agent)
            host = HostService(
                doubles.config(root),
                clients=doubles.Clients(),
                runner=runner,
                agent_composition=composition,
                agent_routes=routes,
                agent_runtime=runtime,
            )
            try:
                assert host.registry.installation("created", 44, 23)
                assert host.registry.repositories("added", 44, 23, ((31, "owner/one"),))
                delivery = "11111111-1111-4111-8111-111111111111"
                receipt = host.custody.receive(
                    doubles.signed(SYNCHRONIZE, delivery, "pull_request").items(), SYNCHRONIZE
                )
                assert receipt.disposition == "accepted"
                host.process(host.custody.pending()[0])
                while host.pump() != 0:
                    pass
            finally:
                host_main._close_owned_resources(host, runtime, routes)
        assert len(provider.comments) == 1
        assert len(runner.reviews) == 1
        shutil.rmtree(root)

    return run


# ---------------------------------------------------------------------------
# Gate classification

CLAIM = CurrentClaim(phase="running", incarnation=1, head="h1", base="b1", policy="p1")
REFERENCE = CommentReference(1, "https://example.test/c/1")


class Publisher:
    """``FakePublisher`` of ``test_v5_gates.py`` without the call record."""

    def __init__(self, mode: str | None = None, found: bool = False):
        self.mode, self.found = mode, found

    def _outcome(self):
        if self.mode == "existing":
            return PublicationResult("existing", REFERENCE)
        if self.mode == "boundary":
            raise GitHubBoundaryError("GitHub did not prove comment publication")
        if self.mode == "collision":
            raise ValueError("stable publication operation collided with a different payload")
        if self.mode == "unknown":
            raise RuntimeError("provider returned an unclassifiable terminal")
        if self.mode == "capability":
            return PublicationResult("capability_unavailable", None, False)
        if self.mode == "unclassified":
            return PublicationResult("banana", REFERENCE)
        return PublicationResult("created", REFERENCE)

    def immutable_operation(self, kind, operation, body, *, context, compatible_bodies=()):
        if self.found:
            return PublicationResult("existing", REFERENCE)
        context()
        return self._outcome()

    def dashboard(self, operation, epoch, head, body):
        return self._outcome()

    def reminder_operation(self, operation, *, context):
        if self.found:
            return PublicationResult("existing", REFERENCE)
        context()
        return self._outcome()


PUBLISHERS = [
    Publisher(mode)
    for mode in (None, "existing", "boundary", "collision", "unknown", "capability", "unclassified")
] + [Publisher(found=True)]
GATES = [
    V5PublicationGates(
        publisher=publisher,
        claim=lambda: CLAIM,
        recipients=lambda: ("the-reviewer", "the-author"),
        dashboard_phase=lambda: CLAIM.phase,
    )
    for publisher in PUBLISHERS
]
REPLY = ReplyReq(id="c1", text="the answer")
REMINDER = RemReq(timer_id="t1")
DASH = DashReq(entries=["row1", "row2"], digest="d1", desired_entries=["row1", "row2"], desired_digest="d1")


def classify_all() -> None:
    for gates in GATES:
        gates.reply_gate(REPLY)
        gates.reminder_gate(REMINDER)
        gates.dash_gate(DASH)


# ---------------------------------------------------------------------------
# Timer rebuild

INPUTS = json.loads((HERE / "inputs.json").read_text())
FACTS = tuple(
    TypeAdapter(TimerCommandApplied).validate_json(json.dumps(row["applied"]))
    if "applied" in row
    else TypeAdapter(TimerDue).validate_json(json.dumps(row["due"]))
    for row in INPUTS["timer_history"]
)


def rebuild_once(facts: tuple = FACTS) -> None:
    path = SCRATCH / "timers.sqlite3"
    store = V5TimerStore.open(path, INPUTS["subject"], history=facts)
    store.close()
    for suffix in ("", "-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)


def cases() -> dict:
    return {
        "webhook ingest/100 deliveries through POST /github/webhooks": ingest_case(),
        "reconciliation/one webhook to quiescence on a fresh Instance": reconcile_once,
        "agent turn/one webhook to quiescence through the scripted Pi agent": agent_case(),
        f"gates/{3 * len(GATES)} classifications (reply, reminder, dash x 8 outcomes)": classify_all,
        f"timers/rebuild from a {len(FACTS)}-fact History": rebuild_once,
        "timers/open a fresh store with no History": lambda: rebuild_once(()),
    }


def main() -> None:
    try:
        for name, case in cases().items():
            trial = timeit.timeit(case, number=1)
            number = max(1, int(0.5 / max(trial, 1e-9)))
            best = min(timeit.repeat(case, number=number, repeat=5)) / number
            print(f"{name:72s} {best * 1e3:10.3f} ms", flush=True)
    finally:
        shutil.rmtree(SCRATCH, ignore_errors=True)


if __name__ == "__main__":
    main()
