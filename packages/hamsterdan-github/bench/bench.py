"""Python side of the hamsterdan-github benchmarks (same inputs as Main.hs).

    upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/bench/bench.py

Results and the Haskell side are in RESULTS.md. Prints the mean time per
operation (best of 5 timeit repeats).
"""

from __future__ import annotations

import itertools
import json
import tempfile
import timeit
import uuid
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx
import jwt
from githubkit.webhooks import sign, verify

from hamsterdan.github_app.auth import GitHubAppClients
from hamsterdan.github_app.config import AccountConfig, HostConfig
from hamsterdan.github_app.effects import CommentPublisher
from hamsterdan.github_app.gateway import GitHubAuthority
from hamsterdan.github_app.models import WireResponse
from hamsterdan.github_app.transport import GitHubKitTransport
from hamsterdan.github_app.webhooks import WebhookCustody

HERE = Path(__file__).parent
inputs = json.loads((HERE / "inputs.json").read_text(encoding="utf-8"))
KEY = (HERE.parent / "test" / "corpus" / "app-test-key.pem").read_text()
SECRET = "bench-secret"
HEAD = inputs["head"]
webhook_body = inputs["webhook_body"].encode()
pull_body = inputs["pull_body"].encode()
pull_value = json.loads(pull_body)
comments = tuple(inputs["comments"])
signature = sign(SECRET, webhook_body)
DELIVERY = "3f0c1a52-4b7e-4c71-9a10-000000000001"

state = tempfile.mkdtemp(prefix="hamsterdan-bench-")
custody = WebhookCustody(Path(state) / "inbox.db", webhook_secret=SECRET)
observation = custody._parse(DELIVERY, "issue_comment", webhook_body)
counter = itertools.count()


def receive() -> None:
    delivery = str(uuid.UUID(int=next(counter)))
    headers = [
        ("content-length", str(len(webhook_body))),
        ("content-type", "application/json"),
        ("x-hub-signature-256", signature),
        ("x-github-delivery", delivery),
        ("x-github-event", "issue_comment"),
    ]
    custody.receive(headers, webhook_body)


config = HostConfig(
    app_id=17,
    app_slug="hamster-dan",
    client_id="Iv1.bench",
    accounts=(AccountConfig(23, "Owner", ((31, "owner/one"),)),),
    state_path=Path(state) / "state.db",
    private_key=KEY,
    webhook_secret=SECRET,
)


def handler(request: httpx.Request) -> httpx.Response:
    if request.url.path.endswith("/access_tokens"):
        return httpx.Response(201, json={"token": "ghs_bench", "expires_at": "2099-01-01T00:00:00Z"})
    return httpx.Response(
        200,
        headers={"content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-github-request-id": "R"},
        content=pull_body,
    )


clients = GitHubAppClients(config, transport=httpx.MockTransport(handler))
installation = GitHubKitTransport(clients.installation(44, [31]))
installation.request("GET", "/repos/owner/one/pulls/7")  # mint the token once


def mint_jwt() -> str:
    """githubkit's AppAuth._create_jwt: PyJWT over the PEM string."""
    now = datetime.now(timezone.utc) - timedelta(minutes=1)
    return jwt.encode({"iss": "17", "iat": now, "exp": now + timedelta(minutes=10)}, KEY, algorithm="RS256")



class FakeTransport:
    def __init__(self, responses: dict[tuple[str, str], WireResponse], pages: dict[str, tuple[Any, ...]]) -> None:
        self.responses, self.page_values = responses, pages

    def request(self, method: str, path: str, body: Any = None) -> WireResponse:  # noqa: ANN401
        return self.responses[(method, path)]

    def pages(self, path: str) -> tuple[Any, ...]:
        return self.page_values[path]


gateway = GitHubAuthority(
    FakeTransport(
        {
            ("GET", "/repos/owner/repo/pulls/7"): WireResponse(200, pull_value),
            ("GET", "/repos/owner/repo/git/ref/heads/main"): WireResponse(200, {"object": {"sha": "b" * 40}}),
        },
        {},
    ),
    "owner/repo",
    7,
)
publisher = CommentPublisher(
    FakeTransport({}, {"/repos/owner/repo/issues/7/comments?per_page=100": comments}),
    "owner/repo",
    7,
    "hamster-dan[bot]",
    lambda *args: None,
)
last_body = "Finding 99: the dashboard and the gate disagree about readiness."

CASES = {
    "webhook verify (HMAC-SHA256, 10 KB)": (lambda: verify(SECRET, webhook_body, signature), 20000),
    "webhook parse (issue_comment, 10 KB)": (lambda: custody._parse(DELIVERY, "issue_comment", webhook_body), 20000),
    "observation encode (sorted JSON)": (
        lambda: json.dumps(asdict(observation), separators=(",", ":"), sort_keys=True),
        20000,
    ),
    "webhook receive (verify, parse, SQLite insert)": (receive, 2000),
    "App JWT mint (RS256, PEM key)": (mint_jwt, 500),
    "installation GET pull (cached token, mock network)": (
        lambda: installation.request("GET", "/repos/owner/one/pulls/7"),
        2000,
    ),
    "gateway pull_request snapshot": (gateway.pull_request, 20000),
    "publisher lookup hit (100 comments)": (
        lambda: publisher.immutable("finding", "op-099", 1, HEAD, last_body),
        5000,
    ),
}


def main() -> None:
    for name, (case, number) in CASES.items():
        best = min(timeit.repeat(case, number=number, repeat=5)) / number
        print(f"{name:55s} {best * 1e6:10.3f} us")


if __name__ == "__main__":
    main()
