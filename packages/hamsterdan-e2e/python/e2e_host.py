"""The reference host for a tier C run: ``python -m hamsterdan.host`` with seams.

    python -I -B e2e_host.py <python -m hamsterdan.host arguments>

Runs in the reference's environment, configured exactly as the production
host (docs/hamsterdan.md §1.8; ``scripts/e2e start-hosts`` prints the
environment). Nothing upstream is patched: this driver replaces
``HostService`` in ``hamsterdan.host.__main__``'s namespace by a factory
that adds the injection points ``HostService`` already takes, then calls
that module's ``main()``. Three variables select them; with none set it is
the production host:

``HAMSTERDAN_E2E_RECORD=TAPE``
    Record a tier B tape of the live run (docs/hamsterdan.md §5.2, tier B
    step 1) into the directory TAPE: every GitHub exchange (the recording
    ``transport_factory``), every agent call (around the real runner), every
    Git publisher call, and the steps that drove the host (the webhook tee,
    registration, and the sweeps and pumps that did something;
    ``host_seams.LiveRecorder``). No secret is written.

``HAMSTERDAN_E2E_AGENTS=TAPE``
    Answer every agent call from the ``agents.jsonl`` of another run's tape,
    carried to this repository (``host_seams.CarriedRunner``): tier C's
    deterministic agent (§5.2, tier C step 2). The real runner is not
    called.

``HAMSTERDAN_E2E_GITHUB_PORT=PORT``
    Send every GitHub request to ``http://127.0.0.1:PORT`` instead of
    api.github.com. For testing this driver against fakes only.

The Haskell twin is ``hamsterdan-e2e-host``.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import host_seams  # noqa: E402
import tape as tapes  # noqa: E402
from hamsterdan.github_app.auth import GitHubAppClients  # noqa: E402
from hamsterdan.host import __main__ as host_main  # noqa: E402
from hamsterdan.host.git_publish import HostGitPublisher  # noqa: E402

# Replays sign the recorded deliveries again with this (tape.py); the
# live secret is never written.
REPLAY_WEBHOOK_SECRET = "tier-c-replay-webhook-secret"


def meta(config, kwargs) -> dict[str, object]:
    composition = kwargs["agent_composition"]
    return {
        "source": "live",
        "config": {
            "app_id": config.app_id,
            "app_slug": config.app_slug,
            "client_id": config.client_id,
            "accounts": [
                [account.account_id, account.account_login, [list(repository) for repository in account.repositories]]
                for account in config.accounts
            ],
            "watched_authors": sorted(config.watched_authors),
            "workflow_path": kwargs.get("workflow_path", ".github/workflows/ci.yml"),
            "reminder_seconds": kwargs.get("reminder_delay", 259200),
            "replay_webhook_secret": REPLAY_WEBHOOK_SECRET,
        },
        "agent": {"provider": composition.provider, "model": composition.model},
        "seams": [],
    }


def service_factory(production, environment):
    record = environment.get("HAMSTERDAN_E2E_RECORD")
    agents = environment.get("HAMSTERDAN_E2E_AGENTS")
    port = environment.get("HAMSTERDAN_E2E_GITHUB_PORT")

    def service(config, **kwargs):
        if port:
            kwargs["clients"] = GitHubAppClients(config, transport=host_seams.Redirect(int(port)))
        if agents:
            kwargs["runner"] = host_seams.CarriedRunner(Path(agents))
        if not record:
            return production(config, **kwargs)
        writer = tapes.TapeWriter(Path(record), meta(config, kwargs))
        context = host_seams.Context()
        kwargs["runner"] = host_seams.RecordingRunner(kwargs["runner"], writer)
        kwargs["transport_factory"] = host_seams.recording_transport_factory(writer, context)
        kwargs["application_factory"] = host_seams.application_factory(
            lambda authority, url: host_seams.RecordingPublisher(HostGitPublisher(authority, url), writer, context)
        )
        clock = time.time
        kwargs["clock"] = clock
        host = production(config, **kwargs)
        host_seams.LiveRecorder(host, writer, clock)
        return host

    return service


def main() -> int:
    environment = dict(os.environ)
    for name in ("HAMSTERDAN_E2E_RECORD", "HAMSTERDAN_E2E_AGENTS", "HAMSTERDAN_E2E_GITHUB_PORT"):
        os.environ.pop(name, None)
    host_main.HostService = service_factory(host_main.HostService, environment)
    sys.argv = ["hamsterdan.host", *sys.argv[1:]]
    return host_main.main()


if __name__ == "__main__":
    raise SystemExit(main())
