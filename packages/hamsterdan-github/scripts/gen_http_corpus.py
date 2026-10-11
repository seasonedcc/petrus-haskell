"""Generate the HTTP-level client differential corpus.

Run with the pinned reference environment from the repository root:

    upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_http_corpus.py

Every row builds one ``GitHubAppClients`` from ``upstream/hamsterdan`` over
``httpx.MockTransport`` with a frozen, scripted clock, and drives it through
a sequence of ``GitHubKitTransport`` requests, downloads and page reads
(and, sometimes, the registration inventory check). The mock answers each
wire request with a randomly generated response: installation-token mints
with valid and malformed expiries, rate-limit rejections, cacheable and
revalidated responses, redirects, compressed and malformed bodies, odd
header bytes and transport failures.

The row records every wire exchange in order (method, URL, ordered request
headers and body bytes; status, raw response headers and body chunks), every
metadata-hook observation, and each step's outcome. The Haskell suite drives
its own client stack through the same steps over a scripted exchange and
must send byte-identical requests and reach identical outcomes.

The App key is the throwaway test key committed next to the corpus; it signs
nothing outside this corpus. No credential or real payload is involved.
"""

from __future__ import annotations

import base64
import datetime as _datetime
import functools
import gzip
import hashlib
import json
import random
import sys
import time
import zlib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "upstream" / "hamsterdan" / "src"))

import githubkit.auth.app  # noqa: E402
import githubkit.cache.mem_cache  # noqa: E402
import httpx  # noqa: E402
import jwt.algorithms  # noqa: E402

from hamsterdan.github_app.auth import GitHubAppClients  # noqa: E402
from hamsterdan.github_app.config import AccountConfig, HostConfig  # noqa: E402
from hamsterdan.github_app.models import GitHubBoundaryError  # noqa: E402
from hamsterdan.github_app.transport import GitHubKitTransport  # noqa: E402

SEED = 20261014
OUT = ROOT / "packages" / "hamsterdan-github" / "test" / "corpus" / "http.jsonl"
KEY = ROOT / "packages" / "hamsterdan-github" / "test" / "corpus" / "app-test-key.pem"
ROWS = 1400
rng = random.Random(SEED)

# --- The frozen clock -------------------------------------------------------

CLOCK = [1_760_000_000.0]


class FrozenDatetime(_datetime.datetime):
    @classmethod
    def now(cls, tz: Any = None) -> Any:  # noqa: ANN401
        return _datetime.datetime.fromtimestamp(CLOCK[0], tz)


githubkit.auth.app.datetime = FrozenDatetime  # type: ignore[attr-defined, misc]
githubkit.cache.mem_cache.datetime = FrozenDatetime  # type: ignore[attr-defined, misc]
time.time = lambda: CLOCK[0]

# Every row mints its App JWT from the same committed key, and parsing (and
# validating) the PEM dominates the run; PKCS#1 v1.5 signing is
# deterministic, so one parsed key signs exactly what a fresh parse would.
jwt.algorithms.load_pem_private_key = functools.lru_cache(maxsize=None)(jwt.algorithms.load_pem_private_key)


def pick(values: list[Any]) -> Any:
    return rng.choice(values)


def iso(seconds: float) -> str:
    return _datetime.datetime.fromtimestamp(seconds, _datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def http_date(seconds: float) -> str:
    return _datetime.datetime.fromtimestamp(seconds, _datetime.UTC).strftime("%a, %d %b %Y %H:%M:%S GMT")


# --- Wire recording ---------------------------------------------------------


class ScriptedStream(httpx.SyncByteStream):
    def __init__(self, chunks: list[bytes], failure: str | None) -> None:
        self.chunks = chunks
        self.failure = failure

    def __iter__(self) -> Any:  # noqa: ANN401
        yield from self.chunks
        if self.failure is not None:
            raise httpx.ReadError(self.failure)

    def close(self) -> None:
        pass


def body_spec(content: bytes) -> dict[str, Any]:
    if len(content) > 4096:
        return {"sha256": hashlib.sha256(content).hexdigest(), "length": len(content)}
    return {"b64": base64.b64encode(content).decode()}


def chunk_spec(chunk: bytes) -> dict[str, Any]:
    if len(chunk) > 4096 and chunk == chunk[:1] * len(chunk):
        return {"fill": chunk[0], "length": len(chunk)}
    return {"b64": base64.b64encode(chunk).decode()}


class Wire:
    def __init__(self) -> None:
        self.exchanges: list[dict[str, Any]] = []
        self.revalidations: dict[str, int] = {}

    def handler(self, request: httpx.Request) -> httpx.Response:
        record: dict[str, Any] = {
            "method": request.method,
            "url": str(request.url),
            "headers": [[k.decode("latin-1"), v.decode("latin-1")] for k, v in request.headers.raw],
            "body": body_spec(request.content),
        }
        exchange: dict[str, Any] = {"request": record}
        self.exchanges.append(exchange)
        if rng.random() < 0.03:
            exchange["raise"] = pick(["ConnectError", "ReadTimeout"])
            raise getattr(httpx, exchange["raise"])("scripted network failure", request=request)
        if request.url.path.endswith("/access_tokens"):
            status, headers, body = mint_response(request)
        else:
            status, headers, body = generic_response(request, self)
        chunks = split(body)
        failure = "scripted read failure" if rng.random() < 0.02 else None
        exchange["response"] = {
            "status": status,
            "headers": [[k.decode("latin-1"), v.decode("latin-1")] for k, v in headers],
            "chunks": [chunk_spec(chunk) for chunk in chunks],
            "failure": failure,
        }
        return httpx.Response(status, headers=headers, stream=ScriptedStream(chunks, failure))


def split(body: bytes) -> list[bytes]:
    if not body:
        return [] if rng.random() < 0.7 else [b""]
    if len(body) > 4096 and body == body[:1] * len(body):
        return [body]
    cuts = sorted(rng.sample(range(1, len(body)), min(len(body) - 1, pick([0, 0, 1, 2]))))
    pieces = []
    start = 0
    for cut in [*cuts, len(body)]:
        pieces.append(body[start:cut])
        start = cut
    return pieces


# --- Responses ----------------------------------------------------------------


def mint_response(request: httpx.Request) -> tuple[int, list[tuple[bytes, bytes]], bytes]:
    now = CLOCK[0]
    headers: list[tuple[bytes, bytes]] = [(b"Content-Type", b"application/json; charset=utf-8")]
    roll = rng.random()
    if roll < 0.08:
        status = pick([403, 429])
        if rng.random() < 0.5:
            headers.append((b"Retry-After", pick([b"5", b"x", b"99999999999999999", b" 7 ", b"-3"])))
        else:
            headers.append((b"X-RateLimit-Remaining", pick([b"0", b"0", b"1"])))
            headers.append(
                (b"X-RateLimit-Reset", pick([b"1760003600", b"x", b"99999999999999999999", b"-1", b"253402300800", b"67768036191676800"]))
            )
        body = pick(
            [
                b'{"message":"You have exceeded a secondary rate limit"}',
                b'{"message":"API rate limit exceeded"}',
                b'{"message":["secondary rate"]}',
                b'{"message":{"secondary rate":1}}',
                b'{"message":5}',
                b"not json",
                b"[]",
            ]
        )
        return status, headers, body
    if roll < 0.14:
        return pick([401, 404, 422, 500]), headers, b'{"message":"Bad credentials"}'
    if roll < 0.16:
        return pick([301, 302]), [(b"Location", pick([b"https://api.github.com/x", b"/y", b"http://[bad"]))], b""
    expires = now + pick([3600, 3600, 3600, 120, 61, 59.75, 30, -10])
    expires_at: Any = iso(expires)
    style = rng.random()
    if style < 0.04:
        expires_at = expires_at.replace("T", "t").replace("Z", "z")
    elif style < 0.06:
        expires_at = expires_at.replace("Z", "+00:00")
    elif style < 0.08:
        expires_at = expires_at.replace("Z", ".000Z")
    elif style < 0.1:
        expires_at = "".join(chr(ord(c) + 0xFEE0) if c.isdigit() else c for c in expires_at[:4]) + expires_at[4:]
    elif style < 0.12:
        expires_at = pick(["0001-01-01T00:00:59Z", "0001-01-01T00:01:00Z", "9999-12-31T23:59:59Z", "2099-02-30T00:00:00Z", "2099-01-01T00:00:60Z", "0000-01-01T00:00:00Z"])
    elif style < 0.13:
        expires_at = pick([5, None, ""])
    payload: dict[str, Any] = {"token": "ghs_" + "".join(pick(list("abcdef0123")) for _ in range(8)), "expires_at": expires_at}
    extra = rng.random()
    if extra < 0.05:
        payload["token"] = pick([5, None, ""])
    elif extra < 0.08:
        del payload["token"]
    elif extra < 0.14:
        payload["permissions"] = pick([{"contents": "write"}, {"contents": "admin"}, {"unknown": "x"}, None, "x", {"issues": None}])
    elif extra < 0.18:
        payload["repository_selection"] = pick(["all", "selected", "bogus", None])
    elif extra < 0.22:
        payload["repositories"] = pick([[], "x", None, [5]])
    elif extra < 0.26:
        payload["has_multiple_single_files"] = pick([True, "yes", "true", 1, 2, "off", None, 0.0])
    elif extra < 0.28:
        payload["single_file_paths"] = pick([["a"], [5], None, "a"])
    elif extra < 0.3:
        payload["single_file"] = pick(["a", 5, None])
    body = json.dumps(payload, separators=(",", ":")).encode()
    special = rng.random()
    if special < 0.03:
        body = b"\xef\xbb\xbf" + body
    elif special < 0.05:
        body = body[:-1] + b',"x":NaN}'
    elif special < 0.07:
        body = b'{"token":"first",' + body[1:]
    elif special < 0.08:
        body = b"not json"
    return pick([201, 201, 201, 200]), headers, body


LINKS = [
    b'<https://api.github.com/repos/o/r/pulls?page=2>; rel="next"',
    b'<https://api.github.com/repos/o/r/pulls?page=2>; rel="next", <https://api.github.com/repos/o/r/pulls?page=9>; rel="last"',
    b'<https://evil.example/x>; rel="next"',
    b'<https://api.github.com/a>; rel="next", <https://api.github.com/b>; rel="next"',
    b'<https://api.github.com:8443/x>; rel="next"',
    b"garbage",
    b'<>; rel="next"',
    b'<https://api.github.com/x#f>; rel="next"',
    b'<https://api.github.com/same>; rel="next"',
]


def generic_response(request: httpx.Request, wire: Wire) -> tuple[int, list[tuple[bytes, bytes]], bytes]:
    now = CLOCK[0]
    url = str(request.url)
    conditional = "if-none-match" in request.headers or "if-modified-since" in request.headers
    headers: list[tuple[bytes, bytes]] = []
    if conditional and rng.random() < 0.6:
        status = 304
        if rng.random() < 0.7:
            headers.append((b"ETag", pick([request.headers.get("if-none-match", '"e1"').encode(), b'"other"'])))
        if rng.random() < 0.3:
            headers.append((b"Cache-Control", pick([b"private, max-age=60", b"no-store"])))
        if rng.random() < 0.3:
            headers.append((b"X-Fresh", b"1"))
        if rng.random() < 0.1:
            headers.append((b"Content-Encoding", b"gzip"))
            return status, headers, gzip.compress(b"")
        return status, headers, b""
    status = pick([200] * 10 + [201, 204, 304, 404, 422, 500, 301, 302, 307, 400])
    headers.append((b"Content-Type", pick([b"application/json; charset=utf-8", b"text/plain"])))
    if rng.random() < 0.5:
        headers.append((b"ETag", pick([b'"e1"', b'W/"e2"', b'"e3"'])))
    if rng.random() < 0.25:
        headers.append((b"Last-Modified", pick([http_date(now - 86400).encode(), b"garbage", b"Mon, 01 Jan 0001 00:00:00 GMT"])))
    if rng.random() < 0.6:
        headers.append(
            (
                b"Cache-Control",
                pick(
                    [
                        b"private, max-age=60, s-maxage=60",
                        b"private, max-age=0",
                        b"no-store",
                        b"public, max-age=600",
                        b"no-cache",
                        b'private="x", max-age=5',
                        b"max-age=abc",
                        b"private",
                        b"no-cache=\"set-cookie\", max-age=30",
                    ]
                ),
            )
        )
    if rng.random() < 0.5:
        headers.append((b"Date", pick([http_date(now).encode(), http_date(now - 30).encode(), b"garbage", b"Sat, 01 Jan 10000 00:00:00 GMT", b"0"])))
    if rng.random() < 0.15:
        headers.append((b"Expires", pick([http_date(now + 60).encode(), b"0", b"garbage", b"Fri, 31 Dec 9999 23:59:59 GMT"])))
    if rng.random() < 0.4:
        headers.append((b"Vary", b"Accept, Authorization, Cookie, X-GitHub-OTP, Accept-Encoding"))
    if rng.random() < 0.3:
        headers.append((b"Link", pick(LINKS)))
    if rng.random() < 0.6:
        headers.append((b"X-GitHub-Request-Id", pick([b"ABCD:1234"] * 8 + [b"caf\xe9", b""])))
    if rng.random() < 0.5:
        headers.append((b"X-RateLimit-Remaining", pick([b"4999"] * 6 + [b"0", b"-1", b"\xd9\xa3", b"12a"])))
        headers.append((b"X-RateLimit-Reset", pick([b"1760003600", b"x", b" 5"])))
    if 300 <= status < 400 and status != 304 and rng.random() < 0.85:
        headers.append(
            (
                b"Location",
                pick([b"https://api.github.com/elsewhere", b"/relative", b"http://[bad", b"https:x", b"", b"mailto:x", b"//host/p"]),
            )
        )
    if rng.random() < 0.03:
        headers.append((b"X-Odd", b"\xff\xfe"))
    if rng.random() < 0.05:
        headers.append((b"Transfer-Encoding", b"chunked"))
    body = generic_body()
    encoding = rng.random()
    if encoding < 0.12:
        headers.append((b"Content-Encoding", b"gzip"))
        body = gzip.compress(body) if rng.random() < 0.85 else gzip.compress(body)[: max(1, len(body) // 2)]
    elif encoding < 0.18:
        headers.append((b"Content-Encoding", b"deflate"))
        body = zlib.compress(body) if rng.random() < 0.5 else zlib.compress(body)[2:-4]
    elif encoding < 0.2:
        headers.append((b"Content-Encoding", pick([b"br", b"identity", b"gzip, identity", b"GZIP"])))
        if headers[-1][1] in (b"gzip, identity", b"GZIP"):
            body = gzip.compress(body)
    elif encoding < 0.21:
        headers.append((b"Content-Encoding", b"gzip"))
        body = b"not gzip at all"
    return status, headers, body


def generic_body() -> bytes:
    roll = rng.random()
    if roll < 0.35:
        return json.dumps({"id": rng.randrange(100), "name": pick(["x", "ü"]), "list": [1, 2]}, ensure_ascii=False).encode()
    if roll < 0.6:
        return json.dumps([{"id": index} for index in range(rng.randrange(4))]).encode()
    if roll < 0.65:
        return json.dumps([{"id": 1}, 5]).encode()
    if roll < 0.72:
        return b""
    if roll < 0.75:
        return b"{not json"
    if roll < 0.77:
        return b'"\xff\xfe"'
    if roll < 0.79:
        return json.dumps({"x": "y"}).encode("utf-16")
    if roll < 0.8:
        return b"[" * 5000 + b"]" * 5000
    if roll < 0.81:
        return b" " * (1_048_576 + pick([0, 1]))
    if roll < 0.83:
        return b'{"n": NaN, "big": 1e400}'
    if roll < 0.84:
        return b"\xef\xbb\xbf{}"
    return json.dumps({"ok": True}).encode()


# --- Steps --------------------------------------------------------------------

CLIENTS = [["app"], ["installation", 44, [31]], ["installation", 44, [31]], ["installation", 44, [31, 32]], ["installation", 45, [31]], ["inventory", 44]]
PATHS = [
    "/repos/o/r/pulls/1",
    "/repos/o/r/pulls/1",
    "/repos/o/r/pulls?state=open&per_page=100",
    "/repos/o/r/issues/1/comments",
    "/app",
    "/APP",
    "/app/installations?per_page=100",
    "/installation/repositories?per_page=100",
    "/applications/x/token",
    "/login/oauth/access_token",
    "/repos/o/r/../x",
    "/a b",
    "/é",
    "/%2F",
    "/x?y=1#frag",
    "/x?q=é",
    "//evil.example/x",
    "relative",
    "/repos/o/r/actions/runs/1/logs",
    "/app\n",
    "/x\x00",
]


def body_value() -> Any:
    if rng.random() < 0.02:
        return {"big": {"repeat": "x", "count": 65520}}
    return pick(
        [
            None,
            {"body": "héllo"},
            {"body": "héllo"},
            {"a": [1.5, None, "é "], "b": {"c": True}},
            {"big": {"repeat": "é", "count": 32750}},
            {"big": {"repeat": "x", "count": 65000}},
            {"nan": float("nan")},
            {"n": 2**80},
            {},
        ]
    )


def step() -> dict[str, Any]:
    roll = rng.random()
    if roll < 0.15:
        return {"op": "clock", "advance": pick([0, 1, 30, 61, 479, 481, 600, 3540, 3600, 3700, 0.25])}
    client = pick(CLIENTS)
    if roll < 0.75:
        method = pick(["GET"] * 8 + ["POST", "POST", "PATCH", "DELETE"])
        path = pick(PATHS) if rng.random() < 0.4 else pick(PATHS[:4] + PATHS[6:8])
        return {"op": "request", "client": client, "method": method, "path": path, "body": None if method == "GET" and rng.random() < 0.9 else body_value()}
    if roll < 0.85:
        return {"op": "download", "client": client, "path": pick(PATHS), "limit": pick([1048576, 10, 0])}
    if roll < 0.95:
        return {"op": "pages", "client": client, "path": pick(["/repos/o/r/pulls?per_page=100", "/repos/o/r/issues/1/comments?per_page=100"])}
    return {"op": "registration"}


def encode_error(error: BaseException) -> dict[str, Any]:
    if isinstance(error, GitHubBoundaryError):
        return {
            "class": "GitHubBoundaryError",
            "message": str(error),
            "failure_class": error.failure_class,
            "provider_status": error.provider_status,
            "provider_detail": error.provider_detail,
        }
    return {"class": type(error).__name__, "message": str(error)}


def expand(value: Any) -> Any:
    """``{"repeat": text, "count": n}`` spells ``text * n`` compactly."""
    if isinstance(value, dict):
        if set(value) == {"repeat", "count"}:
            return value["repeat"] * value["count"]
        return {key: expand(item) for key, item in value.items()}
    if isinstance(value, list):
        return [expand(item) for item in value]
    return value


def run_step(clients: GitHubAppClients, config: HostConfig, value: dict[str, Any]) -> Any:
    op = value["op"]
    if op == "registration":
        inventory = clients.registration_inventory(config)
        return [
            {"installation_id": item.installation_id, "account_id": item.account_id, "repositories": [list(r) for r in item.repositories]}
            for item in inventory.installations
        ]
    kind = value["client"][0]
    if kind == "app":
        client = clients.app
    elif kind == "installation":
        client = clients.installation(value["client"][1], value["client"][2])
    else:
        client = clients.inventory(value["client"][1])
    transport = GitHubKitTransport(client)
    if op == "request":
        response = transport.request(value["method"], value["path"], expand(value["body"]))
        return {"status": response.status, "body": response.body, "next_path": response.next_path}
    if op == "download":
        data = transport.download(value["path"], value["limit"])
        return {"length": len(data), "b64": base64.b64encode(data[:4096]).decode()}
    return list(transport.pages(value["path"]))


def row() -> dict[str, Any]:
    start = pick([1_760_000_000.0, 1_760_000_000.5, 1_000_000_000.0])
    CLOCK[0] = start
    wire = Wire()
    observations: list[dict[str, Any]] = []
    hook = rng.random() < 0.6
    config = HostConfig(
        app_id=17,
        app_slug="hamster-dan",
        client_id="Iv1.corpus",
        accounts=(AccountConfig(23, "Owner", ((31, "owner/one"),)),),
        state_path=Path("/nonexistent/state"),
        private_key=KEY.read_text(),
        webhook_secret="corpus-secret",
    )
    clients = GitHubAppClients(
        config,
        transport=httpx.MockTransport(wire.handler),
        metadata_hook=(lambda m: observations.append(
            {
                "method": m.method,
                "path": m.path,
                "request_id": m.request_id,
                "rate_limit_remaining": m.rate_limit_remaining,
                "rate_limit_reset": m.rate_limit_reset,
                "status": m.status,
            }
        )) if hook else None,
    )
    steps = [step() for _ in range(rng.randrange(1, 9))]
    results = []
    for value in steps:
        if value["op"] == "clock":
            CLOCK[0] += value["advance"]
            results.append(None)
            continue
        before_exchanges, before_observations = len(wire.exchanges), len(observations)
        try:
            outcome: dict[str, Any] = {"ok": run_step(clients, config, value)}
        except Exception as error:  # noqa: BLE001 - the class is the observation
            outcome = {"error": encode_error(error)}
        outcome["exchanges"] = len(wire.exchanges) - before_exchanges
        outcome["observations"] = observations[before_observations:]
        results.append(outcome)
    return {
        "start": start,
        "hook": hook,
        "steps": steps,
        "results": results,
        "exchanges": wire.exchanges,
    }


def main() -> None:
    if not KEY.exists():
        raise SystemExit(f"missing {KEY}; it is the committed throwaway corpus key")
    rows = [row() for _ in range(ROWS)]
    with OUT.open("w", encoding="utf-8") as handle:
        for value in rows:
            handle.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"wrote {len(rows)} rows to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
