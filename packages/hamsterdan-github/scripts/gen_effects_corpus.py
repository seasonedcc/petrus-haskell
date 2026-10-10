"""Generate the reads, effects and GraphQL differential corpus.

Run with the pinned reference environment from the repository root:

    upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_effects_corpus.py

Every row runs one ``GitHubAuthority``, ``CommentPublisher``,
``CommentRerunBroker`` or ``GitHubGraphQL`` operation from
``upstream/hamsterdan`` against a simulated, randomly misbehaving GitHub:
comments land or not, requests fail before or after landing, statuses and
bodies are mutated, the fence and fault hooks refuse. The row records every
interaction in order (each request with its exact JSON body and the reply,
each page read, download, fence, fault, retry delay and context call) and
the operation's outcome. The Haskell suite replays the recorded replies and
must issue the same interactions in the same order and reach the same
outcome.

No credential or real payload is involved: every value is synthetic.
"""

from __future__ import annotations

import base64
import copy
import dataclasses
import json
import random
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "upstream" / "hamsterdan" / "src"))

from hamsterdan.github_app.effects import CommentPublisher, CommentRerunBroker  # noqa: E402
from hamsterdan.github_app.gateway import GitHubAuthority  # noqa: E402
from hamsterdan.github_app.models import (  # noqa: E402
    MAX_LOG_BYTES,
    ActionsJobSnapshot,
    ActionsRunSnapshot,
    FindingPublication,
    GitHubBoundaryError,
    PullRequestSnapshot,
    WireResponse,
)
from hamsterdan.github_app.transport import GitHubGraphQL  # noqa: E402

SEED = 20261013
OUT = ROOT / "packages" / "hamsterdan-github" / "test" / "corpus" / "effects.jsonl"
REPO = "owner/repo"
PR = 7
BOT = "hamsterdan[bot]"
HEADS = ["a" * 40, "b" * 40, "c" * 40, "0123456789abcdef0123456789abcdef01234567"]
BAD_HEADS = ["A" * 40, "abc", "g" * 40, "a" * 41, ""]

rng = random.Random(SEED)
# 0 for a well-behaved provider row, 1 for a misbehaving one.
damage = [1.0]


class FenceRefused(Exception):
    """The scripted fence refused the effect."""


def pick(values: list[Any]) -> Any:
    return copy.deepcopy(rng.choice(values))


WEIRD = [
    None,
    False,
    True,
    0,
    1,
    -1,
    7,
    2**70,
    "",
    "x",
    "7",
    " 12 ",
    "1_0",
    "open",
    "closed",
    "APPROVED",
    "dismissed",
    "completed",
    "success",
    [],
    [1],
    {},
    {"login": "x"},
    1.5,
    "a" * 40,
]


def mutate(value: Any, rate: float) -> Any:
    """Randomly damage a JSON value."""
    if isinstance(value, dict):
        out: dict[str, Any] = {}
        for key, item in value.items():
            roll = rng.random()
            if roll < rate / 3:
                continue
            if roll < rate:
                out[key] = pick(WEIRD)
            else:
                out[key] = mutate(item, rate / 2)
        if rng.random() < rate / 4:
            out[pick(["extra", "id", "state", "body"])] = pick(WEIRD)
        return out
    if isinstance(value, list):
        out_list = [mutate(item, rate / 2) for item in value if rng.random() > rate / 4]
        if out_list and rng.random() < rate / 4:
            out_list.append(copy.deepcopy(rng.choice(out_list)))
        if rng.random() < rate / 5:
            out_list.append(pick(WEIRD))
        return out_list
    return value


def maybe_mutate(value: Any, probability: float = 0.25, rate: float = 0.3) -> Any:
    if rng.random() < probability * damage[0]:
        return mutate(value, rate)
    return value


def boundary_spec() -> dict[str, Any]:
    return {
        "message": pick(["GitHub request failed", "injected boundary failure"]),
        "failure_class": pick(["transport_ambiguity", "transient_http_rejection", "provider_rejection"]),
        "provider_status": pick([None, 502, 404]),
        "provider_detail": pick(["none", "http_transport", "github_exception"]),
    }


def raise_boundary(spec: dict[str, Any]) -> None:
    raise GitHubBoundaryError(
        spec["message"],
        failure_class=spec["failure_class"],
        provider_status=spec["provider_status"],
        provider_detail=spec["provider_detail"],
    )


# --- The simulated GitHub ---------------------------------------------------


class World:
    """A misbehaving GitHub for one row, recording every interaction."""

    def __init__(self, heads: list[str], profile: dict[str, float]) -> None:
        self.events: list[dict[str, Any]] = []
        self.issue_comments: list[dict[str, Any]] = []
        self.review_comments: list[dict[str, Any]] = []
        self.next_id = 100
        self.heads = heads
        self.profile = profile
        self.runs_head = rng.choice(heads)

    # Comment helpers

    def comment(self, body: Any, login: Any = BOT) -> dict[str, Any]:
        self.next_id += rng.choice([1, 1, 1, 2])
        identifier: Any = self.next_id
        if rng.random() < self.profile["bad_id"]:
            identifier = pick([None, "x", str(self.next_id), 1.5, True, [], " 9 "])
        item: dict[str, Any] = {
            "id": identifier,
            "user": {"login": login},
            "body": body,
            "html_url": f"https://github.com/{REPO}/pull/{PR}#issuecomment-{self.next_id}",
        }
        if rng.random() < self.profile["bad_id"] / 2:
            del item[pick(["id", "html_url", "user"])]
        if rng.random() < self.profile["bad_id"] / 2:
            item["html_url"] = pick([None, 5, ["u"]])
        return item

    def seed_comments(self, markers: list[str], payloads: list[str]) -> None:
        for _ in range(rng.choice([0, 0, 1, 2, 3])):
            self.issue_comments.append(self.comment(pick(["hello", "LGTM", "<!-- hamsterdan:dashboard -->"]), "someone"))
        for marker in markers:
            roll = rng.random()
            target = self.issue_comments if rng.random() < 0.7 else self.review_comments
            if roll < 0.25 and payloads:
                target.append(self.comment(rng.choice(payloads)))
            elif roll < 0.35:
                target.append(self.comment(f"different body\n\n{marker}"))
            elif roll < 0.42:
                target.append(self.comment(marker))
            elif roll < 0.48:
                target.append(self.comment(rng.choice(payloads) if payloads else marker, pick(["someone", " Hamsterdan[BOT] ", None, 5])))
            elif roll < 0.52:
                target.append(self.comment(f"{marker}\n\ntrailer"))
            elif roll < 0.56:
                target.append(self.comment({"body": marker}))

    # Transport

    def request(self, method: str, path: str, body: Any = None) -> WireResponse:
        event: dict[str, Any] = {"t": "request", "method": method, "path": path, "body": body}
        self.events.append(event)
        try:
            response = self.respond(method, path, copy.deepcopy(body))
        except GitHubBoundaryError as error:
            event["raise"] = boundary_of(error)
            raise
        event["reply"] = {"status": response.status, "body": response.body, "next_path": response.next_path}
        return WireResponse(response.status, copy.deepcopy(response.body), response.next_path)

    def pages(self, path: str) -> tuple[dict[str, Any], ...]:
        event: dict[str, Any] = {"t": "pages", "path": path}
        self.events.append(event)
        if rng.random() < self.profile["page_fail"]:
            spec = boundary_spec()
            event["raise"] = spec
            raise_boundary(spec)
        if "/reviews" in path:
            values = self.reviews()
        elif path.startswith(f"/repos/{REPO}/pulls/{PR}/comments"):
            values = [copy.deepcopy(item) for item in self.review_comments]
        else:
            values = [copy.deepcopy(item) for item in self.issue_comments]
        event["reply"] = values
        return tuple(copy.deepcopy(values))

    def download(self, path: str, limit: int = MAX_LOG_BYTES) -> bytes:
        event: dict[str, Any] = {"t": "download", "path": path, "limit": limit}
        self.events.append(event)
        if rng.random() < 0.2:
            spec = boundary_spec()
            event["raise"] = spec
            raise_boundary(spec)
        size = pick([0, 5, 1024, MAX_LOG_BYTES, MAX_LOG_BYTES + 1])
        fill = rng.randrange(256)
        event["reply"] = {"fill": fill, "length": size}
        return bytes([fill]) * size

    # Hooks

    def fence(self, repository: str, pr_number: int, epoch: int, head: str, operation: str) -> None:
        event: dict[str, Any] = {"t": "fence", "args": [repository, pr_number, epoch, head, operation]}
        self.events.append(event)
        if rng.random() < self.profile["fence_fail"]:
            event["raise"] = True
            raise FenceRefused("stale authority")

    def fault(self, phase: str, repository: str, pr_number: int, kind: str, operation: str) -> None:
        event: dict[str, Any] = {"t": "fault", "args": [phase, repository, pr_number, kind, operation]}
        self.events.append(event)
        if rng.random() < self.profile["fault_fail"]:
            spec = boundary_spec()
            event["raise"] = spec
            raise_boundary(spec)

    def delay(self, seconds: float) -> None:
        self.events.append({"t": "delay", "seconds": seconds})

    def context(self, value: list[Any]) -> Any:
        self.events.append({"t": "context", "reply": value})
        return tuple(value)

    # Responses

    def respond(self, method: str, path: str, body: Any) -> WireResponse:
        if rng.random() < self.profile["raise"]:
            raise_boundary(boundary_spec())
        root = f"/repos/{REPO}"
        if method == "POST" and path == "/graphql":
            return self.graphql(body)
        if method == "POST" and path == f"{root}/issues/{PR}/comments":
            return self.effect(self.issue_comments, body, 201)
        if method == "POST" and path == f"{root}/pulls/{PR}/comments":
            return self.inline(body)
        if method == "POST" and path == f"{root}/pulls/{PR}/reviews":
            return self.batch(body)
        if method == "PATCH" and path.startswith(f"{root}/issues/comments/"):
            return self.edit(path, body)
        if method == "POST" and path.startswith(f"{root}/git/"):
            return self.git_object(path)
        if method == "GET":
            return self.read(path)
        return WireResponse(404, {"message": "Not Found"})

    def status_reply(self, success: int) -> WireResponse:
        status = pick([400, 403, 404, 409, 422, 422, 429, 500, 502, success, 204])
        body = pick(
            [
                None,
                "text",
                [],
                {"message": "Validation Failed"},
                {"message": " validation failed ", "errors": []},
                {"message": "Validation Failed", "errors": [{"field": "line", "code": "invalid"}]},
                {"message": "line is not in diff"},
                {"message": " Line Is Not In Diff "},
                {"message": "pull request review thread line must be part of the diff"},
                {"message": "You have exceeded a secondary rate limit"},
                {"message": "abuse detection mechanism triggered"},
                {"message": 5},
                {
                    "message": "Unprocessable",
                    "errors": [
                        {"field": "Pull_Request_Review_Thread/Line", "code": " Custom "},
                        {"field": "side", "code": "missing"},
                        "string",
                        {"field": "secret_field", "code": "token=abc"},
                        {"field": "path", "code": "already_exists"},
                    ],
                },
                {"errors": [{"field": "body", "code": "invalid"}] * 30},
            ]
        )
        return WireResponse(status, body)

    def landed_reply(self, item: dict[str, Any], success: int) -> WireResponse:
        roll = rng.random()
        if roll < 0.12:
            raise_boundary(boundary_spec())
        if roll < 0.2:
            return WireResponse(success, pick([None, [], "x", {"id": "x"}, {"html_url": "u"}, {"id": None}]))
        if roll < 0.35:
            return self.status_reply(success)
        return WireResponse(success, maybe_mutate(copy.deepcopy(item), 0.1))

    def effect(self, target: list[dict[str, Any]], body: Any, success: int) -> WireResponse:
        if rng.random() < self.profile["land"]:
            item = self.comment(body.get("body") if isinstance(body, dict) else body)
            target.append(item)
            return self.landed_reply(item, success)
        if rng.random() < 0.4:
            raise_boundary(boundary_spec())
        return self.status_reply(success)

    def inline(self, body: Any) -> WireResponse:
        if rng.random() < self.profile["land"]:
            item = self.comment(body.get("body"))
            self.review_comments.append(item)
            return self.landed_reply(item, 201)
        if rng.random() < 0.3:
            raise_boundary(boundary_spec())
        return self.status_reply(201)

    def batch(self, body: Any) -> WireResponse:
        if rng.random() < self.profile["land"]:
            for comment in body.get("comments", []):
                self.review_comments.append(self.comment(comment.get("body")))
            roll = rng.random()
            if roll < 0.15:
                raise_boundary(boundary_spec())
            if roll < 0.3:
                return self.status_reply(200)
            return WireResponse(200, pick([{"id": 900, "html_url": "https://github.com/r"}, {"id": "x"}, None, [], {"id": 901}]))
        if rng.random() < 0.3:
            raise_boundary(boundary_spec())
        return self.status_reply(200)

    def edit(self, path: str, body: Any) -> WireResponse:
        identifier = path.rsplit("/", 1)[-1]
        for item in self.issue_comments:
            if str(item.get("id")) == identifier and rng.random() < self.profile["land"]:
                item["body"] = body.get("body")
                return self.landed_reply(item, 200)
        if rng.random() < 0.3:
            raise_boundary(boundary_spec())
        return self.status_reply(200)

    def git_object(self, path: str) -> WireResponse:
        sha = pick(HEADS + ["A" * 40, "short", None, 5])
        roll = rng.random()
        if roll < 0.75:
            return WireResponse(pick([201, 201, 201, 200]), maybe_mutate({"sha": sha, "url": "u"}, 0.15))
        if roll < 0.85:
            raise_boundary(boundary_spec())
        return WireResponse(pick([201, 422]), pick([None, [], {"message": "x"}]))

    def read(self, path: str) -> WireResponse:
        root = f"/repos/{REPO}"
        status_roll = rng.random()
        if status_roll < self.profile["bad_status"] * damage[0]:
            return WireResponse(pick([404, 403, 500, 201]), {"message": "Not Found"})
        if path == f"{root}/pulls/{PR}":
            return WireResponse(200, self.pull())
        if path.startswith(f"{root}/git/ref/heads/"):
            return WireResponse(200, maybe_mutate({"ref": "refs/heads/main", "object": {"type": "commit", "sha": pick(HEADS + ["F" * 40])}}, 0.2))
        if path.startswith(f"{root}/rules/branches/"):
            if rng.random() < 0.35:
                return WireResponse(404, {"message": "Not Found"})
            return WireResponse(200, self.rules())
        if path.startswith(f"{root}/branches/") and path.endswith("/protection"):
            roll = rng.random()
            if roll < 0.3:
                return WireResponse(404, {"message": "Not Found"})
            return WireResponse(200, self.protection())
        if path == f"{root}/pulls/{PR}/requested_reviewers":
            return WireResponse(
                200,
                maybe_mutate({"users": [{"login": pick(["alice", "Bob", "carol"])} for _ in range(rng.randrange(4))], "teams": []}, 0.3),
            )
        if path.startswith(f"{root}/compare/"):
            return WireResponse(
                200,
                maybe_mutate({"status": pick(["ahead", "behind", "diverged", "identical"]), "behind_by": pick([0, 0, 1, 3])}, 0.35),
            )
        if "/actions/workflows/" in path:
            return self.collection(path, "workflow_runs", self.run_value)
        if "/actions/runs/" in path and "/jobs" in path:
            return self.collection(path, "jobs", self.job_value)
        return WireResponse(404, {"message": "Not Found"})

    def pull(self) -> Any:
        value = {
            "state": pick(["open", "closed", "open"]),
            "draft": pick([True, False, 0, "yes"]),
            "head": {"sha": pick([self.runs_head] * 4 + HEADS + ["A" * 40]), "ref": pick(["topic", "feature/x"]), "repo": {"full_name": "owner/repo"}},
            "base": {"sha": pick(HEADS), "ref": pick(["main", "release/1.0", "ünï code", "a b%"])},
            "mergeable": pick([True, False, None]),
            "merged": pick([False, True, None]),
            "user": {"login": pick(["author", "Someone"])},
            "html_url": f"https://github.com/{REPO}/pull/{PR}",
            "mergeable_state": pick(["clean", "dirty", "unknown"]),
        }
        if rng.random() < 0.2:
            del value["mergeable_state"]
        if rng.random() < 0.1 * damage[0]:
            value["head"] = pick([None, [], "x", 5])
        return maybe_mutate(value, 0.35, 0.25)

    def rules(self) -> Any:
        rules = []
        for _ in range(rng.randrange(4)):
            if rng.random() < 0.5:
                rules.append(
                    {
                        "type": "required_status_checks",
                        "parameters": {
                            "strict_required_status_checks_policy": pick([True, False]),
                            "required_status_checks": [{"context": pick(["ci", "lint", "Zeta", "ünï"])} for _ in range(rng.randrange(3))],
                        },
                    }
                )
            elif rng.random() < 0.7:
                rules.append(
                    {
                        "type": "pull_request",
                        "parameters": {
                            "required_approving_review_count": pick([0, 1, 2]),
                            "required_review_thread_resolution": pick([True, False]),
                        },
                    }
                )
            else:
                rules.append({"type": pick(["deletion", "non_fast_forward"]), "parameters": pick([None, {}])})
        return maybe_mutate(rules, 0.3, 0.2)

    def protection(self) -> Any:
        value: dict[str, Any] = {}
        if rng.random() < 0.8:
            value["required_status_checks"] = {"strict": pick([True, False]), "contexts": [pick(["ci", "lint"]) for _ in range(rng.randrange(3))]}
        if rng.random() < 0.8:
            value["required_pull_request_reviews"] = {"required_approving_review_count": pick([0, 1, 3])}
        if rng.random() < 0.6:
            value["required_conversation_resolution"] = {"enabled": pick([True, False])}
        if rng.random() < 0.15:
            value[pick(["required_status_checks", "required_pull_request_reviews", "required_conversation_resolution"])] = None
        return maybe_mutate(value, 0.3, 0.2)

    def reviews(self) -> list[dict[str, Any]]:
        values = []
        for index in range(rng.randrange(6)):
            review: dict[str, Any] = {
                "id": pick([index + 1, index + 1, 50 - index]),
                "user": {"login": pick(["alice", "Bob", "carol", ""])},
                "state": pick(["APPROVED", "approved", "CHANGES_REQUESTED", "DISMISSED", "COMMENTED", "straße"]),
                "submitted_at": pick(["2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", None]),
            }
            if rng.random() < 0.15:
                del review[pick(["id", "submitted_at", "user", "state"])]
            values.append(maybe_mutate(review, 0.12, 0.2))
        return [value for value in values if isinstance(value, dict)]

    def run_value(self, index: int) -> Any:
        if not damage[0]:
            return {
                "id": pick([1, 2, 3, index + 1]),
                "head_sha": pick([self.runs_head] * 3 + [rng.choice(HEADS)]),
                "path": pick([".github/workflows/ci.yml", "ci.yml"]),
                "run_attempt": pick([1, 2]),
                "event": "pull_request",
                "pull_requests": pick([[{"number": PR}], [{"number": PR}, {"number": 9}], [{"number": 8}]]),
                "status": pick(["completed", "in_progress", "queued"]),
                "conclusion": pick(["success", "failure", None, "skipped", "cancelled"]),
            }
        return {
            "id": pick([index + 1, index + 1, 3]),
            "head_sha": pick([self.runs_head, self.runs_head, self.runs_head.upper(), rng.choice(HEADS)]),
            "path": pick([".github/workflows/ci.yml", "ci.yml", ".github/workflows/other.yml"]),
            "run_attempt": pick([1, 2, 1]),
            "event": pick(["pull_request", "pull_request", "push"]),
            "pull_requests": pick([[{"number": PR}], [{"number": PR}], [], [{"number": 8}], [{"number": PR}, {"number": 9}]]),
            "status": pick(["completed", "in_progress", "queued"]),
            "conclusion": pick(["success", "failure", None, "skipped", "cancelled", ""]),
        }

    def job_value(self, index: int) -> Any:
        if not damage[0]:
            return {
                "id": index + 10,
                "name": pick(["build", "test", "lint", "ci"]),
                "status": pick(["completed", "in_progress"]),
                "conclusion": pick(["success", "failure", None, "skipped", "neutral"]),
            }
        return {
            "id": pick([index + 10, index + 10, 0]),
            "name": pick(["build", "test", "lint", "ci", ""]),
            "status": pick(["completed", "in_progress"]),
            "conclusion": pick(["success", "failure", None, "skipped", "neutral"]),
        }

    def collection(self, path: str, field: str, make: Any) -> WireResponse:
        count = rng.randrange(4) if damage[0] else rng.randrange(1, 5)
        values = [maybe_mutate(make(index), 0.15, 0.2) for index in range(count)]
        total = pick([count] * 8 + [count + 1, -1, "3"]) if damage[0] else count
        next_path = None
        roll = rng.random() / max(damage[0], 0.01)
        if roll < 0.06:
            next_path = path
        elif roll < 0.18:
            next_path = path + "&page=2" if "&page=" not in path else path.replace("&page=", "&page=1")
        body: Any = {"total_count": total, field: values}
        if next_path is not None and not damage[0]:
            next_path = None
        return WireResponse(200, maybe_mutate(body, 0.05, 0.2), next_path)

    def graphql(self, body: Any) -> WireResponse:
        query = body.get("query", "")
        if "reviewThreads" in query:
            return self.threads_page(body)
        if "resolveReviewThread" in query:
            thread = body["variables"]["thread"]
            reply = {"data": {"resolveReviewThread": {"thread": {"id": thread, "isResolved": True}}}}
            return WireResponse(pick([200, 200, 200, 502]), maybe_mutate(reply, 0.2))
        if "updateRefs" in query:
            change = body["variables"]["input"]
            reply = {"data": {"updateRefs": {"clientMutationId": change["clientMutationId"]}}}
            if rng.random() < 0.2:
                reply = {"data": {"updateRefs": None}, "errors": [{"message": "stale"}]}
            return WireResponse(pick([200, 200, 200, 500]), maybe_mutate(reply, 0.2))
        reply = {"data": {"repository": {"id": pick(["R_1", "R_2"])}}}
        return WireResponse(pick([200, 200, 200, 404]), maybe_mutate(reply, 0.2))

    def threads_page(self, body: Any) -> WireResponse:
        nodes = []
        for index in range(rng.randrange(5)):
            operation = pick(["op1", "op-2", "x y"])
            head = pick(self.heads + ["d" * 40])
            first = {
                "viewerDidAuthor": pick([True, True, False, None]),
                "body": pick(
                    [
                        f"finding text\n\n<!-- hamsterdan:finding operation={operation} head={head} -->",
                        f"<!-- hamsterdan:finding operation={operation} head={head.upper()} -->",
                        "human comment",
                        f"x <!-- hamsterdan:finding operation= head={head} --> <!-- hamsterdan:finding operation=o head={head} -->",
                        5,
                    ]
                ),
            }
            node = {
                "id": f"T{index}",
                "isResolved": pick([False, False, True]),
                "comments": pick([{"nodes": [first]}, {"nodes": []}, {"nodes": [first, first]}, None]),
            }
            nodes.append(node)
        has_next = rng.random() < 0.2 and body["variables"].get("after") is None
        reply = {
            "data": {
                "repository": {
                    "pullRequest": {
                        "reviewThreads": {"nodes": nodes, "pageInfo": {"hasNextPage": has_next, "endCursor": pick(["c1", "", None]) if has_next else None}}
                    }
                }
            }
        }
        return WireResponse(pick([200, 200, 200, 200, 502]), maybe_mutate(reply, 0.1, 0.15))


def boundary_of(error: GitHubBoundaryError) -> dict[str, Any]:
    return {
        "message": str(error),
        "failure_class": error.failure_class,
        "provider_status": error.provider_status,
        "provider_detail": error.provider_detail,
    }


def encode(value: Any) -> Any:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return {field.name: encode(getattr(value, field.name)) for field in dataclasses.fields(value)}
    if isinstance(value, (list, tuple)):
        return [encode(item) for item in value]
    if isinstance(value, dict):
        return {key: encode(item) for key, item in value.items()}
    if isinstance(value, bytes):
        return {"fill": value[0] if value else 0, "length": len(value)}
    return value


def outcome_of(action: Any) -> dict[str, Any]:
    try:
        return {"ok": encode(action())}
    except GitHubBoundaryError as error:
        return {"error": {"class": type(error).__name__, **boundary_of(error)}}
    except AssertionError:
        raise
    except Exception as error:  # noqa: BLE001 - the class is the observation
        return {"error": {"class": type(error).__name__, "message": str(error)}}


# --- Operations ---------------------------------------------------------------


def profile() -> dict[str, float]:
    return {
        "raise": pick([0.0, 0.0, 0.05, 0.15]),
        "page_fail": pick([0.0, 0.0, 0.05, 0.2]),
        "fence_fail": pick([0.0, 0.0, 0.05, 0.3]),
        "fault_fail": pick([0.0, 0.1, 0.3]),
        "land": pick([0.3, 0.6, 0.9]),
        "bad_id": pick([0.0, 0.0, 0.05, 0.2]),
        "bad_status": pick([0.0, 0.0, 0.05, 0.15]),
    }


def snapshot_args(world: World) -> dict[str, Any]:
    return {
        "repository": REPO,
        "number": PR,
        "state": "open",
        "draft": False,
        "head": pick(world.heads),
        "base": pick(world.heads),
        "head_ref": "topic",
        "base_ref": "main",
        "mergeable": True,
        "merged": False,
        "closed": False,
        "author": "author",
        "mergeable_state": "clean",
        "url": "u",
        "head_repository": REPO,
    }


def run_args(world: World, with_jobs: bool) -> dict[str, Any]:
    jobs = []
    if with_jobs:
        for index in range(rng.randrange(4)):
            jobs.append(
                {
                    "id": index + 1,
                    "name": pick(["build", "test", "lint"]),
                    "status": pick(["completed", "in_progress"]),
                    "conclusion": pick(["success", "failure", None, "skipped"]),
                    "required": pick([True, False]),
                }
            )
    return {
        "id": pick([1, 2, 3]),
        "head": pick([world.runs_head] * (1 if damage[0] else 4) + world.heads),
        "workflow": pick(["ci.yml", ".github/workflows/ci.yml"]),
        "attempt": pick([1, 2]),
        "status": pick(["completed", "in_progress", "queued"]),
        "conclusion": pick(["success", "failure", None, "cancelled", ""]),
        "jobs": jobs,
    }


def to_run(value: dict[str, Any]) -> ActionsRunSnapshot:
    return ActionsRunSnapshot(
        value["id"],
        value["head"],
        value["workflow"],
        value["attempt"],
        value["status"],
        value["conclusion"],
        tuple(ActionsJobSnapshot(**job) for job in value["jobs"]),
    )


def finding_args(world: World, anchored: bool) -> dict[str, Any]:
    return {
        "operation": pick(["f1", "f2", "f.3", "bad op", "-x"]) if rng.random() < 0.1 else pick(["f1", "f2", "f3", "f4"]),
        "text": pick(["Possible bug", "Ünïcode text", "multi\nline"]),
        "path": pick(["src/a.py", "dir with space/b.py", "ü/c.py"]) if anchored or rng.random() < 0.5 else "",
        "line": pick([1, 12, 40]) if anchored or rng.random() < 0.5 else pick([0, -1]),
        "related_locations": [[pick(["src/x.py", "a b/c#d.py", "é.py"]), pick([1, 2])] for _ in range(pick([0, 0, 1, 2]))],
        "suggestion": pick(["", "", "fixed()"]),
        "link": pick(["", "https://example.invalid/doc"]),
    }


def to_finding(value: dict[str, Any]) -> FindingPublication:
    return FindingPublication(
        value["operation"],
        value["text"],
        value["path"],
        value["line"],
        tuple(tuple(item) for item in value["related_locations"]),
        value["suggestion"],
        value["link"],
    )


def row(op: str) -> dict[str, Any]:
    heads = rng.sample(HEADS, 2)
    clean = 0.6 if op in {"issue", "rerun_request", "workflow_runs", "select_run", "jobs", "actions_evidence"} else 0.3
    damage[0] = 0.0 if rng.random() < clean else 1.0
    world = World(heads, profile())
    args: dict[str, Any] = {"heads": heads}
    use_graphql = rng.random() < 0.7
    graphql = GitHubGraphQL(world) if use_graphql else None
    args["graphql"] = use_graphql
    authority = GitHubAuthority(world, REPO, PR, graphql=graphql)
    with_fault = rng.random() < 0.5
    args["fault"] = with_fault
    publisher = CommentPublisher(
        world, REPO, PR, BOT, world.fence, world.fault if with_fault else None, retry_delay=world.delay
    )
    action: Any

    if op == "authority":
        args["repository"] = pick(["owner/repo", "owner", "/repo", "owner/", "a/b/c", "o/r", ""])
        args["pr"] = pick([7, 0, -1, 1])

        def action() -> Any:
            built = GitHubAuthority(world, args["repository"], args["pr"])
            return {"owner": built.owner, "name": built.name, "root": built.root}
    elif op == "pull_request":
        action = authority.pull_request
    elif op == "policy":
        args["base_ref"] = pick(["main", "release/1.0", "ünï code", "a b%"])

        def action() -> Any:
            return authority.policy(args["base_ref"])
    elif op == "human_review":
        action = authority.human_review
    elif op == "resolve_stale":
        args["current_head"] = pick(heads + ["d" * 40])

        def action() -> Any:
            return authority.resolve_stale_finding_threads(args["current_head"])
    elif op == "base_current":
        args["pull"] = snapshot_args(world)

        def action() -> Any:
            return authority.base_current(PullRequestSnapshot(**args["pull"]))
    elif op == "comments":
        action = authority.comments
    elif op in {"workflow_runs", "select_run"}:
        args["workflow"] = pick(["ci.yml", ".github/workflows/ci.yml", "dir/ci yml"])
        args["head"] = pick([world.runs_head, world.runs_head, world.runs_head.upper(), "abc"])
        method = authority.workflow_runs if op == "workflow_runs" else authority.select_run

        def action() -> Any:
            return method(args["workflow"], args["head"])
    elif op in {"jobs", "actions_evidence"}:
        args["run"] = run_args(world, False)
        args["required"] = [pick(["build", "test", "lint", "ci"]) for _ in range(rng.randrange(4))]
        method = authority.jobs if op == "jobs" else authority.actions_evidence

        def action() -> Any:
            return method(to_run(args["run"]), args["required"])
    elif op == "run_result":
        args["run"] = run_args(world, True)

        def action() -> Any:
            return authority.run_result(to_run(args["run"]))
    elif op == "failure_logs":
        args["run"] = run_args(world, False)

        def action() -> Any:
            return authority.failure_logs(to_run(args["run"]), world)
    elif op == "create_tree":
        args["base_tree"] = pick(heads)
        args["entries"] = [
            [pick(["a.txt", "dir/b.bin", "ü.md"]), pick(["100644", "100755", "120000"]), pick([None, "", "aGVsbG8=", "AAEC/w=="])]
            for _ in range(rng.randrange(4))
        ]

        def action() -> Any:
            return authority.create_tree(
                base_tree=args["base_tree"],
                entries=[(p, m, None if c is None else base64.b64decode(c)) for p, m, c in args["entries"]],
            )
    elif op == "create_commit":
        args["tree"] = pick(heads)
        args["parents"] = [pick(heads) for _ in range(pick([0, 1, 2]))]
        args["message"] = pick(["Fix", "Ünïcode\n\nbody"])
        args["name"] = pick(["Hamsterdan", "Dan Bot"])
        args["email"] = pick(["bot@example.invalid"])

        def action() -> Any:
            return authority.create_commit(
                tree=args["tree"], parents=args["parents"], message=args["message"], name=args["name"], email=args["email"]
            )
    elif op == "review_threads":
        args["owner"], args["name"] = pick([["owner", "repo"], ["o", "r"]])

        def action() -> Any:
            return list(GitHubGraphQL(world).review_threads(args["owner"], args["name"], PR))
    elif op == "resolve_thread":
        args["thread"] = pick(["T1", "PRRT_x", ""])

        def action() -> Any:
            return GitHubGraphQL(world).resolve_review_thread(args["thread"])
    elif op == "cas_ref":
        args["repository"] = pick(["owner/repo", "owner/repo", "bad", "a/b/c"])
        args["ref"] = pick(["refs/heads/topic", "refs/heads/topic", "topic", "refs/heads/"])
        args["expected"] = pick(heads + ["A" * 40, "short"])
        args["commit"] = pick(heads)

        def action() -> Any:
            return GitHubGraphQL(world).compare_and_swap_ref(args["repository"], args["ref"], args["expected"], args["commit"])
    elif op == "publisher":
        args["bot_login"] = pick([BOT, " Hamsterdan[BOT] ", "hamsterdan", "", "  ", "x[bot]"])

        def action() -> Any:
            built = CommentPublisher(world, REPO, PR, args["bot_login"], world.fence)
            return {"bot_login": built.bot_login, "root": built.root}
    elif op == "marker":
        args["kind"] = pick(["conversation", "finding", "readiness", "reminder", "dashboard", ""])
        args["operation"] = pick(["op", "a" * 128, "a" * 129, "op.1:x-y_z", "-op", "op space", "ü", "op\n"])
        args["head"] = pick(HEADS + BAD_HEADS)

        def action() -> Any:
            return CommentPublisher.marker(args["kind"], args["operation"], args["head"])
    elif op in {"immutable", "find"}:
        args["kind"] = pick(["conversation", "readiness", "reminder", "finding", "bogus"]) if rng.random() < 0.1 else pick(["conversation", "readiness"])
        args["operation"] = pick(["op1", "op2"])
        args["epoch"] = pick([1, 5])
        args["head"] = pick(heads) if rng.random() < 0.95 else pick(BAD_HEADS)
        args["body"] = pick(["Hello", "Ünïcode body", "multi\n\nparagraph"])
        args["compatible"] = [pick(["Legacy hello", "Old"]) for _ in range(pick([0, 0, 1, 2]))]
        args["authority_operation"] = pick([None, None, "auth-op", ""])
        marker = f"<!-- hamsterdan:{args['kind']} operation={args['operation']} head={args['head']} -->"
        world.seed_comments([marker], [f"{body}\n\n{marker}" for body in [args["body"], *args["compatible"]]])
        if op == "immutable":

            def action() -> Any:
                return publisher.immutable(
                    args["kind"],
                    args["operation"],
                    args["epoch"],
                    args["head"],
                    args["body"],
                    authority_operation=args["authority_operation"],
                    compatible_bodies=tuple(args["compatible"]),
                )
        else:

            def action() -> Any:
                return publisher.find(
                    args["kind"], args["operation"], args["head"], args["body"], compatible_bodies=tuple(args["compatible"])
                )
    elif op == "immutable_operation":
        args["kind"] = pick(["conversation", "readiness"])
        args["operation"] = pick(["op1", "op2"]) if rng.random() < 0.9 else pick(["bad op", "op+"])
        args["body"] = pick(["Hello", "Reply ü"])
        args["compatible"] = [pick(["Legacy hello"]) for _ in range(pick([0, 1]))]
        args["context"] = [pick([1, 2]), pick(heads)]
        for held in heads:
            marker = f"<!-- hamsterdan:{args['kind']} operation={args['operation']} head={held} -->"
            world.seed_comments([marker], [f"{body}\n\n{marker}" for body in [args["body"], *args["compatible"]]])

        def action() -> Any:
            return publisher.immutable_operation(
                args["kind"],
                args["operation"],
                args["body"],
                context=lambda: world.context(args["context"]),
                compatible_bodies=tuple(args["compatible"]),
            )
    elif op == "reminder_operation":
        args["operation"] = pick(["r1", "r2"])
        args["context"] = [pick([1, 2]), pick(heads), pick([None, "reviewer", "@@rev", ""]), pick(["author", "@author"])]
        for held in heads:
            marker = f"<!-- hamsterdan:reminder operation={args['operation']} head={held} -->"
            world.seed_comments([marker], [f"@x, body\n\n{marker}"])
        if rng.random() < 0.5:
            world.issue_comments.append(world.comment("Board\n\n<!-- hamsterdan:dashboard -->"))

        def action() -> Any:
            return publisher.reminder_operation(args["operation"], context=lambda: world.context(args["context"]))
    elif op == "reminder":
        args["operation"] = pick(["r1", "r2"])
        args["epoch"] = pick([1, 2])
        args["head"] = pick(heads)
        args["reviewer"] = pick([None, "reviewer", "@rev", ""])
        args["author"] = pick(["author", "@author"])
        args["maintainer"] = pick([None, "maint", ""])
        if rng.random() < 0.6:
            board = world.comment("Board\n\n<!-- hamsterdan:dashboard -->")
            if rng.random() < 0.3:
                board["html_url"] = pick([None, "", 5])
            world.issue_comments.append(board)
        marker = f"<!-- hamsterdan:reminder operation={args['operation']} head={args['head']} -->"
        world.seed_comments([marker], [])

        def action() -> Any:
            return publisher.reminder(
                args["operation"],
                args["epoch"],
                args["head"],
                reviewer=args["reviewer"],
                author=args["author"],
                maintainer=args["maintainer"],
            )
    elif op == "dashboard":
        args["operation"] = pick(["board", "board-2"])
        args["epoch"] = pick([1, 3])
        args["head"] = pick(heads)
        args["body"] = pick(["Ready", "Not ready ü"])
        marker = "<!-- hamsterdan:dashboard -->"
        roll = rng.random()
        if roll < 0.3:
            world.issue_comments.append(world.comment(f"{args['body']}\n\n{marker}"))
        elif roll < 0.65:
            world.issue_comments.append(world.comment(f"Older board\n\n{marker}"))
        elif roll < 0.7:
            world.issue_comments.append(world.comment(f"Older board\n\n{marker}", "someone"))

        def action() -> Any:
            return publisher.dashboard(args["operation"], args["epoch"], args["head"], args["body"])
    elif op in {"finding", "finding_find"}:
        args["finding"] = finding_args(world, False)
        args["epoch"] = pick([1, 2])
        args["head"] = pick(heads) if rng.random() < 0.95 else pick(BAD_HEADS)
        args["authority_operation"] = pick([None, "batch-op"])
        finding = to_finding(args["finding"])
        try:
            content = publisher._finding_content(finding, args["head"])
            world.seed_comments(
                [content.marker], [content.inline_payload, content.fallback_payload, content.legacy_payload]
            )
        except ValueError:
            pass
        if op == "finding":

            def action() -> Any:
                f = args["finding"]
                return publisher.finding(
                    f["operation"],
                    args["epoch"],
                    args["head"],
                    f["text"],
                    path=f["path"],
                    line=f["line"],
                    related_locations=tuple(tuple(item) for item in f["related_locations"]),
                    suggestion=f["suggestion"],
                    link=f["link"],
                    authority_operation=args["authority_operation"],
                )
        else:

            def action() -> Any:
                return publisher.finding_find(args["finding"]["operation"], args["head"])
    elif op == "findings":
        args["findings"] = [finding_args(world, rng.random() < 0.95) for _ in range(pick([0, 1, 2, 3, 3]))]
        args["epoch"] = pick([1, 2])
        args["head"] = pick(heads)
        args["authority_operation"] = pick(["batch-op", "review"])
        for value in args["findings"]:
            try:
                content = publisher._finding_content(to_finding(value), args["head"])
                world.seed_comments([content.marker], [content.inline_payload, content.fallback_payload])
            except ValueError:
                pass

        def action() -> Any:
            return publisher.findings(
                args["epoch"],
                args["head"],
                tuple(to_finding(value) for value in args["findings"]),
                authority_operation=args["authority_operation"],
            )
    elif op in {"held", "issue", "rerun_request"}:
        args["run"] = run_args(world, False)
        args["epoch"] = pick([1, 2])
        args["operation"] = pick(["rerun-1", "rerun-2"])
        broker = CommentRerunBroker(authority, publisher)
        run = to_run(args["run"])
        if rng.random() < 0.3:
            item = world.comment(CommentRerunBroker.marker(run.id, run.head, args["operation"]))
            world.issue_comments.append(item)
        if op == "held":

            def action() -> Any:
                return broker.held(run.id, run.head, args["operation"])
        elif op == "issue":

            def action() -> Any:
                return broker.issue(run, epoch=args["epoch"], operation=args["operation"])
        else:

            def action() -> Any:
                return broker.request(run, epoch=args["epoch"], operation=args["operation"])
    else:
        raise AssertionError(op)

    world.events.clear()
    outcome = outcome_of(action)
    return {"op": op, "args": args, "events": world.events, "outcome": outcome}


OPS = {
    "authority": 40,
    "pull_request": 260,
    "policy": 220,
    "human_review": 220,
    "resolve_stale": 120,
    "base_current": 100,
    "comments": 30,
    "workflow_runs": 200,
    "select_run": 60,
    "jobs": 160,
    "actions_evidence": 160,
    "run_result": 100,
    "failure_logs": 50,
    "create_tree": 120,
    "create_commit": 60,
    "review_threads": 120,
    "resolve_thread": 60,
    "cas_ref": 100,
    "publisher": 30,
    "marker": 80,
    "immutable": 260,
    "find": 80,
    "immutable_operation": 120,
    "reminder_operation": 100,
    "reminder": 120,
    "dashboard": 200,
    "finding": 260,
    "finding_find": 60,
    "findings": 260,
    "held": 40,
    "issue": 160,
    "rerun_request": 60,
}


def main() -> None:
    rows = []
    for op, count in OPS.items():
        for _ in range(count):
            rows.append(row(op))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as handle:
        for value in rows:
            handle.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"wrote {len(rows)} rows to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
