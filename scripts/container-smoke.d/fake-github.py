"""A stand-in for https://api.github.com, for scripts/container-smoke.

It runs in its own container, reachable as api.github.com on the smoke
network, and serves TLS with a certificate from the smoke run's own CA
(which the host container trusts through SYSTEM_CERTIFICATE_PATH). It
answers the registration calls that `hamsterdan.host validate` and the
`serve` lifespan make for the App, installation and repository the smoke
fixture configures (deployment/config/installations.toml), and logs every
request as `METHOD TARGET AUTH-SCHEME` on stdout.

    python3 fake-github.py CERTIFICATE KEY APP_ID SLUG CLIENT_ID INSTALLATIONS_TOML
"""

from __future__ import annotations

import http.server
import json
import ssl
import sys
import tomllib

PERMISSIONS = {
    "actions": "read",
    "administration": "read",
    "contents": "write",
    "issues": "write",
    "pull_requests": "write",
    "metadata": "read",
}
EVENTS = [
    "issue_comment",
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "pull_request_review_thread",
    "workflow_run",
]


def routes(app_id: int, slug: str, client_id: str, installations: dict) -> dict:
    table: dict[tuple[str, str], tuple[int, object]] = {
        ("GET", "/app"): (
            200,
            {"id": app_id, "slug": slug, "client_id": client_id, "permissions": PERMISSIONS, "events": EVENTS},
        ),
    }
    listed = []
    # One installation per configured account, numbered from 4242; each
    # installation token reads that account's configured repositories.
    for number, account in enumerate(installations["accounts"], start=4242):
        listed.append(
            {
                "id": number,
                "account": {"id": account["id"], "login": account["login"]},
                "suspended_at": None,
                "permissions": PERMISSIONS,
            }
        )
        token = f"ghs_smoke{number}"
        table[("POST", f"/app/installations/{number}/access_tokens")] = (
            201,
            {"token": token, "expires_at": "2099-01-01T00:00:00Z", "repository_selection": "selected"},
        )
        repositories = []
        for entry in account["repositories"]:
            identifier, _, full_name = entry.partition(":")
            repositories.append({"id": int(identifier), "full_name": full_name})
        table[("GET", f"/installation/repositories?per_page=100#{token}")] = (
            200,
            {"total_count": len(repositories), "repositories": repositories},
        )
    table[("GET", "/app/installations?per_page=100")] = (200, listed)
    return table


def main() -> None:
    certificate, key, app_id, slug, client_id, installations_path = sys.argv[1:]
    with open(installations_path, "rb") as stream:
        installations = tomllib.load(stream)
    table = routes(int(app_id), slug, client_id, installations)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def answer(self) -> None:
            length = int(self.headers.get("content-length") or 0)
            if length:
                self.rfile.read(length)
            authorization = self.headers.get("authorization") or ""
            scheme, _, credential = authorization.partition(" ")
            print(f"{self.command} {self.path} {scheme or '-'}", flush=True)
            key = (self.command, self.path)
            if self.path.startswith("/installation/"):
                key = (self.command, f"{self.path}#{credential}")
            status, document = table.get(key, (404, {"message": "Not Found"}))
            body = json.dumps(document).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json; charset=utf-8")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = answer
        do_POST = answer
        do_PATCH = answer
        do_PUT = answer
        do_DELETE = answer

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - BaseHTTPRequestHandler's signature
            pass

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("listening", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
