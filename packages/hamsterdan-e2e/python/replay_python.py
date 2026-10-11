"""Replay a tier B tape into the reference host.

    python -I -B replay_python.py TAPE ROOT --github-port PORT --server-log LOG --report REPORT

ROOT is an empty state directory. The host is the reference ``HostService``
with its production GitHub stack sent to ``tape_server.py`` on PORT, the
tape's agent results (``ReplayRunner``), the tape's Git publisher outcomes
(``ReplayPublisher``) and each step's recorded clock (``StepClock``). It
runs the tape's steps in order:

- ``registry``: ``host.registry.reconcile(inventories)``;
- ``deliver``: ``host.custody.receive`` with the recorded headers and body,
  signed again with the tape's ``replay_webhook_secret``; the disposition
  must be the recorded one;
- ``process``: ``host.process`` of that delivery's pending observation;
- ``pump``: ``host.pump(limit)``, which must process what it processed when
  recorded;
- ``converge``: ``host.pump()`` until it processes nothing, the replay
  server and the runner see no new call, and no publication is unresolved
  (what a live tape asks after each delivery);
- ``sweep``: ``host.sweep(trigger)`` (a live tape's);
- ``close``: ``host.close()``.

A step the recording host raised on (``raises``) must raise again with the
same message.

REPORT gets ``{"steps": [...], "agents": ..., "publisher": ...}``: per step
whether it went as recorded, and the replay runner's and publisher's calls,
unknown keys, mismatches and unused records. The state stays in ROOT.
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest  # noqa: E402

import host_seams  # noqa: E402
import tape as tapes  # noqa: E402
from hamsterdan.github_app.auth import GitHubAppClients  # noqa: E402
from hamsterdan.github_app.config import AccountConfig, HostConfig  # noqa: E402
from hamsterdan.github_app.models import InstallationInventory  # noqa: E402
from hamsterdan.host.agenticus import AgentRouteStore, compose_agent  # noqa: E402
from hamsterdan.host.service import HostService  # noqa: E402

HERE = Path(__file__).resolve().parent
APP_KEY = HERE.parents[2] / "packages" / "hamsterdan-github" / "test" / "corpus" / "app-test-key.pem"


def intent_order(monkeypatch: pytest.MonkeyPatch) -> None:
    """Tier A's ``intent_order`` seam (``journeys_reference.py``): the allowed
    intents in source order, as the tape's recording host declared them."""
    from hamsterdan.host.v5 import application

    selected = tuple(name for name in application._ALLOWED if name not in application._MUTATIONS)
    monkeypatch.setattr(application, "_ALLOWED", (*selected, "change", "update_base", "resolve_conflict"))


def lines(path: Path) -> int:
    return sum(1 for _ in path.open(encoding="utf-8")) if path.exists() else 0


def replay(tape: Path, root: Path, port: int, server_log: Path) -> dict[str, object]:
    meta = tapes.read_meta(tape)
    settings = meta["config"]
    steps = tapes.read(tape, "steps.jsonl")
    secret = settings["replay_webhook_secret"]
    config = HostConfig(
        app_id=settings["app_id"],
        app_slug=settings["app_slug"],
        client_id=settings["client_id"],
        accounts=tuple(
            AccountConfig(account, login, tuple((rid, name) for rid, name in repositories))
            for account, login, repositories in settings["accounts"]
        ),
        state_path=root,
        private_key=APP_KEY.read_text(),
        webhook_secret=secret,
        watched_authors=frozenset(settings.get("watched_authors", ())),
    )
    agent = meta.get("agent") or {}
    composition = compose_agent(provider=agent.get("provider"), model=agent.get("model"))
    routes = AgentRouteStore(root / "agent-routes.sqlite3")
    routes.activate(composition, root / "applications")
    runner = host_seams.ReplayRunner(tape)
    publisher = host_seams.ReplayPublisher(tape)
    clock = host_seams.StepClock(steps[0]["clock"] if steps else 0.0)
    report: list[dict[str, object]] = []
    with pytest.MonkeyPatch.context() as monkeypatch:
        if "intent_order" in meta.get("seams", ()):
            intent_order(monkeypatch)
        host = HostService(
            config,
            clients=GitHubAppClients(config, transport=host_seams.Redirect(port)),
            runner=runner,
            agent_composition=composition,
            agent_routes=routes,
            clock=clock,
            workflow_path=settings["workflow_path"],
            reminder_delay=float(settings["reminder_seconds"]),
            application_factory=host_seams.application_factory(lambda _authority, _url: publisher),
        )
        closed = False

        def unresolved() -> bool:
            return any(application.has_unresolved_publication() for application in host._apps.values())

        for step in steps:
            clock.value = step["clock"]
            entry: dict[str, object] = {"op": step["op"], "seq": step["seq"], "ok": True}
            try:
                if step["op"] == "registry":
                    host.registry.reconcile(
                        tuple(
                            InstallationInventory(i, a, tuple((rid, name) for rid, name in repositories))
                            for i, a, repositories in step["inventories"]
                        )
                    )
                elif step["op"] == "deliver":
                    body = step["body"].encode()
                    receipt = host.custody.receive(tapes.signed_headers(step["headers"], secret, body), body)
                    entry["disposition"] = receipt.disposition
                    entry["ok"] = receipt.disposition == step["disposition"]
                elif step["op"] == "process":
                    pending = [item for item in host.custody.pending() if item.delivery_id == step["delivery"]]
                    entry["ok"] = len(pending) == 1
                    if pending:
                        host.process(pending[0])
                elif step["op"] == "pump":
                    processed = host.pump(step["limit"])
                    entry["processed"] = processed
                    entry["ok"] = processed == step["processed"]
                elif step["op"] == "converge":
                    for _ in range(50):
                        before = (lines(server_log), len(runner.log), len(publisher.log))
                        processed = host.pump()
                        after = (lines(server_log), len(runner.log), len(publisher.log))
                        if processed == 0 and before == after and not unresolved():
                            break
                    else:
                        entry["ok"] = False
                elif step["op"] == "sweep":
                    entry["reconciled"] = host.sweep(step["trigger"])
                elif step["op"] == "close":
                    host.close()
                    closed = True
                else:
                    entry["ok"] = False
                    entry["error"] = f"unknown step {step['op']}"
            except Exception as error:  # noqa: BLE001 - reported; the comparison fails on it
                if "raises" in step:
                    entry["raised"] = str(error)
                    entry["ok"] = str(error) == step["raises"]
                else:
                    entry["ok"] = False
                    entry["error"] = traceback.format_exc(limit=8)
            else:
                if "raises" in step:
                    entry["ok"] = False
                    entry["error"] = "expected to raise: " + step["raises"]
            report.append(entry)
        if not closed:
            host.close()
    return {"steps": report, "agents": runner.report(), "publisher": publisher.report()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("tape", type=Path)
    parser.add_argument("root", type=Path)
    parser.add_argument("--github-port", type=int, required=True)
    parser.add_argument("--server-log", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    output = replay(args.tape.absolute(), args.root.absolute(), args.github_port, args.server_log)
    args.report.write_text(json.dumps(output, sort_keys=True, indent=1) + "\n")


if __name__ == "__main__":
    main()
