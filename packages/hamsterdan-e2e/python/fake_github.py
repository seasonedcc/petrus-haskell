"""A fake GitHub that answers an App host's registration, for smoke tests.

    python3 fake_github.py --log LOG [--app-id 17] [--slug hamsterdan-test]
        [--client-id Iv1.test] [--installation 44:23:Owner]
        [--repository 31:owner/one ...]

Standard library only. It listens on an ephemeral port of 127.0.0.1 and
prints ``port N`` first. It answers what a host's startup registration
(``reconcile_registration``) and its installation tokens ask:

- ``GET /app``: the App, with exactly the permissions and events
  docs/hamsterdan.md §5.1 lists (``APP_PERMISSIONS``, ``APP_EVENTS``);
- ``GET /app/installations?per_page=100``: the one installation;
- ``POST /app/installations/<id>/access_tokens``: a token;
- ``GET /installation/repositories?per_page=100``: the repositories.

Anything else is a 404 and a ``"kind": "unanswered"`` log line. Every
request appends ``{"method", "path", "body", "kind"}`` to LOG.
"""

from __future__ import annotations

import argparse
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_PERMISSIONS = {
    "actions": "read",
    "administration": "read",
    "contents": "write",
    "issues": "write",
    "pull_requests": "write",
    "metadata": "read",
}
APP_EVENTS = (
    "issue_comment",
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "pull_request_review_thread",
    "workflow_run",
)
TOKEN = re.compile(r"/app/installations/([1-9][0-9]*)/access_tokens\Z")


def answers(args: argparse.Namespace) -> dict[tuple[str, str], object]:
    installation, account, login = args.installation.split(":", 2)
    return {
        ("GET", "/app"): {
            "id": args.app_id,
            "slug": args.slug,
            "client_id": args.client_id,
            "permissions": APP_PERMISSIONS,
            "events": list(APP_EVENTS),
        },
        ("GET", "/app/installations?per_page=100"): [
            {
                "id": int(installation),
                "account": {"id": int(account), "login": login},
                "suspended_at": None,
                "permissions": APP_PERMISSIONS,
            }
        ],
        ("GET", "/installation/repositories?per_page=100"): {
            "total_count": len(args.repository),
            "repositories": [
                {"id": int(identity), "full_name": name}
                for identity, _, name in (item.partition(":") for item in args.repository)
            ],
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--app-id", type=int, default=17)
    parser.add_argument("--slug", default="hamsterdan-test")
    parser.add_argument("--client-id", default="Iv1.test")
    parser.add_argument("--installation", default="44:23:Owner")
    parser.add_argument("--repository", action="append", default=[])
    args = parser.parse_args()
    known = answers(args)
    lock = threading.Lock()
    log = args.log.open("a", encoding="utf-8")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, *_args) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            status, value, kind = 404, {"message": "Not Found"}, "unanswered"
            if self.command == "POST" and TOKEN.fullmatch(self.path):
                status, kind = 201, "token"
                value = {"token": "ghs_fake", "expires_at": "2099-01-01T00:00:00Z", "repository_selection": "selected"}
            elif (self.command, self.path) in known:
                status, value, kind = 200, known[(self.command, self.path)], "answered"
            with lock:
                log.write(json.dumps({"method": self.command, "path": self.path, "body": body, "kind": kind}) + "\n")
                log.flush()
            content = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _serve

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(f"port {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
