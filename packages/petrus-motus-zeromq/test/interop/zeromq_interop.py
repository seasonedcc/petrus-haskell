"""The reference's half of the ZeroMQ Dispatch interop suite (run from upstream/petrus).

Subcommands:
  certs DIR                       create server, client, and stranger CURVE
                                  certificates with zmq.auth under DIR/certificates,
                                  allow the client in DIR/allowed; print the paths
  client ENDPOINT SECRET PUBLIC   drive a server (any implementation) with the
                                  reference's synchronous client and native
                                  asynchronous access over the scenario below;
                                  SECRET/PUBLIC are CURVE certificate files or "-";
                                  print a JSON report
  classified                      print the reference's _classified_failure of
                                  each exception in CLASSIFIED_CASES, in order

The client scenario expects four dispatched occurrences of ``scenario_call()``
on queue "cpu" (in order 1..4); the Haskell suite dispatches them and checks
the collected outcomes after the report.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, os.getcwd())

import zmq  # noqa: E402
import zmq.auth  # noqa: E402

from petrus.motus.activity import ActivityFailure, ActivityInvocation, ExecutionPolicy  # noqa: E402
from petrus.motus.transport.zeromq import (  # noqa: E402
    AsyncZeroMQWorkerAccess,
    OperationUncertain,
    ZeroMQWorkerDispatch,
    _classified_failure,
    _ProtocolError,
)


def scenario_call() -> ActivityInvocation:
    return ActivityInvocation(
        "work",
        input={"nested": [1, {"faithful": True}], "text": "café ☃", "float": 1.5},
        policy=ExecutionPolicy(
            attempts=3,
            heartbeat_timeout=4,
            initial_interval=5,
            coefficient=3,
            max_interval=20,
            start_to_close=40,
            schedule_to_close=90,
        ),
        correlation="correlation",
        idempotency="idempotency",
    )


def certs(directory: str) -> None:
    root = Path(directory)
    certificates = root / "certificates"
    allowed = root / "allowed"
    certificates.mkdir()
    allowed.mkdir()
    server_public, server_secret = zmq.auth.create_certificates(certificates, "server")
    client_public, client_secret = zmq.auth.create_certificates(certificates, "client")
    _, stranger_secret = zmq.auth.create_certificates(certificates, "stranger")
    shutil.copy(client_public, allowed / "client.key")
    print(
        json.dumps(
            {
                "server_public": str(server_public),
                "server_secret": str(server_secret),
                "client_secret": str(client_secret),
                "stranger_secret": str(stranger_secret),
                "allowed": str(allowed),
            }
        )
    )


def error_of(action) -> dict:
    try:
        action()
    except Exception as error:  # noqa: BLE001 - the report names the type
        return {"type": type(error).__name__, "message": str(error)}
    return {"type": None, "message": None}


def attempt_report(attempt) -> dict:
    return {
        "attempt_id": attempt.attempt_id,
        "epoch": attempt.epoch,
        "claimant": attempt.claimant,
        "queue": attempt.queue,
        "instance": attempt.instance,
        "latest_details": attempt.latest_details,
        "invocation_equal": attempt.invocation == scenario_call(),
    }


def client(endpoint: str, secret: str, public: str) -> None:
    keys = {}
    if secret != "-":
        keys = {"client_secret_certificate": secret, "server_public_certificate": public}
    report: dict = {}
    sync = ZeroMQWorkerDispatch(endpoint, queues=("cpu",), worker_id="python-remote", request_timeout=2, **keys)
    try:
        first = sync.claim()
        report["first"] = attempt_report(first)
        report["heartbeats"] = [
            sync.heartbeat(first, details={"progress": [1, 2], "note": "é"}),
            sync.heartbeat(first),
            sync.heartbeat(first, details=None),
        ]
        result = {"completed": [True], "text": "☃"}
        sync.complete(first, result)
        sync.complete(first, result)
        report["stale"] = error_of(lambda: sync.heartbeat(first))
        report["conflict"] = error_of(lambda: sync.complete(first, {"completed": [False]}))
        second = sync.claim()
        report["second"] = attempt_report(second)
        sync.fail(
            second,
            ActivityFailure("invalid", kind="InvalidRequest", details={"field": "name"}, retryable=False, retry_after=7),
        )

        async def native() -> dict:
            access = await AsyncZeroMQWorkerAccess.create(
                endpoint, queues=("cpu",), worker_id="python-async", request_timeout=2, **keys
            )
            try:
                third = await access.claim(0)
                details = await access.heartbeat(0, third, details={"cursor": 1})
                await access.complete(0, third, {"async": True})
                fourth = await access.claim(0)
                await access.fail(0, fourth, "boom")
                empty = await access.claim(0)
                return {
                    "third": attempt_report(third),
                    "heartbeat": details,
                    "fourth": attempt_report(fourth),
                    "empty": empty is None,
                }
            finally:
                await access.close()

        report["native"] = asyncio.run(native())
        report["drained"] = sync.claim() is None
    finally:
        sync.close()
    if secret != "-":
        stranger_secret = str(Path(secret).parent / "stranger.key_secret")
        stranger = ZeroMQWorkerDispatch(
            endpoint,
            queues=("cpu",),
            client_secret_certificate=stranger_secret,
            server_public_certificate=public,
            request_timeout=0.2,
        )
        try:
            report["stranger"] = error_of(stranger.claim)
        finally:
            stranger.close()
    print(json.dumps(report, sort_keys=True))


# The exceptions a Worker may report as themselves; the Haskell suite throws
# its twins in the same order.
CLASSIFIED_CASES = (
    ValueError("heartbeat details require finite JSON numbers"),
    ValueError(),
    ValueError("it's \"quoted\"\u00a0é\n"),
    RuntimeError("Activity cancelled: stop"),
    LookupError("no Activity implementation for 'x'"),
    TypeError("Activity failure must be a string, exception, or ActivityFailure"),
    TimeoutError("ZeroMQ Dispatch server did not become ready"),
    ConnectionError("ZeroMQ claim was not acknowledged"),
    OperationUncertain("ZeroMQ complete response was lost"),
    _ProtocolError("unsupported ZeroMQ Dispatch protocol version"),
)


def classified() -> None:
    failures = [_classified_failure(case) for case in CLASSIFIED_CASES]
    print(json.dumps([{"error": f.error, "kind": f.kind, "retryable": f.retryable} for f in failures]))


def main() -> None:
    command, *arguments = sys.argv[1:]
    {"certs": certs, "client": client, "classified": classified}[command](*arguments)


if __name__ == "__main__":
    main()
