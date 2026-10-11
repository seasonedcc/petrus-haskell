"""Run the reference ``python -m hamsterdan.host`` main() over many cases.

Usage: ``python -I -B cli_reference.py < cases.json > results.json``.

Each case is ``{"argv": [...], "env": {...}, "github_port": int | null}``.
For each case the process environment is replaced by ``env``, ``sys.argv``
by the case's arguments, and ``main()`` runs with stdout and stderr
captured; the result is ``{"code", "stdout", "stderr"}``. An exception that
escapes ``main()`` is reported as exit status 1 with its final traceback
line (``Class: message``) on stderr.

Two compositions are replaced, as in the Haskell port:

* the GitHub network: ``GitHubAppClients`` sends every request to the
  recording fake GitHub on ``127.0.0.1:github_port`` (plain HTTP, same
  paths), through an injected httpx transport;
* the Pi agent runtime: the agent composition is the test default
  (``compose_agent()``), with no Pi runtime or workspaces and an
  ``object()`` runner, since the agent runtimes are not part of this port.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import traceback
import types

import httpx

import hamsterdan.host.service as service_module
from hamsterdan.github_app.auth import GitHubAppClients
from hamsterdan.host import __main__ as host_main
from hamsterdan.host.agenticus import compose_agent


class Redirect(httpx.HTTPTransport):
    def __init__(self, port: int) -> None:
        super().__init__()
        self.port = port

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        request.url = request.url.copy_with(scheme="http", host="127.0.0.1", port=self.port)
        return super().handle_request(request)


def run(case: dict[str, object]) -> dict[str, object]:
    port = case.get("github_port")

    def clients(config, **kwargs):
        if port is None:
            raise AssertionError("this case must not reach GitHub")
        return GitHubAppClients(config, transport=Redirect(int(port)), **kwargs)

    service_module.GitHubAppClients = clients
    host_main.PiA2InstallationConfig = types.SimpleNamespace(
        from_environment=lambda environ, state_path: types.SimpleNamespace(provider=None, model=None)
    )
    host_main.compose_agent = lambda *args, **kwargs: compose_agent()
    host_main._compose_agent_runtime = lambda state_path, installation: (None, None)
    host_main.compose_agent_runner = lambda **kwargs: object()
    os.environ.clear()
    os.environ.update(case["env"])
    sys.argv = ["hamsterdan.host", *case["argv"]]
    out, err = io.StringIO(), io.StringIO()
    code = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = host_main.main()
        except SystemExit as exit:
            code = exit.code
        except Exception as error:  # noqa: BLE001 - reported like an uncaught traceback's last line
            code = 1
            err.write("".join(traceback.format_exception_only(error)))
    return {"code": code, "stdout": out.getvalue(), "stderr": err.getvalue()}


def main() -> None:
    cases = json.load(sys.stdin)
    results = [run(case) for case in cases]
    sys.stdout.write(json.dumps(results))


if __name__ == "__main__":
    main()
