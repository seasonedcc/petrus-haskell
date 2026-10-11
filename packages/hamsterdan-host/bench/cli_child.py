"""``python -m hamsterdan.host ARGS`` with GitHub sent to the bench's fake.

Usage: ``python -I -B cli_child.py ARGS`` with ``HAMSTERDAN_BENCH_GITHUB_PORT``
set. The reference's ``main()`` runs unchanged except for one composition,
as in ``differential/cli_reference.py``: ``GitHubAppClients`` sends every
request to the fake GitHub on ``127.0.0.1:$HAMSTERDAN_BENCH_GITHUB_PORT``
(plain HTTP, same paths) through an injected httpx transport. The port's side
is ``hamsterdan-host-bench --cli ARGS`` (``bench/Process.hs``).
"""

from __future__ import annotations

import os
import sys

import httpx

import hamsterdan.host.service as service_module
from hamsterdan.github_app.auth import GitHubAppClients
from hamsterdan.host import __main__ as host_main

PORT = int(os.environ.pop("HAMSTERDAN_BENCH_GITHUB_PORT"))


class Redirect(httpx.HTTPTransport):
    def handle_request(self, request: httpx.Request) -> httpx.Response:
        request.url = request.url.copy_with(scheme="http", host="127.0.0.1", port=PORT)
        return super().handle_request(request)


def clients(config, **kwargs):
    return GitHubAppClients(config, transport=Redirect(), **kwargs)


service_module.GitHubAppClients = clients
sys.argv = ["hamsterdan.host", *sys.argv[1:]]

if __name__ == "__main__":
    raise SystemExit(host_main.main())
