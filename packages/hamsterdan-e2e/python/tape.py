"""The tier B tape: what one Hamsterdan host run exchanged with the world.

Standard library only (Python 3.9 or later), so the replay server, the
comparators and the scripts run outside the reference's environment too.

A tape is a directory of JSON Lines files, one record per line, written in
the order things happened. Records keep the member order of the values they
carry (an agent's findings reach History in that order), so readers must
not reorder them:

``meta.json``
    ``{"format": FORMAT, "source": ..., "config": {...}}``. ``config`` is
    the host configuration the replay needs: ``app_id``, ``app_slug``,
    ``client_id``, ``accounts`` (``[[account_id, login, [[repository_id,
    full_name], ...]], ...]``), ``workflow_path``, ``reminder_seconds`` and
    ``replay_webhook_secret``. No real secret is ever stored: replays sign
    every delivery again with ``replay_webhook_secret`` (the custody keeps no
    signature), and authenticate to the replay server with any App key.

``github.jsonl``
    One record per ``Transport.request`` the host made through its
    ``transport_factory``: ``seq``, ``method``, ``path``, ``body`` (the JSON
    value or ``null``), ``status``, ``response`` (the JSON value or
    ``null``), ``next`` (the ``Link rel="next"`` path or ``null``) and
    ``context`` (``host``, or ``publisher`` for the requests the Git
    publisher made). A request that failed at the boundary has ``error``
    instead of a response. App and installation token requests are not on
    the tape: githubkit makes them below the transport, and the replay server
    answers them itself.

``steps.jsonl``
    What drove the host, in order. ``{"op": "registry", "inventories":
    [[installation_id, account_id, [[repository_id, full_name], ...]], ...]}``;
    ``{"op": "deliver", "delivery": uuid, "event": name, "headers": [[k, v],
    ...], "body": text, "disposition": ...}`` (headers without the
    signature); ``{"op": "process", "delivery": uuid}``; ``{"op": "pump",
    "limit": n, "processed": n}``; ``{"op": "converge"}`` (pump until
    quiescent; what a webhook tee records, since a live host pumps on its
    own clock); ``{"op": "close"}``. Every step carries ``clock``, the host
    clock when it started.

``agents.jsonl``
    One record per ``AgentRunner`` call, keyed by ``kind`` (``review``,
    ``converse`` or ``code``), ``operation`` and ``attempt``: the
    ``repository_url``, the ``request`` (``dataclasses.asdict``), the
    values ``is_current()`` returned during the call, in order, and the
    ``result`` (``asdict``) or the ``error``.

``publisher.jsonl``
    One record per Git publisher call (``reconcile`` or ``publish``) with its
    keyword ``arguments`` (``publish`` also has ``result``, the coding
    result) and its ``outcome`` (``asdict``) or ``error``.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import threading
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple

FORMAT = "hamsterdan-e2e-tape/1"
FILES = ("github.jsonl", "steps.jsonl", "agents.jsonl", "publisher.jsonl")
SIGNATURE_HEADER = "x-hub-signature-256"


def canonical(value: Any) -> str:
    """The identity of a JSON value: sorted keys, compact separators."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def body_key(raw: bytes) -> str:
    """The identity of a request body as sent: its JSON value, or empty."""
    if not raw:
        return ""
    return canonical(json.loads(raw.decode("utf-8")))


def sign(secret: str, body: bytes) -> str:
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def signed_headers(headers: List[List[str]], secret: str, body: bytes) -> List[Tuple[str, str]]:
    """The recorded headers with a fresh signature, in their recorded order."""
    kept = [(str(name), str(value)) for name, value in headers if str(name).lower() != SIGNATURE_HEADER]
    return kept + [(SIGNATURE_HEADER, sign(secret, body))]


def unsigned(headers: Any) -> List[List[str]]:
    return [[str(name), str(value)] for name, value in headers if str(name).lower() != SIGNATURE_HEADER]


class TapeWriter:
    """Append-only writer of one tape directory, safe across threads (a live
    host receives webhooks and pumps on different threads)."""

    def __init__(self, root: Path, meta: Dict[str, Any]) -> None:
        self.root = root
        self._lock = threading.Lock()
        root.mkdir(parents=True, exist_ok=True)
        (root / "meta.json").write_text(json.dumps({"format": FORMAT, **meta}, sort_keys=True, indent=1) + "\n")
        self._handles = {name: (root / name).open("a", encoding="utf-8") for name in FILES}
        self._counts = {name: sum(1 for _ in (root / name).open(encoding="utf-8")) for name in FILES}

    def append(self, name: str, record: Dict[str, Any]) -> int:
        with self._lock:
            sequence = self._counts[name]
            self._counts[name] = sequence + 1
            handle = self._handles[name]
            handle.write(json.dumps({"seq": sequence, **record}, ensure_ascii=False) + "\n")
            handle.flush()
            return sequence

    def counts(self) -> Tuple[int, ...]:
        with self._lock:
            return tuple(self._counts[name] for name in FILES)

    def close(self) -> None:
        with self._lock:
            for handle in self._handles.values():
                handle.close()


def read_meta(root: Path) -> Dict[str, Any]:
    meta = json.loads((root / "meta.json").read_text())
    if meta.get("format") != FORMAT:
        raise SystemExit(f"{root}: not a {FORMAT} tape")
    return meta


def read(root: Path, name: str) -> List[Dict[str, Any]]:
    path = root / name
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def is_mutation(method: str, path: str, body: Any) -> bool:
    """A write: every POST or PATCH except GraphQL queries."""
    if method not in ("POST", "PATCH"):
        return False
    if path == "/graphql":
        query = body.get("query", "") if isinstance(body, dict) else ""
        return query.lstrip().startswith("mutation")
    return True


# ---------------------------------------------------------------------------
# The final comment set, from the writes and the answers they got


def comment_set(exchanges: List[Tuple[str, str, Any, Any]]) -> Dict[str, Any]:
    """The App's comments as GitHub would show them after these writes.

    ``exchanges`` are ``(method, path, request body, response body)`` in
    order. Issue comments are keyed by the id GitHub answered with, and
    edits replace their body; review comments and reviews keep their
    anchors. Rerun markers are issue comments like any other.
    """
    issue: Dict[str, str] = {}
    review_comments: List[Dict[str, Any]] = []
    reviews: List[Dict[str, Any]] = []
    resolved: List[str] = []
    refs: List[Dict[str, Any]] = []
    for method, path, body, response in exchanges:
        parts = path.split("?")[0].strip("/").split("/")
        if method == "POST" and parts[-1] == "comments" and "issues" in parts:
            identity = str(response.get("id")) if isinstance(response, dict) else "?"
            issue[identity] = str(body.get("body", ""))
        elif method == "PATCH" and len(parts) >= 2 and parts[-2] == "comments" and "issues" in parts:
            issue[parts[-1]] = str(body.get("body", ""))
        elif method == "POST" and parts[-1] == "comments" and "pulls" in parts:
            review_comments.append({key: body.get(key) for key in ("path", "line", "side", "commit_id", "body")})
        elif method == "POST" and parts[-1] == "reviews":
            reviews.append(
                {
                    "event": body.get("event"),
                    "commit_id": body.get("commit_id"),
                    "body": body.get("body"),
                    "comments": [
                        {key: item.get(key) for key in ("path", "line", "side", "body")} for item in body.get("comments", [])
                    ],
                }
            )
        elif method == "POST" and path == "/graphql" and isinstance(body, dict):
            variables = body.get("variables") or {}
            if "resolveReviewThread" in str(body.get("query")):
                resolved.append(str(variables.get("thread")))
            elif "updateRefs" in str(body.get("query")):
                refs.extend((variables.get("input") or {}).get("refUpdates") or [])
    return {
        "issue_comments": [{"id": key, "body": value} for key, value in issue.items()],
        "review_comments": review_comments,
        "reviews": reviews,
        "resolved_threads": resolved,
        "ref_updates": refs,
    }


def render_comments(comments: Dict[str, Any]) -> str:
    """The comment set as one Markdown page, for reading and for diffing."""
    out: List[str] = []
    for item in comments["issue_comments"]:
        out.append(f"## issue comment {item['id']}\n\n{item['body']}\n")
    for index, item in enumerate(comments["reviews"], start=1):
        out.append(f"## review {index} ({item['event']} on {item['commit_id']})\n\n{item['body']}\n")
        for comment in item["comments"]:
            out.append(f"### {comment['path']}:{comment['line']} ({comment['side']})\n\n{comment['body']}\n")
    for item in comments["review_comments"]:
        out.append(f"## review comment {item['path']}:{item['line']} ({item['side']} on {item['commit_id']})\n\n{item['body']}\n")
    for thread in comments["resolved_threads"]:
        out.append(f"## resolved thread {thread}\n")
    for update in comments["ref_updates"]:
        out.append(f"## ref update {update.get('name')} {update.get('beforeOid')} -> {update.get('afterOid')}\n")
    return "\n".join(out)


def tape_exchanges(tape: List[Dict[str, Any]], contexts: Optional[Tuple[str, ...]] = None) -> Iterator[Dict[str, Any]]:
    for record in tape:
        if contexts is None or record.get("context", "host") in contexts:
            yield record


# ---------------------------------------------------------------------------
# Agent results across repositories (tier C)


def _hex(segment: str, length: int) -> bool:
    return len(segment) == length and all(c in "0123456789abcdef" for c in segment)


def _uuid(segment: str) -> bool:
    parts = segment.split("-")
    return [len(part) for part in parts] == [8, 4, 4, 4, 12] and all(_hex(part, len(part)) for part in parts)


def operation_shape(operation: str) -> str:
    """An agent operation without what differs between two repositories.

    The operation is split on ``:``; a segment holding ``/`` (a repository
    full name) becomes ``<repository>``, 40 hexadecimal digits ``<sha>``, 64
    ``<digest>``, a UUID ``<uuid>``, and decimal digits ``<n>`` (installation,
    repository, pull request and comment ids). ``review:github:44:31:pr:7:
    <40 hex>:i1`` becomes ``review:github:<n>:<n>:pr:<n>:<sha>:i1``. The
    Haskell twin is ``Hamsterdan.E2E.Agents.operationShape``.
    """
    shaped = []
    for segment in operation.split(":"):
        if "/" in segment:
            shaped.append("<repository>")
        elif _hex(segment, 40):
            shaped.append("<sha>")
        elif _hex(segment, 64):
            shaped.append("<digest>")
        elif _uuid(segment):
            shaped.append("<uuid>")
        elif segment.isascii() and segment.isdigit():
            shaped.append("<n>")
        else:
            shaped.append(segment)
    return ":".join(shaped)


CORRELATION = ("kind", "repository", "pull_request", "epoch", "head", "base", "ref")


def _replace_strings(value: Any, replacements: List[Tuple[str, str]]) -> Any:
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [_replace_strings(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: _replace_strings(item, replacements) for key, item in value.items()}
    return value


def carry_result(recorded_request: Dict[str, Any], request: Dict[str, Any], result: Dict[str, Any]) -> Dict[str, Any]:
    """A recorded agent result answering an equivalent request elsewhere.

    Every string the recorded request's ``repository``, ``head``, ``base``
    and ``ref`` held is replaced, wherever it appears in the result, by the
    new request's (longest first), and the result's correlation members
    (``CORRELATION``) are the new request's. The Haskell twin is
    ``Hamsterdan.E2E.Agents.carryResult``.
    """
    pairs = {
        str(recorded_request[name]): str(request[name])
        for name in ("repository", "head", "base", "ref")
        if isinstance(recorded_request.get(name), str)
        and isinstance(request.get(name), str)
        and recorded_request[name]
        and recorded_request[name] != request[name]
    }
    replacements = sorted(pairs.items(), key=lambda pair: (-len(pair[0]), pair[0]))
    carried = _replace_strings(result, replacements)
    for name in CORRELATION:
        if name in carried and name in request:
            carried[name] = request[name]
    return carried
