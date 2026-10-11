"""Generate the webhook, inbox and routing differential corpus.

Run with the pinned reference environment from the repository root:

    upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_webhook_corpus.py

Every row drives a fresh ``WebhookCustody`` (and ``InstallationRegistry``)
from ``upstream/hamsterdan`` through a sequence of operations and records
each outcome and the final SQLite rows. The Haskell suite replays the same
operations and must reproduce every outcome and every stored byte.

No secret or real payload is involved: the webhook secret is a fixed test
value and every payload is synthetic.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import random
import sqlite3
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "upstream" / "hamsterdan" / "src"))

from hamsterdan.github_app.config import AccountConfig  # noqa: E402
from hamsterdan.github_app.models import InstallationInventory  # noqa: E402
from hamsterdan.github_app.routing import InstallationRegistry  # noqa: E402
from hamsterdan.github_app.webhooks import (  # noqa: E402
    SUPPORTED_EVENTS,
    WebhookCustody,
    WebhookRejected,
    admit_conversation,
)

SEED = 20261012
SECRET = "corpus-hook-secret"
OUT = ROOT / "packages" / "hamsterdan-github" / "test" / "corpus" / "webhooks.jsonl"
ACCOUNTS = (
    AccountConfig(23, "Owner", ((31, "owner/one"), (32, "owner/two"))),
    AccountConfig(24, "Other-Owner", ((33, "other-owner/three"),)),
)

rng = random.Random(SEED)


def accounts_json() -> list[object]:
    return [[a.account_id, a.account_login, [list(r) for r in a.repositories]] for a in ACCOUNTS]


# --- Values -----------------------------------------------------------------

WEIRD = [
    None,
    False,
    True,
    0,
    1,
    -3,
    44,
    "",
    "x",
    "44",
    "created",
    "added",
    "removed",
    [],
    [1],
    ["a", "b"],
    {},
    {"a": 1},
    {"number": 7},
    1.5,
    0.0,
    2**70,
    "café \U0001f600",
]


def weird() -> object:
    return rng.choice(WEIRD)


def text() -> str:
    alphabet = "abcXYZ019 -_@\t\n\"\\/éß \U0001f600\x01"
    return "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 12)))


def user() -> dict[str, object]:
    login = rng.choice(["alice", "Bob-Dev", "carol", "dave", " hamster-dan[bot] ", "HAMSTER-DAN[BOT]"])
    kind = "User" if rng.random() < 0.8 else rng.choice(["Bot", "Organization", None])
    return {"id": rng.randint(1, 99), "login": login, "type": kind}


def repository() -> dict[str, object]:
    repo_id, name = rng.choice([(31, "owner/one"), (32, "Owner/Two"), (33, "other-owner/three"), (99, "owner/no")])
    return {"id": repo_id, "full_name": name, "name": name.split("/")[1], "private": rng.random() < 0.5}


def installation() -> dict[str, object]:
    return {"id": rng.choice([44, 45, 46]), "account": {"id": rng.choice([23, 24, 25]), "login": "Owner"}}


def comment_body() -> str:
    if rng.random() < 0.025:
        return rng.choice(["x" * 16384, "x" * 16385, "\u00e9" * 8192, "\u00e9" * 8193])
    return rng.choice(
        [
            "@hamster-dan explain the blockers",
            "  @HaMsTeR-DaN   why?  ",
            "@hamster-dan",
            "@hamster-dan ",
            "@Hamster-Dan\u00a0\u00a0spaced",
            "@hamster-dan\u2028line",
            "@hamster-dan-other explain",
            "@hamster-dan\texplain",
            "hello @hamster-dan",
            "@ham\u017fter-dan x",
            "\u212a@hamster-dan k",
            "@hamster-dan \u00df\u00e9 \U0001f600",
            text(),
        ]
    )


def payload(event: str) -> dict[str, object]:
    value: dict[str, object] = {"action": rng.choice(["created", "opened", "synchronize", "completed", "edited"])}
    if rng.random() < 0.9:
        value["installation"] = installation()
    if rng.random() < 0.9:
        value["repository"] = repository()
    value["sender"] = user()
    number = rng.randint(1, 30)
    if event in {"pull_request", "pull_request_review", "pull_request_review_comment", "pull_request_review_thread"}:
        value["pull_request"] = {"number": number, "head": {"sha": "a" * 40}, "title": text()}
        if event != "pull_request":
            value["comment" if event == "pull_request_review_comment" else "review"] = {"id": 5, "body": text()}
    elif event == "issue_comment":
        value["action"] = rng.choice(["created", "created", "edited", "deleted"])
        issue: dict[str, object] = {"number": number}
        if rng.random() < 0.8:
            issue["pull_request"] = {"url": "https://api.github.com/x"}
        value["issue"] = issue
        comment: dict[str, object] = {
            "id": rng.randint(1, 999),
            "body": comment_body(),
            "author_association": rng.choice(["OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR", "member", "Collaborator", None]),
        }
        if rng.random() < 0.85:
            comment["user"] = user()
        value["comment"] = comment
    elif event == "issues":
        value["issue"] = {"number": number}
    elif event in {"workflow_run", "check_run", "check_suite"}:
        pulls = [{"number": number}] if rng.random() < 0.8 else []
        value[event] = {"id": 77, "pull_requests": pulls, "head_sha": "b" * 40}
    elif event == "installation":
        value["action"] = rng.choice(["created", "deleted", "suspend", "unsuspend", "new_permissions_accepted", "other"])
        value["repositories"] = [repository() for _ in range(rng.randint(0, 3))]
        value.pop("repository", None)
    elif event == "installation_repositories":
        value["action"] = rng.choice(["added", "removed", "other"])
        value["repositories_added"] = [repository() for _ in range(rng.randint(0, 3))]
        value["repositories_removed"] = [repository() for _ in range(rng.randint(0, 2))]
        value.pop("repository", None)
    elif event == "ping":
        value = {"zen": "Keep it logically awesome.", "hook_id": 1}
        if rng.random() < 0.5:
            value["installation"] = installation()
    return value


PATHS = [
    ("action",),
    ("installation",),
    ("installation", "id"),
    ("installation", "account"),
    ("installation", "account", "id"),
    ("repository",),
    ("repository", "id"),
    ("repository", "full_name"),
    ("pull_request",),
    ("pull_request", "number"),
    ("issue",),
    ("issue", "pull_request"),
    ("issue", "number"),
    ("comment",),
    ("comment", "user"),
    ("comment", "body"),
    ("comment", "id"),
    ("comment", "author_association"),
    ("sender",),
    ("sender", "login"),
    ("repositories",),
    ("repositories_added",),
    ("repositories_removed",),
    ("workflow_run",),
    ("workflow_run", "pull_requests"),
    ("check_run", "pull_requests"),
    ("check_suite", "pull_requests"),
]


def mutate(value: dict[str, object]) -> dict[str, object]:
    for _ in range(rng.randint(1, 3)):
        path = rng.choice(PATHS)
        target: object = value
        for key in path[:-1]:
            if not isinstance(target, dict):
                break
            target = target.setdefault(key, {})
        if not isinstance(target, dict):
            continue
        roll = rng.random()
        if roll < 0.15:
            target.pop(path[-1], None)
        elif roll < 0.3 and path[-1] in {"repositories", "repositories_added", "repositories_removed"}:
            target[path[-1]] = rng.choice(
                [
                    [{"id": 31}],
                    [{"full_name": "owner/one"}],
                    ["owner/one"],
                    [[31, "owner/one"]],
                    "",
                    "ab",
                    {},
                    {"id": 1},
                    None,
                    5,
                    [{"id": "31", "full_name": "owner/one"}, {"id": 32, "full_name": " owner/two"}],
                ]
            )
        elif roll < 0.4 and path[-1] == "pull_requests":
            target[path[-1]] = rng.choice([[5], ["x"], "x", {"0": {"number": 1}}, 3, [{"number": "7"}], [[1]], [None]])
        else:
            target[path[-1]] = weird()
    return value


# --- Envelopes --------------------------------------------------------------


def signed(body: bytes) -> str:
    return "sha256=" + hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()


def delivery_spelling() -> str:
    value = uuid.UUID(int=rng.getrandbits(128))
    hex32 = value.hex
    roll = rng.random()
    if roll < 0.85:
        return str(value)
    return rng.choice(
        [
            hex32,
            hex32.upper(),
            "{" + str(value) + "}",
            "urn:uuid:" + str(value),
            "+" + hex32[1:],
            "-0000000000000000000000000000000",
            "-" + hex32[1:],
            hex32[:8] + "_" + hex32[9:],
            hex32[:31] + "_",
            "0x" + hex32[2:],
            "0x_" + hex32[3:],
            " " + hex32[1:],
            "{ " + hex32[2:] + "}",
            hex32[:31] + "g",
            hex32[:30],
            "not-a-uuid",
            "",
            "\xa0" + hex32[1:],
            hex32[:10] + "__" + hex32[12:],
        ]
    )


def headers_for(body: bytes, event: str | None, delivery: str | None = None) -> list[list[str]]:
    headers = [
        ["content-length", str(len(body))],
        ["content-type", "application/json"],
        ["x-hub-signature-256", signed(body)],
        ["x-github-delivery", delivery if delivery is not None else delivery_spelling()],
    ]
    if event is not None:
        headers.append(["x-github-event", event])
    return headers


def mutate_headers(headers: list[list[str]], body: bytes) -> list[list[str]]:
    roll = rng.random()
    if roll < 0.08:
        headers[0][1] = rng.choice(["", "3", " " + str(len(body)) + " ", "0" + str(len(body)), "+2", "٢", "1e2", "-1"])
    elif roll < 0.14:
        headers[1][1] = rng.choice(["application/json; charset=utf-8", "APPLICATION/JSON", " application/json\t", "text/plain", ""])
    elif roll < 0.2:
        headers[2][1] = rng.choice(["sha1=" + "0" * 40, headers[2][1].upper(), "sha256=" + "0" * 64, headers[2][1] + " ", headers[2][1][:-1]])
    elif roll < 0.26:
        name = rng.choice(["Content-Length", "X-GitHub-Event", "x-hub-signature-256", "X-Other", "Content-Type"])
        headers.append([name, rng.choice([str(len(body)), "ping", "x"])])
    elif roll < 0.3:
        headers.append(["Transfer-Encoding", "chunked"])
    elif roll < 0.34:
        headers.append(["X-GitHub-Delivery", "x" * 257])
    elif roll < 0.38:
        index = rng.randrange(len(headers))
        headers.pop(index)
    elif roll < 0.42:
        headers = [[name.upper(), value] for name, value in headers]
    elif roll < 0.46:
        headers[1][1] = "application/json" + "x" * 300
    return headers


def body_for(value: object) -> bytes:
    roll = rng.random()
    if roll < 0.8:
        return json.dumps(value).encode()
    if roll < 0.85:
        return json.dumps(value, ensure_ascii=False).encode()
    if roll < 0.88:
        return json.dumps(value, ensure_ascii=False).encode("utf-16")
    if roll < 0.9:
        return json.dumps(value).encode("utf-16-le")
    if roll < 0.92:
        return b"\xef\xbb\xbf" + json.dumps(value).encode()
    return rng.choice(
        [
            b"not json",
            b"[]",
            b"null",
            b"\"x\"",
            b"{\"action\": NaN}",
            b"{\"a\": 1, \"a\": 2, \"action\": \"x\", \"action\": \"created\"}",
            b"{\"action\": " + b"1" * 4301 + b"}",
            b"{\"action\": " + b"1" * 4300 + b"}",
            b"{\"action\": [" + b"[" * 200 + b"]" * 200 + b"]}",
            b"{\"action\": \"\xff\"}",
            b"{\"action\": 1e400}",
            b"{} ",
            b" {}",
            b"{}x",
            b"",
            b"\xef\xbb\xbf\xef\xbb\xbf{}",
            b"{\"action\": \"x\" \x0c}",
        ]
    )


# --- Running ----------------------------------------------------------------


def observation_text(observation: object) -> str | None:
    if observation is None:
        return None
    from dataclasses import asdict

    return json.dumps(asdict(observation), separators=(",", ":"), sort_keys=True)


def run_receive(custody: WebhookCustody, headers: list[list[str]], body: bytes) -> dict[str, object]:
    try:
        receipt = custody.receive([tuple(item) for item in headers], body)
    except WebhookRejected as error:
        return {"outcome": "rejected", "reason": str(error)}
    except Exception as error:  # the uncaught failures a host answers with 500
        return {"outcome": "error", "class": type(error).__name__}
    return {
        "outcome": "receipt",
        "delivery_id": receipt.delivery_id,
        "disposition": receipt.disposition,
        "observation": observation_text(receipt.observation),
    }


def dump_state(directory: Path) -> dict[str, object]:
    state: dict[str, object] = {}
    inbox = sqlite3.connect(directory / "w.db")
    state["inbox"] = [
        list(row)
        for row in inbox.execute(
            "SELECT delivery_id,event,observation,status,attempts,reason,error_class,next_attempt_at FROM inbox ORDER BY rowid"
        )
    ]
    inbox.close()
    if (directory / "r.db").exists():
        routes = sqlite3.connect(directory / "r.db")
        state["installations"] = [list(row) for row in routes.execute("SELECT * FROM installations ORDER BY installation_id")]
        state["repositories"] = [
            list(row) for row in routes.execute("SELECT * FROM repositories ORDER BY installation_id, repository_id")
        ]
        routes.close()
    return state


def receive_case() -> dict[str, object]:
    with_registry = rng.random() < 0.7
    maximum = 1_048_576 if rng.random() < 0.95 else 300
    steps = []
    deliveries: list[str] = []
    for _ in range(rng.randint(1, 4)):
        event = "issue_comment" if rng.random() < 0.35 else rng.choice(sorted(SUPPORTED_EVENTS) + ["push", None])
        value: object = payload(event or "ping")
        if rng.random() < 0.45 and isinstance(value, dict):
            value = mutate(value)
        body = body_for(value)
        delivery = rng.choice(deliveries) if deliveries and rng.random() < 0.2 else None
        headers = headers_for(body, event, delivery)
        deliveries.append(headers[3][1])
        if rng.random() < 0.25:
            headers = mutate_headers(headers, body)
        elif rng.random() < 0.03:
            headers[2][1] = signed(body + b" ")
        steps.append({"op": "receive", "headers": headers, "body": base64.b64encode(body).decode()})
    return {"kind": "receive", "registry": with_registry, "maximum": maximum, "steps": steps}


def subject_of(step_value: dict[str, object]) -> list[int]:
    return [step_value["installation"]["id"], step_value["repository"]["id"], step_value["pull_request"]["number"]]  # type: ignore[index]


def inbox_case() -> dict[str, object]:
    steps: list[dict[str, object]] = []
    deliveries: list[str] = []
    subjects = [[44, 31, 1], [44, 31, 2], [44, 32, 1]]
    clock = 100.0
    for _ in range(rng.randint(3, 30)):
        roll = rng.random()
        if roll < 0.3 or not deliveries:
            subject = rng.choice(subjects)
            value = {
                "action": "synchronize",
                "installation": {"id": subject[0], "account": {"id": 23}},
                "repository": {"id": subject[1], "full_name": "owner/one"},
                "pull_request": {"number": subject[2]},
            }
            body = json.dumps(value).encode()
            delivery = str(uuid.UUID(int=rng.getrandbits(128)))
            deliveries.append(delivery)
            steps.append({"op": "receive", "headers": headers_for(body, "pull_request", delivery), "body": base64.b64encode(body).decode()})
        elif roll < 0.42:
            steps.append({"op": "pending", "limit": rng.choice([0, 1, 2, 100, 5000]), "subject": rng.choice([None, *subjects])})
        elif roll < 0.5:
            steps.append({"op": "has_pending", "subject": rng.choice(subjects)})
        elif roll < 0.6:
            steps.append({"op": "eligible", "delivery": rng.choice([*deliveries, str(uuid.UUID(int=1))]), "subject": rng.choice(subjects)})
        elif roll < 0.67:
            steps.append({"op": "acknowledge", "delivery": rng.choice(deliveries), "reason": rng.choice(["processed", "x" * 300, "café"])})
        elif roll < 0.82:
            for _ in range(rng.choice([1, 1, 5, 20])):
                steps.append({"op": "retry", "delivery": rng.choice(deliveries), "error": rng.choice(["RuntimeError", "GitHubBoundaryError", "E" * 200])})
        elif roll < 0.87:
            steps.append({"op": "status", "delivery": rng.choice([*deliveries, "missing"])})
        elif roll < 0.9:
            steps.append({"op": "counts"})
        elif roll < 0.93:
            steps.append({"op": "failures", "limit": rng.choice([0, 1, 100])})
        elif roll < 0.97:
            choice = rng.choice(deliveries)
            steps.append({"op": "requeue", "delivery": rng.choice([choice, choice.upper(), "not-a-uuid", choice.replace("-", "")])})
        else:
            clock += rng.choice([0.5, 1.0, 2.0, 64.0, 400.0])
            steps.append({"op": "clock", "now": clock})
    return {"kind": "inbox", "registry": False, "maximum": 1_048_576, "steps": steps}


def routing_case() -> dict[str, object]:
    steps: list[dict[str, object]] = []
    for _ in range(rng.randint(2, 25)):
        roll = rng.random()
        installation_id = rng.choice([44, 45, 46, 0, -1, "44", True, None])
        account_id = rng.choice([23, 24, 25, "23", True])
        if roll < 0.3:
            steps.append(
                {
                    "op": "installation",
                    "action": rng.choice(["created", "unsuspend", "new_permissions_accepted", "suspend", "deleted", "other", 1, None, ["x"], {"a": 1}]),
                    "installation_id": installation_id,
                    "account_id": account_id,
                }
            )
        elif roll < 0.6:
            repositories = [
                rng.choice(
                    [
                        [31, "owner/one"],
                        [31, "Owner/One"],
                        [32, "owner/two"],
                        [33, "other-owner/three"],
                        [33, "Other-Owner/Three"],
                        [99, "owner/no"],
                        [0, "owner/one"],
                        ["31", "owner/one"],
                        [31, " owner/one"],
                        [31, "owner/one/x"],
                        [31, "owner/é"],
                        [31, 5],
                        [31, "owner/" + "x" * 200],
                    ]
                )
                for _ in range(rng.randint(0, 3))
            ]
            steps.append(
                {
                    "op": "repositories",
                    "action": rng.choice(["added", "removed", "other", None, ["added"]]),
                    "installation_id": installation_id,
                    "account_id": account_id,
                    "repositories": repositories,
                }
            )
        elif roll < 0.8:
            steps.append({"op": "route", "installation_id": rng.choice([44, 45, 46]), "repository_id": rng.choice([31, 32, 33, 99])})
        elif roll < 0.9:
            inventory = []
            for account in rng.sample([23, 24, 25], rng.choice([1, 2, 2, 3])):
                repos = rng.sample([[31, "owner/one"], [32, "Owner/Two"], [33, "other-owner/three"], [99, "x/y"], [31, "owner/renamed"]], rng.randint(0, 4))
                inventory.append([rng.choice([44, 45, 46, 0]), account, repos])
            steps.append({"op": "reconcile", "inventory": inventory})
        else:
            steps.append({"op": rng.choice(["active_count", "active_installation_count"])})
    return {"kind": "routing", "registry": True, "maximum": 1_048_576, "steps": steps}


def surrogate_cases() -> list[dict[str, object]]:
    """Fixed rows: lone surrogate escapes in provider JSON.

    CPython's ``json.loads`` keeps ``"\\ud800"`` in a ``str``. A comment body
    holding one is refused (``len(text.encode())`` raises
    ``UnicodeEncodeError``, a ``ValueError``); anywhere else the delivery is
    accepted and its observation is stored with ``ensure_ascii``, which
    escapes it again. These rows come after the seeded ones and draw nothing
    from ``rng``, so the seeded rows are unchanged.
    """
    serial = iter(range(1, 1000))

    def receive(event: str, value: object) -> dict[str, object]:
        body = json.dumps(value).encode()  # ensure_ascii: the escape travels as written
        delivery = str(uuid.UUID(int=0x5D800000000000000000000000000000 + next(serial)))
        return {"op": "receive", "headers": headers_for(body, event, delivery), "body": base64.b64encode(body).decode()}

    installed = {"id": 44, "account": {"id": 23, "login": "Owner"}}
    repo = {"id": 31, "full_name": "owner/one"}
    pull = {"number": 7, "head": {"sha": "a" * 40}}

    def comment(body: str, login: str = "alice", association: str = "OWNER") -> dict[str, object]:
        return {
            "action": "created",
            "installation": installed,
            "repository": repo,
            "issue": {"number": 7, "pull_request": {"url": "https://api.github.com/x"}},
            "comment": {"id": 9, "body": body, "author_association": association, "user": {"id": 5, "login": login, "type": "User"}},
            "sender": {"id": 5, "login": login, "type": "User"},
        }

    accepted = [
        receive("pull_request", {"action": "\ud800", "installation": installed, "repository": {"id": 31, "full_name": "owner/\udc00"}, "pull_request": pull}),
        receive("pull_request", {"action": "synchronize", "installation": installed, "repository": repo, "pull_request": pull, "\udfff": ["\ud83d"]}),
        receive("issue_comment", comment("@hamster-dan explain", login="\ud800bob", association="\udc00")),
        receive("issue_comment", comment("@hamster-dan \ud83d\ude00 a pair is fine")),
        {"op": "pending", "limit": 100, "subject": None},
    ]
    refused = [
        receive("issue_comment", comment("@hamster-dan \ud800 why")),
        receive("issue_comment", comment("\ude00\ud83d reversed")),
        receive("pull_request_review_comment", {"action": "created", "installation": installed, "repository": repo, "pull_request": pull, "comment": {"id": 5, "body": "\ud800"}}),
        {"op": "pending", "limit": 100, "subject": None},
    ]
    routing = [
        receive(
            "installation_repositories",
            {
                "action": "added",
                "installation": installed,
                "repositories_added": [{"id": 31, "full_name": "owner/\ud800"}, {"id": 32, "full_name": "owner/two"}],
                "repositories_removed": [],
            },
        ),
        receive("installation", {"action": "created", "installation": installed, "repositories": [{"id": 33, "full_name": "\udc00/three"}]}),
        {"op": "pending", "limit": 100, "subject": None},
    ]
    return [
        {"kind": "receive", "registry": registry, "maximum": 1_048_576, "steps": steps}
        for steps in (accepted, refused, routing)
        for registry in (False, True)
    ]


class Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


def run(case: dict[str, object]) -> dict[str, object]:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        clock = Clock()
        registry = InstallationRegistry(directory / "r.db", accounts=ACCOUNTS) if case["registry"] else None
        custody = WebhookCustody(
            directory / "w.db",
            webhook_secret=SECRET,
            registry=registry,
            maximum_body_bytes=case["maximum"],  # type: ignore[arg-type]
            clock=clock,
        )
        results: list[object] = []
        for step in case["steps"]:  # type: ignore[attr-defined]
            results.append(apply(step, custody, registry, clock))
        custody.close()
        if registry is not None:
            registry.close()
        case["results"] = results
        case.update(dump_state(directory))
    return case


def observations(values: tuple[object, ...]) -> list[object]:
    return [json.loads(observation_text(value)) | {"attempts": value.attempts} for value in values]  # type: ignore[attr-defined]


def apply(step: dict[str, object], custody: WebhookCustody, registry: InstallationRegistry | None, clock: Clock) -> object:
    op = step["op"]
    if op == "receive":
        result = run_receive(custody, step["headers"], base64.b64decode(step["body"]))  # type: ignore[arg-type]
        if result.get("observation") is not None:
            from hamsterdan.github_app.webhooks import Observation

            item = Observation(**json.loads(result["observation"]) | {"repositories": tuple(tuple(x) for x in json.loads(result["observation"])["repositories"])})  # type: ignore[arg-type]
            admitted = admit_conversation(item, app_slug="hamster-dan", bot_login="hamster-dan[bot]")
            result["admitted"] = None if admitted is None else admitted.dump()
        return result
    if op == "pending":
        subject = step["subject"]
        return observations(custody.pending(step["limit"], subject=None if subject is None else tuple(subject)))  # type: ignore[arg-type]
    if op == "has_pending":
        return custody.has_pending(subject=tuple(step["subject"]))  # type: ignore[arg-type]
    if op == "eligible":
        return custody.eligible(step["delivery"], subject=tuple(step["subject"]))  # type: ignore[arg-type]
    if op == "acknowledge":
        custody.acknowledge(step["delivery"], step["reason"])  # type: ignore[arg-type]
        return None
    if op == "retry":
        error = type(step["error"], (Exception,), {})()  # type: ignore[arg-type]
        custody.retry(step["delivery"], error)  # type: ignore[arg-type]
        return None
    if op == "status":
        return custody.status(step["delivery"])  # type: ignore[arg-type]
    if op == "counts":
        return custody.counts()
    if op == "failures":
        return list(custody.failures(step["limit"]))  # type: ignore[arg-type]
    if op == "requeue":
        return custody.requeue(step["delivery"])  # type: ignore[arg-type]
    if op == "clock":
        clock.now = step["now"]  # type: ignore[assignment]
        return None
    assert registry is not None
    try:
        if op == "installation":
            return registry.installation(step["action"], step["installation_id"], step["account_id"])  # type: ignore[arg-type]
        if op == "repositories":
            return registry.repositories(
                step["action"],  # type: ignore[arg-type]
                step["installation_id"],  # type: ignore[arg-type]
                step["account_id"],  # type: ignore[arg-type]
                tuple(tuple(item) for item in step["repositories"]),  # type: ignore[attr-defined]
            )
        if op == "route":
            route = registry.route(step["installation_id"], step["repository_id"])  # type: ignore[arg-type]
            return None if route is None else [route.installation_id, route.account_id, route.repository_id, route.repository_full_name]
        if op == "reconcile":
            inventory = tuple(InstallationInventory(a, b, tuple(tuple(r) for r in repos)) for a, b, repos in step["inventory"])  # type: ignore[attr-defined]
            return registry.reconcile(inventory)
        if op == "active_count":
            return registry.active_count()
        if op == "active_installation_count":
            return registry.active_installation_count()
    except Exception as error:
        return {"error": type(error).__name__, "message": str(error)}
    raise AssertionError(op)


def main() -> None:
    cases = [receive_case() for _ in range(1000)] + [inbox_case() for _ in range(200)] + [routing_case() for _ in range(300)]
    cases += surrogate_cases()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w") as handle:
        for case in cases:
            row = {"accounts": accounts_json(), "secret": SECRET} | run(case)
            handle.write(json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n")
    print(f"wrote {len(cases)} rows to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
