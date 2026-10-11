"""Rehearse tier C's host start offline: both hosts, a fake GitHub, one webhook.

    python3 rehearse_hosts.py --work DIR --reference PYTHON --haskell-host EXE
        [--agents TAPE] [--key PEM] [--signal TERM|INT]

Standard library only. For each host (the reference through ``e2e_host.py``
under PYTHON, the Haskell host through ``hamsterdan-e2e-host``) it does what
``scripts/e2e start-hosts`` does for a live run, against fakes:

1. a state directory, an ``installations.toml`` and the §1.8 environment
   (``scripts/e2e`` builds the same one), with a stand-in Pi package and
   Node (``pi_fixture``) and ``HAMSTERDAN_E2E_GITHUB_PORT`` pointing at
   ``fake_github.py``;
2. ``serve`` on an ephemeral port of 127.0.0.1, until ``/healthz`` answers;
3. one signed ``pull_request`` delivery for a repository the installation
   does not hold (custody takes it without calling GitHub);
4. SIGTERM (or ``--signal INT``), and the exit status: both re-raise the
   signal after the graceful shutdown (uvicorn's ``capture_signals``), so
   both end by it (``-15`` or ``-2``).

The reference also records a tape (``HAMSTERDAN_E2E_RECORD``), and both take
``--agents`` as ``HAMSTERDAN_E2E_AGENTS`` when given. Prints one JSON report:
per host the ``/healthz`` answer, the webhook answer, the exit status, the
fake GitHub's log, and (reference) the tape's steps; and ``secrets_on_disk``,
every tape file holding the webhook secret or the private key (must be
none).
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[2]
WEBHOOK_SECRET = "rehearsal-webhook-secret"
PI_VERSION = "0.83.0"
DELIVERY = "6f1f9d2e-3c4b-4a5d-8e6f-7a8b9c0d1e2f"
BODY = json.dumps(
    {
        "action": "opened",
        "installation": {"id": 44, "account": {"id": 23}},
        "repository": {"id": 99, "full_name": "owner/elsewhere"},
        "pull_request": {"number": 1},
    }
).encode()


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def pi_fixture(root: Path) -> dict[str, str]:
    """A stand-in Pi package and Node that pass the host's startup probes
    (the Haskell ``Hamsterdan.Agents.Pi.Doubles.piPackageFixture``)."""
    package = root / "package"
    ai = package / "node_modules" / "@earendil-works" / "pi-ai"
    (package / "dist").mkdir(parents=True, exist_ok=True)
    ai.mkdir(parents=True, exist_ok=True)
    (package / "dist" / "cli.js").write_text("fixture")
    (package / "dist" / "index.js").write_text("fixture")
    (package / "package.json").write_text(
        json.dumps(
            {
                "name": "@earendil-works/pi-coding-agent",
                "version": PI_VERSION,
                "bin": {"pi": "dist/cli.js"},
                "main": "dist/index.js",
                "dependencies": {"@earendil-works/pi-ai": PI_VERSION},
            }
        )
    )
    (ai / "package.json").write_text(json.dumps({"name": "@earendil-works/pi-ai", "version": PI_VERSION}))
    node = root / "node"
    node.write_text(
        '#!/bin/sh\nif [ "$1" = "--version" ]; then printf "v22.19.0\\n"; else printf \'{"type":"probe","ok":true}\\n\'; fi\n'
    )
    node.chmod(0o700)
    return {
        "HAMSTERDAN_PI_CLI_PATH": str(package / "dist" / "cli.js"),
        "HAMSTERDAN_PI_NODE_PATH": str(node),
        "HAMSTERDAN_PI_PACKAGE_ROOT": str(package),
    }


def environment(work: Path, key: str, port: int, github_port: int) -> dict[str, str]:
    installations = work / "installations.toml"
    installations.write_text('[[accounts]]\nid = 23\nlogin = "Owner"\nrepositories = ["31:owner/one", "32:owner/two"]\n')
    installations.chmod(0o600)
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(work),
        "HAMSTERDAN_STATE_PATH": str(work / "state"),
        "HAMSTERDAN_GITHUB_APP_ID": "17",
        "HAMSTERDAN_GITHUB_APP_SLUG": "hamsterdan-test",
        "HAMSTERDAN_GITHUB_CLIENT_ID": "Iv1.test",
        "HAMSTERDAN_GITHUB_INSTALLATIONS_FILE": str(installations),
        "HAMSTERDAN_GITHUB_PRIVATE_KEY": key,
        "HAMSTERDAN_GITHUB_WEBHOOK_SECRET": WEBHOOK_SECRET,
        "HAMSTERDAN_PI_PROVIDER": "anthropic",
        "HAMSTERDAN_PI_MODEL": "claude-sonnet-4-5",
        "HAMSTERDAN_PI_API_KEY": "rehearsal-not-a-key",
        "HAMSTERDAN_WORKFLOW_PATH": ".github/workflows/ci.yml",
        "HAMSTERDAN_REMINDER_SECONDS": "300",
        "HAMSTERDAN_HOST": "127.0.0.1",
        "HAMSTERDAN_PORT": str(port),
        "HAMSTERDAN_E2E_GITHUB_PORT": str(github_port),
        **pi_fixture(work / "pi"),
    }


def get(url: str) -> tuple[int, object]:
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")


def deliver(port: int) -> tuple[int, object]:
    signature = "sha256=" + hmac.new(WEBHOOK_SECRET.encode(), BODY, hashlib.sha256).hexdigest()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/github/webhooks",
        data=BODY,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-GitHub-Delivery": DELIVERY,
            "X-GitHub-Event": "pull_request",
            "X-Hub-Signature-256": signature,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")


def rehearse(command: list[str], work: Path, key: str, extra: dict[str, str], stop: signal.Signals) -> dict[str, object]:
    work.mkdir(parents=True, exist_ok=True)
    log = work / "fake-github.jsonl"
    fake = subprocess.Popen(
        [sys.executable, "-I", "-B", str(HERE / "fake_github.py"), "--log", str(log), "--repository", "31:owner/one", "--repository", "32:owner/two"],
        stdout=subprocess.PIPE,
        text=True,
    )
    host = None
    report: dict[str, object] = {}
    try:
        github_port = int(fake.stdout.readline().split()[1])
        port = free_port()
        env = {**environment(work, key, port, github_port), **extra}
        with (work / "host.log").open("w") as output:
            host = subprocess.Popen([*command, "serve"], env=env, stdout=output, stderr=subprocess.STDOUT, cwd=work)
            health: object = None
            for _ in range(600):
                if host.poll() is not None:
                    break
                try:
                    health = get(f"http://127.0.0.1:{port}/healthz")
                    break
                except (urllib.error.URLError, ConnectionError, OSError):
                    time.sleep(0.1)
            report["health"] = health
            report["webhook"] = deliver(port) if host.poll() is None else None
            if host.poll() is None:
                host.send_signal(stop)
            try:
                report["exit"] = host.wait(timeout=60)
            except subprocess.TimeoutExpired:
                host.kill()
                report["exit"] = host.wait()
        report["github"] = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        report["log_tail"] = (work / "host.log").read_text(errors="replace")[-2000:]
    finally:
        if host is not None and host.poll() is None:
            host.kill()
            host.wait()
        fake.terminate()
        fake.wait()
        fake.stdout.close()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--reference", required=True, help="the reference environment's python")
    parser.add_argument("--haskell-host", required=True, help="the hamsterdan-e2e-host executable")
    parser.add_argument("--agents", type=Path)
    parser.add_argument("--signal", choices=("TERM", "INT"), default="TERM")
    parser.add_argument("--key", type=Path, default=REPOSITORY / "packages" / "hamsterdan-github" / "test" / "corpus" / "app-test-key.pem")
    args = parser.parse_args()
    key = args.key.read_text()
    agents = {"HAMSTERDAN_E2E_AGENTS": str(args.agents.absolute())} if args.agents else {}
    tape = args.work.absolute() / "python" / "tape"
    stop = signal.Signals["SIG" + args.signal]
    report = {
        "python": rehearse(
            [os.path.abspath(args.reference), "-I", "-B", str(HERE / "e2e_host.py")],
            args.work.absolute() / "python",
            key,
            {**agents, "HAMSTERDAN_E2E_RECORD": str(tape)},
            stop,
        ),
        "haskell": rehearse([os.path.abspath(args.haskell_host)], args.work.absolute() / "haskell", key, agents, stop),
    }
    steps = [json.loads(line) for line in (tape / "steps.jsonl").read_text().splitlines()] if (tape / "steps.jsonl").exists() else []
    report["python"]["tape_steps"] = [{k: v for k, v in step.items() if k not in ("clock", "body")} for step in steps]
    report["python"]["tape_meta"] = json.loads((tape / "meta.json").read_text()) if (tape / "meta.json").exists() else None
    secrets = [WEBHOOK_SECRET, key.strip().splitlines()[1] if len(key.strip().splitlines()) > 1 else key]
    report["secrets_on_disk"] = [
        str(path.relative_to(tape)) for path in sorted(tape.glob("*")) if any(secret in path.read_text(errors="replace") for secret in secrets)
    ] if tape.exists() else []
    print(json.dumps(report, sort_keys=True, indent=1))


if __name__ == "__main__":
    main()
