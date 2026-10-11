"""Serve the reference ``create_app`` over the ``test_service.py`` fakes.

Usage: ``python -I -B api_reference.py STATE_ROOT``. Binds 127.0.0.1 on an
ephemeral port, prints ``listening PORT`` once uvicorn has started, and serves
until SIGTERM. The service mirrors ``service(tmp_path)`` from
``tests/integration/host/test_service.py``: recording clients, a recording
Application factory, the registry reconciled for installation 44, and no
startup registration reconciliation. ``ApiSpec`` drives the same requests
against this server and against the warp application and compares the raw
responses.
"""

from __future__ import annotations

import asyncio
import socket
import sys
from pathlib import Path

import uvicorn

from hamsterdan.github_app.config import AccountConfig, HostConfig
from hamsterdan.github_app.models import InstallationInventory
from hamsterdan.host.agenticus import AgentRouteStore, compose_agent
from hamsterdan.host.api import create_app
from hamsterdan.host.service import HostService


class Client:
    def request(self, method, path):
        raise AssertionError("no provider calls are expected")


class Clients:
    def registration_inventory(self, config):
        raise AssertionError("registration inventory was not configured")

    def installation(self, installation_id, repository_ids):
        return Client()

    def close(self):
        pass


class Application:
    def __init__(self, *args, **kwargs):
        pass

    def process_observation(self, observation, *, conversation=None):
        pass

    def reconcile(self, reason):
        pass

    def settle(self):
        return None

    def has_unresolved_publication(self):
        return False

    def run_durable_activities(self, limit):
        return 0

    def stop_durable_activities(self):
        pass

    def close(self):
        pass


def main() -> None:
    root = Path(sys.argv[1])
    composition = compose_agent()
    routes = AgentRouteStore(root / "test-agent-routes.sqlite3")
    routes.activate(composition, root / "applications")
    host = HostService(
        HostConfig(
            app_id=17,
            app_slug="hamsterdan-test",
            client_id="Iv1.client-secret-looking",
            accounts=(AccountConfig(23, "Owner", ((31, "owner/one"), (32, "owner/two"))),),
            state_path=root,
            private_key="private-key-secret",
            webhook_secret="hook-secret",
            watched_authors=frozenset(),
        ),
        clients=Clients(),
        runner=object(),
        agent_composition=composition,
        agent_routes=routes,
        application_factory=Application,
    )
    host.registry.reconcile((InstallationInventory(44, 23, ((31, "owner/one"), (32, "owner/two"))),))
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    server = uvicorn.Server(
        uvicorn.Config(create_app(host, reconcile_startup=False), log_level="warning", access_log=False)
    )

    async def announce() -> None:
        while not server.started:
            await asyncio.sleep(0.01)
        print(f"listening {port}", flush=True)

    async def run() -> None:
        watcher = asyncio.create_task(announce())
        await server.serve(sockets=[listener])
        watcher.cancel()

    asyncio.run(run())


if __name__ == "__main__":
    main()
