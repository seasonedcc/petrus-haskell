"""Run the reference ``python -m hamsterdan.host serve`` as a process.

Usage: ``python -I -B serve_reference.py STDOUT STDERR < case.json``, where
the case is ``{"env": {...}, "github_port": int}``. The process's standard
output and error descriptors are pointed at the two files, the process
environment is replaced by ``env``, and ``main()`` runs ``serve``, so uvicorn
writes its log lines to those descriptors exactly as it does under the
systemd unit. It serves until SIGTERM (or fails to start), and exits the way
the reference does.

One composition is replaced, as in ``cli_reference.py``: the GitHub network.
``GitHubAppClients`` sends every request to the recording fake GitHub on
``127.0.0.1:github_port``. Everything else (the agent composition, uvicorn,
its logging configuration and its proxy headers middleware) is the real one.
"""

from __future__ import annotations

import json
import os
import sys

import httpx

import hamsterdan.host.service as service_module
from hamsterdan.github_app.auth import GitHubAppClients
from hamsterdan.host import __main__ as host_main


class Redirect(httpx.HTTPTransport):
    def __init__(self, port: int) -> None:
        super().__init__()
        self.port = port

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        request.url = request.url.copy_with(scheme="http", host="127.0.0.1", port=self.port)
        return super().handle_request(request)


def main() -> None:
    for path, descriptor in ((sys.argv[1], 1), (sys.argv[2], 2)):
        opened = os.open(path, os.O_WRONLY | os.O_APPEND)
        os.dup2(opened, descriptor)
        os.close(opened)
    case = json.load(sys.stdin)
    port = int(case["github_port"])

    def clients(config, **kwargs):
        return GitHubAppClients(config, transport=Redirect(port), **kwargs)

    service_module.GitHubAppClients = clients
    os.environ.clear()
    os.environ.update(case["env"])
    sys.argv = ["hamsterdan.host", "serve"]
    sys.exit(host_main.main())


if __name__ == "__main__":
    main()
