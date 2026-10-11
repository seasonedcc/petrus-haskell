"""A fake GitHub REST and GraphQL API that answers from a tier B tape.

    python3 tape_server.py TAPE --log LOG [--skip-context publisher] [--sticky-reads]

Standard library only. It listens on an ephemeral port of 127.0.0.1 and
prints ``port N`` on its first line of output. Point a host's GitHub client
at it (the reference through an httpx transport that rewrites the origin,
the Haskell host through ``newPlainExchangeAt``).

Each request is answered from the tape's ``github.jsonl``: the recorded
answers to the same ``(method, path, body)`` are served in recorded order.
The body matches by its JSON value, so key order and spacing do not
matter; the log keeps the bytes the host sent. A request with no recorded
answer left gets a 500 and an ``unrecorded`` log line, and comparisons fail
on it. App installation token requests are answered here (githubkit makes
them below the transport, so they are not on the tape).

``--skip-context publisher`` leaves out the requests the recording host
made inside its Git publisher, for replays that replay the publisher
itself. ``--sticky-reads`` answers a read (a GET or a GraphQL query) whose
recorded answers are used up with its last one; live tapes need it, because
a replay converges with fewer or more reads than a live host polled.

Every request appends one line to LOG at once: ``n``, ``method``, ``path``,
``body`` (the text sent), ``kind`` (``tape``, ``auth``, ``sticky`` or
``unrecorded``), ``tape_seq`` and ``status``.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import threading
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import tape as tapes  # noqa: E402

TOKEN_PATH = re.compile(r"/app/installations/([1-9][0-9]*)/access_tokens\Z")


class Replay:
    def __init__(self, root: Path, log: Path, skip: tuple[str, ...], sticky: bool) -> None:
        tapes.read_meta(root)
        self.queues: dict[tuple[str, str, str], deque] = defaultdict(deque)
        self.last: dict[tuple[str, str, str], dict] = {}
        for record in tapes.read(root, "github.jsonl"):
            if record.get("context", "host") in skip:
                continue
            key = (record["method"], record["path"], "" if record["body"] is None else tapes.canonical(record["body"]))
            self.queues[key].append(record)
        self.sticky = sticky
        self.lock = threading.Lock()
        self.count = 0
        self.log = log.open("a", encoding="utf-8")

    def write(self, entry: dict) -> None:
        self.log.write(json.dumps(entry, sort_keys=True, ensure_ascii=False) + "\n")
        self.log.flush()

    def answer(self, method: str, path: str, raw: bytes) -> tuple[int, dict, bytes | None]:
        with self.lock:
            self.count += 1
            entry = {"n": self.count, "method": method, "path": path, "body": raw.decode("utf-8", "replace")}
            token = TOKEN_PATH.fullmatch(path)
            if method == "POST" and token:
                answer = {
                    "token": f"ghs_replay{token.group(1)}",
                    "expires_at": "2099-01-01T00:00:00Z",
                    "permissions": {},
                    "repository_selection": "selected",
                }
                self.write({**entry, "kind": "auth", "tape_seq": None, "status": 201})
                return 201, {}, json.dumps(answer).encode()
            try:
                key = (method, path, tapes.body_key(raw))
                body = None if not raw else json.loads(raw)
            except ValueError:
                key, body = (method, path, "<unparseable>"), None
            queue = self.queues.get(key)
            kind = "tape"
            if queue:
                record = queue.popleft()
                self.last[key] = record
            elif self.sticky and key in self.last and not tapes.is_mutation(method, path, body):
                record, kind = self.last[key], "sticky"
            else:
                self.write({**entry, "kind": "unrecorded", "tape_seq": None, "status": 500})
                return 500, {}, b'{"message":"unrecorded request"}'
            if "error" in record:
                self.write({**entry, "kind": kind, "tape_seq": record["seq"], "status": None})
                return 0, {}, None
            headers = {}
            if record.get("next"):
                headers["Link"] = f'<https://api.github.com{record["next"]}>; rel="next"'
            content = b"" if record["response"] is None else json.dumps(record["response"]).encode()
            self.write({**entry, "kind": kind, "tape_seq": record["seq"], "status": record["status"]})
            return int(record["status"]), headers, content


def handler(replay: Replay):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, *_args) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(length) if length else b""
            status, headers, content = replay.answer(self.command, self.path, raw)
            if content is None:
                # A recorded transport failure: no answer at all.
                self.close_connection = True
                return
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(content)

        do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _serve

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("tape", type=Path)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--skip-context", action="append", default=[])
    parser.add_argument("--sticky-reads", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    replay = Replay(args.tape, args.log, tuple(args.skip_context), args.sticky_reads)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler(replay))
    server.daemon_threads = True
    print(f"port {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
