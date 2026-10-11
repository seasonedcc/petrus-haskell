"""Drive the reference host over a state directory, for state interop.

Usage: ``python -I -B state_reference.py drive ROOT < steps.json`` or
``python -I -B state_reference.py dump ROOT``.

``drive`` opens the reference ``HostService`` on ROOT exactly as
``test_selected_v5_routes_custodied_webhook_into_identified_history_before_acknowledgement``
of ``tests/integration/host/test_service.py`` does (the real V5 application,
``V5Provider`` behind the GitHub transport, the clear-review ``V5Runner``),
runs the steps, closes the host, and prints one JSON document: the provider
calls, the provider's final state, and one report per ``report`` step.
The provider's starting state (head, comments) comes in with the steps, so a
run can resume where a run of either implementation left the provider.

With ``github_port`` (and ``private_key``, the App's PEM) in the document,
the host instead composes the real GitHub client stack and sends every
request to the recording fake GitHub on ``127.0.0.1:github_port``; the
``V5Provider`` then stays unused.

``dump`` prints every file under ROOT in a comparable form: SQLite
databases as their schema and sorted rows, every other file as text.

``InteropSpec`` runs the same steps through the Haskell host and compares.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

import httpx

from hamsterdan.agents.protocol import ReviewResult
from hamsterdan.github_app.auth import GitHubAppClients
from hamsterdan.github_app.config import AccountConfig, HostConfig
from hamsterdan.github_app.models import WireResponse
from hamsterdan.host import service as service_module
from hamsterdan.host.__main__ import inspect_instance
from hamsterdan.host.agenticus import AgentRouteStore, compose_agent
from hamsterdan.host.service import HostService


class Client:
    def request(self, method, path):
        raise AssertionError("no inventory calls are expected")


class Clients:
    def registration_inventory(self, config):
        raise AssertionError("registration inventory was not configured")

    def installation(self, installation_id, repository_ids):
        return Client()

    def close(self):
        pass


class V5Provider:
    def __init__(self, head: str, comments: list) -> None:
        self.head, self.base = head, "b" * 40
        self.calls: list[list[str]] = []
        self.comments: list[dict[str, object]] = comments

    def pages(self, path: str):
        self.calls.append(["PAGES", path])
        if path == "/repos/owner/one/issues/7/comments?per_page=100":
            return tuple(self.comments)
        return ()

    def request(self, method: str, path: str, body: object | None = None):
        self.calls.append([method, path])
        if method == "GET" and path == "/repos/owner/one/pulls/7":
            return WireResponse(
                200,
                {
                    "state": "open",
                    "draft": False,
                    "mergeable": True,
                    "mergeable_state": "clean",
                    "merged": False,
                    "html_url": "https://example.test/owner/one/pull/7",
                    "user": {"login": "author"},
                    "head": {"sha": self.head, "ref": "feature", "repo": {"full_name": "owner/one"}},
                    "base": {"sha": self.base, "ref": "main"},
                },
            )
        if method == "GET" and path == "/repos/owner/one/git/ref/heads/main":
            return WireResponse(200, {"object": {"sha": self.base}})
        if method == "GET" and path == "/repos/owner/one/rules/branches/main":
            return WireResponse(404, {})
        if method == "GET" and path == "/repos/owner/one/branches/main/protection":
            return WireResponse(404, {})
        if method == "GET" and path == f"/repos/owner/one/compare/{self.base}...{self.head}":
            return WireResponse(200, {"status": "ahead", "behind_by": 0})
        if method == "GET" and path == "/repos/owner/one/pulls/7/requested_reviewers":
            return WireResponse(200, {"users": []})
        if method == "GET" and path.startswith("/repos/owner/one/actions/workflows/.github%2Fworkflows%2Fci.yml/runs?"):
            return WireResponse(200, {"total_count": 0, "workflow_runs": []})
        if method == "POST" and path == "/graphql":
            return WireResponse(
                200,
                {
                    "data": {
                        "repository": {
                            "pullRequest": {
                                "reviewThreads": {
                                    "nodes": [],
                                    "pageInfo": {"hasNextPage": False, "endCursor": None},
                                }
                            }
                        }
                    }
                },
            )
        if method == "POST" and path == "/repos/owner/one/issues/7/comments" and isinstance(body, dict):
            comment = {
                "id": len(self.comments) + 1,
                "html_url": f"https://example.test/comments/{len(self.comments) + 1}",
                "body": body.get("body", ""),
                "user": {"login": "hamsterdan-test[bot]"},
            }
            self.comments.append(comment)
            return WireResponse(201, comment)
        if method == "PATCH" and path.startswith("/repos/owner/one/issues/comments/") and isinstance(body, dict):
            identifier = int(path.rsplit("/", 1)[1])
            for comment in self.comments:
                if comment["id"] == identifier:
                    comment["body"] = body.get("body", "")
                    return WireResponse(200, comment)
        raise AssertionError(f"unexpected provider request: {method} {path} {body!r}")


class V5Runner:
    def __init__(self) -> None:
        self.reviews: list[list[object]] = []

    def review(self, repository_url, request, *, operation, attempt, is_current=None):
        self.reviews.append([repository_url, request.head, operation, attempt])
        return ReviewResult(
            request.repository,
            request.pull_request,
            request.epoch,
            request.head,
            request.base,
            "clear",
            [],
            [],
        )


def config(root: Path, private_key: str = "private-key-secret") -> HostConfig:
    return HostConfig(
        app_id=17,
        app_slug="hamsterdan-test",
        client_id="Iv1.client-secret-looking",
        accounts=(AccountConfig(23, "Owner", ((31, "owner/one"), (32, "owner/two"))),),
        state_path=root,
        private_key=private_key,
        webhook_secret="hook-secret",
        watched_authors=frozenset(),
    )


def signed(body: bytes, delivery: str, event: str) -> dict[str, str]:
    digest = hmac.new(b"hook-secret", body, hashlib.sha256).hexdigest()
    return {
        "content-type": "application/json",
        "x-hub-signature-256": f"sha256={digest}",
        "x-github-delivery": delivery,
        "x-github-event": event,
        "content-length": str(len(body)),
    }


def inspected(root: Path) -> object:
    """``inspect-instance`` over the Instance, or the refusal it prints."""
    try:
        return inspect_instance(root, 44, 31, 7)
    except ValueError as error:
        return {"refused": str(error)}


class Redirect(httpx.HTTPTransport):
    """Send every request to the recording fake GitHub on a local port."""

    def __init__(self, port: int) -> None:
        super().__init__()
        self.port = port

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        request.url = request.url.copy_with(scheme="http", host="127.0.0.1", port=self.port)
        return super().handle_request(request)


def drive(root: Path, document: dict) -> dict:
    provider = V5Provider(document["head"], document["comments"])
    runner = V5Runner()
    port = document.get("github_port")
    if port is None:
        service_module.GitHubKitTransport = lambda client: provider
        clients, settings = Clients(), config(root)
    else:
        # The real GitHub client stack (App JWT, installation token,
        # githubkit, httpx) against the fake GitHub on 127.0.0.1:port.
        service_module.GitHubAppClients = lambda configured, **kwargs: GitHubAppClients(
            configured, transport=Redirect(int(port)), **kwargs
        )
        clients, settings = None, config(root, document["private_key"])
    composition = compose_agent()
    routes = AgentRouteStore(root / "test-agent-routes.sqlite3")
    routes.activate(composition, root / "applications")
    host = HostService(
        settings,
        clients=clients,
        runner=runner,
        agent_composition=composition,
        agent_routes=routes,
    )
    reports: list[dict] = []
    deliveries: list[str] = []
    try:
        for step in document["steps"]:
            op = step["op"]
            if op == "activate":
                assert host.registry.installation("created", 44, 23)
                assert host.registry.repositories("added", 44, 23, ((31, "owner/one"),))
            elif op == "deliver":
                body = step["body"].encode()
                receipt = host.custody.receive(signed(body, step["delivery"], step["event"]).items(), body)
                deliveries.append(step["delivery"])
                pending = [item for item in host.custody.pending() if item.delivery_id == step["delivery"]]
                reports.append({"receipt": receipt.disposition, "pending": len(pending)})
                if pending:
                    host.process(pending[0])
            elif op == "head":
                provider.head = step["head"]
            elif op == "converge":
                rounds = 0
                while True:
                    rounds += 1
                    assert rounds <= 50, "the host did not converge"
                    if host.pump() == 0:
                        break
            elif op == "sweep":
                reports.append({"swept": host.sweep(step.get("trigger", "periodic"))})
            elif op == "report":
                reports.append(
                    {
                        "status": {delivery: host.custody.status(delivery) for delivery in step["deliveries"]},
                        "counts": host.custody.counts(),
                        "subject": host.subject_state(44, 31, 7),
                        "inspect": inspected(root),
                    }
                )
            else:
                raise AssertionError(f"unknown step {op}")
    finally:
        host.close()
    return {
        "calls": provider.calls,
        "head": provider.head,
        "comments": provider.comments,
        "reviews": runner.reviews,
        "reports": reports,
    }


WORKER = re.compile(r"worker:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
INSTANT = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?")
EPOCH = re.compile(r"1\d{9}(\.\d+)?|1\d{12}|1\d{15}")


def normalized(text: str) -> str:
    """Only what differs between two runs of the same implementation: the
    Worker claimant's random identity and the wall-clock instants (ISO
    instants in JSON; epoch seconds, milliseconds and microseconds in
    SQLite columns)."""
    return INSTANT.sub("<instant>", WORKER.sub("worker:<uuid>", text))


def cell(value: object) -> str:
    text = repr(value)
    return "<epoch>" if EPOCH.fullmatch(text) else normalized(text)


def dump(root: Path) -> dict:
    files: dict[str, object] = {}
    for directory, _subdirectories, names in os.walk(root):
        for name in names:
            path = Path(directory) / name
            relative = str(path.relative_to(root))
            if name.endswith("-wal") or name.endswith("-shm") or name.endswith("-journal"):
                continue
            if relative == "test-agent-routes.sqlite3":
                # Agent route custody is the agents package's (the Haskell
                # host composes no agent runtime yet).
                continue
            if name.endswith(".sqlite3"):
                with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as database:
                    tables = {}
                    for table, sql in database.execute(
                        "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') AND sql IS NOT NULL ORDER BY name"
                    ):
                        rows = []
                        if sql.startswith("CREATE TABLE"):
                            rows = sorted(
                                [[cell(value) for value in row] for row in database.execute(f'SELECT * FROM "{table}"')]
                            )
                        tables[table] = {"sql": sql, "rows": rows}
                    files[relative] = {
                        "user_version": database.execute("PRAGMA user_version").fetchone()[0],
                        "tables": tables,
                    }
            else:
                files[relative] = normalized(path.read_bytes().decode("utf-8", "backslashreplace"))
    return dict(sorted(files.items()))


def main() -> None:
    command, root = sys.argv[1], Path(sys.argv[2])
    if command == "drive":
        result = drive(root, json.load(sys.stdin))
    elif command == "dump":
        result = dump(root)
    else:
        raise SystemExit(f"unknown command {command}")
    json.dump(result, sys.stdout, sort_keys=True)


if __name__ == "__main__":
    main()
