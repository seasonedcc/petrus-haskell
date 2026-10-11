"""Record one of the eleven readiness journeys as a tier B tape, over real HTTP.

    python -I -B record_journey.py NAME ROOT TAPE [--fault agent|github:K]

The journey is tier A's (``journeys_reference.py``'s ``Drive``, which makes
``_run_journey``'s moves phase by phase), with its fake GitHub behind a real
HTTP server instead of in place of the transport:

- the upstream ``ScenarioProvider`` answers on an ephemeral port of
  127.0.0.1 (its three paginated reads through ``pages``, everything else
  through ``request``, and App installation tokens directly);
- the reference host composes its production GitHub stack
  (``GitHubAppClients``, App JWT, installation token, githubkit, httpx,
  ``GitHubKitTransport``), redirected to that port by an httpx transport;
- ``HostService`` gets the recording seams of ``host_seams``: the
  ``transport_factory``, the runner, the Git publisher (through
  ``application_factory``) and the step log; the clock is tier A's.

The journey's own moves (the provider's truth changing between phases, the
fixture repository advancing its base) happen exactly as in tier A; the
tape sees only their effect on what GitHub answers.

``--fault`` records a failure path on top of the journey: ``agent`` makes
the first agent call fail (``AgentProtocolError``, timed out), and
``github:K`` drops the connection of the K-th GitHub request (installation
tokens aside) without an answer, which the host sees as a transport
ambiguity. A faulted journey need not end as the journey does, so its
closing checks are not asserted (``result`` is null); the tape holds what
happened.

It prints one JSON document: the journey's ``result``, the ``state`` of ROOT
(``journeys_reference.dump``), and ``provider_errors``, every request the
fake GitHub could not answer (there must be none).
"""

from __future__ import annotations

import importlib.util
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest  # noqa: E402

import host_seams  # noqa: E402
import tape as tapes  # noqa: E402
from hamsterdan.agents.protocol import AgentProtocolError  # noqa: E402
from hamsterdan.github_app.auth import GitHubAppClients  # noqa: E402
from hamsterdan.github_app.config import HostConfig  # noqa: E402
from hamsterdan.host.git_publish import HostGitPublisher  # noqa: E402
from hamsterdan.host.service import HostService  # noqa: E402

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[2]
JOURNEYS_REFERENCE = REPOSITORY / "packages" / "hamsterdan-testing" / "differential" / "journeys_reference.py"
APP_KEY = REPOSITORY / "packages" / "hamsterdan-github" / "test" / "corpus" / "app-test-key.pem"
PAGED = (
    "/repos/owner/repo/issues/7/comments?per_page=100",
    "/repos/owner/repo/pulls/7/comments?per_page=100",
    "/repos/owner/repo/pulls/7/reviews?per_page=100",
)


def journeys_reference():
    spec = importlib.util.spec_from_file_location("journeys_reference", JOURNEYS_REFERENCE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ProviderServer:
    """The journey's ``ScenarioProvider`` over HTTP."""

    def __init__(self, module, drop: int | None = None) -> None:
        self.module = module
        self.provider = None
        self.drop = drop
        self.count = 0
        self.errors: list[str] = []
        self.lock = threading.Lock()
        server = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def log_message(self, *_args) -> None:
                pass

            def _serve(self) -> None:
                length = int(self.headers.get("content-length") or 0)
                raw = self.rfile.read(length) if length else b""
                status, value = server.answer(self.command, self.path, raw)
                if status is None:
                    self.close_connection = True
                    return
                content = b"" if value is None else json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)

            do_GET = do_POST = do_PATCH = _serve

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.http.daemon_threads = True
        self.port = self.http.server_address[1]
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()

    def answer(self, method: str, path: str, raw: bytes):
        with self.lock:
            try:
                if method == "POST" and path.startswith("/app/installations/") and path.endswith("/access_tokens"):
                    return 201, {
                        "token": self.module.INSTALLATION_TOKEN,
                        "expires_at": "2099-01-01T00:00:00Z",
                        "permissions": {},
                        "repository_selection": "selected",
                    }
                self.count += 1
                if self.count == self.drop:
                    return None, None
                body = json.loads(raw) if raw else None
                if method == "GET" and path in PAGED:
                    return 200, list(self.provider.pages(path))
                response = self.provider.request(method, path, body)
                return response.status, response.body
            except Exception as error:  # noqa: BLE001 - reported, and the recording fails
                self.errors.append(f"{method} {path}: {type(error).__name__}: {error}")
                return 500, {"message": "provider error"}

    def close(self) -> None:
        self.http.shutdown()
        self.http.server_close()


class FaultyRunner:
    """The journey's runner with its first call failing (``--fault agent``)."""

    def __init__(self, inner) -> None:
        self.inner, self.failed = inner, False

    def _call(self, kind: str, *args, **kwargs):
        if not self.failed:
            self.failed = True
            raise AgentProtocolError(f"injected {kind} fault", timed_out=True)
        return getattr(self.inner, kind)(*args, **kwargs)

    def review(self, *args, **kwargs):
        return self._call("review", *args, **kwargs)

    def converse(self, *args, **kwargs):
        return self._call("converse", *args, **kwargs)

    def code(self, *args, **kwargs):
        return self._call("code", *args, **kwargs)


def record(name: str, root: Path, tape: Path, fault: str | None = None) -> dict[str, object]:
    jr = journeys_reference()
    module = jr.scenarios_module()
    jr.git_determinism()
    drop = int(fault.split(":", 1)[1]) if fault and fault.startswith("github:") else None
    server = ProviderServer(module, drop)
    writer = tapes.TapeWriter(
        tape,
        {
            "source": f"journey:{name}" + (f" fault:{fault}" if fault else ""),
            "config": {
                "app_id": 17,
                "app_slug": "hamsterdan-test",
                "client_id": module.CLIENT_SECRET,
                "accounts": [[23, "Owner", [[31, "owner/repo"]]]],
                "workflow_path": ".github/workflows/ci.yml",
                "reminder_seconds": 259200,
                "replay_webhook_secret": module.WEBHOOK_SECRET,
            },
            # The reference spreads a frozenset into the allowed intents; tier
            # A's determinism seam puts them in source order on both sides.
            "seams": ["intent_order"],
        },
    )
    context = host_seams.Context()
    private_key = APP_KEY.read_text()

    def recording_host(config, *, clients, runner, agent_composition, agent_routes, clock):
        del clients  # tier A's in-process doubles; this host talks HTTP
        _, webhook_secret = config._credentials()
        settings = HostConfig(
            app_id=config.app_id,
            app_slug=config.app_slug,
            client_id=config.client_id,
            accounts=config.accounts,
            state_path=config.state_path,
            private_key=private_key,
            webhook_secret=webhook_secret,
            watched_authors=config.watched_authors,
        )
        host = HostService(
            settings,
            clients=GitHubAppClients(settings, transport=host_seams.Redirect(server.port)),
            runner=host_seams.RecordingRunner(FaultyRunner(runner) if fault == "agent" else runner, writer),
            agent_composition=agent_composition,
            agent_routes=agent_routes,
            clock=clock,
            transport_factory=host_seams.recording_transport_factory(writer, context),
            application_factory=host_seams.application_factory(
                lambda authority, url: host_seams.RecordingPublisher(HostGitPublisher(authority, url), writer, context)
            ),
        )
        host_seams.RecordingHost(host, writer, clock)
        return host

    try:
        with pytest.MonkeyPatch.context() as monkeypatch:
            jr.intent_order(monkeypatch)
            monkeypatch.setattr(jr, "HostService", recording_host)
            drive = jr.Drive(module, name, root, None, monkeypatch)
            server.provider = drive.provider
            try:
                for phase in jr.phases(jr.JOURNEYS[name]):
                    getattr(drive, f"phase_{phase}")()
            except Exception:
                # A fault may stop the journey where the host raised (the
                # tape's step says so); the host closes there.
                if not fault:
                    raise
                drive.host.close()
                return {"result": None, "state": jr.dump(root), "provider_errors": server.errors, "stopped": True}
            if fault:
                # The closing checks of a faulted journey may not hold; its
                # final pumps are still part of the tape.
                try:
                    drive.finish()
                except AssertionError:
                    pass
                result = None
            else:
                result = drive.finish()
    finally:
        server.close()
        writer.close()
    return {"result": result, "state": jr.dump(root), "provider_errors": server.errors}


def main() -> None:
    name, root, tape = sys.argv[1], Path(sys.argv[2]).absolute(), Path(sys.argv[3]).absolute()
    fault = sys.argv[5] if len(sys.argv) > 5 and sys.argv[4] == "--fault" else None
    output = record(name, root, tape, fault)
    sys.stdout.write("\n" + json.dumps(output, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
