"""Durable execution custody across a crash, under the pinned reference.

    custody_interop.py provision PROVIDER OPERATION
        create the scenario's territory, print the lease as JSON, and die
        (os._exit: no cleanup, no finalizers), leaving whatever custody state
        the provider keeps durably;
    custody_interop.py resume PROVIDER OPERATION LEASE_JSON
        recover the operation as a fresh process would (lookup-first
        reconcile), execute in the territory, destroy the dead process's
        lease, and print the report as JSON.

PROVIDER is ``local``, ``docker`` or ``gondolin``. Docker runs whatever
``docker`` is on PATH (the suite puts ``fake_docker.py`` there, with
``DOCKER_FAKE_STATE``); Gondolin reads ``PETRUS_CUSTODY_GONDOLIN_ROOT`` and
``PETRUS_CUSTODY_GONDOLIN_SDK``. The Haskell suite (``CustodyInteropSpec``)
runs the same two steps in Haskell and checks that every pairing of the two
languages reports what the reference reports against itself.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

from petrus.motus.execution import (
    Command,
    EnvironmentCapability,
    EnvironmentLease,
    EnvironmentSpec,
    LeaseState,
    PrivateFile,
)
from petrus.motus.execution.archive import extract_workspace_archive, workspace_archive
from petrus.motus.execution.gondolin import GondolinEnvironment
from petrus.motus.execution.providers import DockerEnvironment, LocalProcessEnvironment

PRIVATE = EnvironmentCapability.PRIVATE_FILE_TRANSFER.value


def provider(name: str):
    if name == "local":
        return LocalProcessEnvironment()
    if name == "docker":
        return DockerEnvironment()
    if name == "gondolin":
        return GondolinEnvironment(
            Path(os.environ["PETRUS_CUSTODY_GONDOLIN_ROOT"]),
            sdk_module=os.environ["PETRUS_CUSTODY_GONDOLIN_SDK"],
            lease_ttl=30,
        )
    raise SystemExit(f"unknown provider {name!r}")


def specs(name: str) -> tuple[EnvironmentSpec, EnvironmentSpec]:
    """The scenario's spec, and a materially different one."""
    if name == "local":
        return EnvironmentSpec(required_capabilities=frozenset({PRIVATE})), EnvironmentSpec()
    if name == "docker":
        return EnvironmentSpec("fake/image:1"), EnvironmentSpec("fake/image:2")
    return EnvironmentSpec("fake-image", frozenset({PRIVATE})), EnvironmentSpec("other-image")


def lease_json(lease: EnvironmentLease) -> dict:
    return {
        "operation_id": lease.operation_id,
        "provider": lease.provider,
        "lease_id": lease.lease_id,
        "capabilities": sorted(lease.capabilities),
        "state": lease.state.value,
    }


def lease_from_json(value: dict) -> EnvironmentLease:
    return EnvironmentLease(
        value["operation_id"], value["provider"], value["lease_id"], frozenset(value["capabilities"]), LeaseState(value["state"])
    )


def describe(lease: EnvironmentLease | None, provisioned: EnvironmentLease, created: EnvironmentLease | None = None):
    """A lease as the report spells it: none, the dead process's, the one
    this process created, or another."""
    if lease is None:
        return None
    if lease == provisioned:
        return "provisioned"
    if lease == created:
        return "created"
    return {"new": {"capabilities": sorted(lease.capabilities), "state": lease.state.value}}


def error(exception: BaseException) -> dict:
    return {"error": [type(exception).__name__, str(exception)]}


def files(archive: bytes) -> dict:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        extract_workspace_archive(archive, root)
        return {str(path.relative_to(root)): path.read_text() for path in sorted(root.rglob("*")) if path.is_file()}


def provision(name: str, operation: str) -> None:
    lease = provider(name).create(operation, specs(name)[0])
    sys.stdout.write(json.dumps(lease_json(lease)) + "\n")
    sys.stdout.flush()
    os._exit(0)


def resume(name: str, operation: str, provisioned_json: str) -> None:
    environment = provider(name)
    spec, other = specs(name)
    provisioned = lease_from_json(json.loads(provisioned_json))
    report: dict = {}
    reconciled = environment.reconcile(operation)
    report["reconcile"] = {
        "classification": reconciled.classification.value,
        "lease": describe(reconciled.lease, provisioned),
        "detail": reconciled.detail,
    }
    report["lookup"] = describe(environment.lookup(operation), provisioned)
    lease = environment.create(operation, spec)
    report["create"] = describe(lease, provisioned)
    try:
        report["collide"] = describe(environment.create(operation, other), provisioned, lease)
    except (RuntimeError, ValueError) as failure:
        report["collide"] = error(failure)
    with tempfile.TemporaryDirectory() as temporary:
        source = Path(temporary)
        (source / "input").write_text("host")
        archive = workspace_archive(source)
    attachment = environment.attach(lease, archive, "custody-digest")
    result = environment.execute(attachment, Command(("/bin/sh", "-c", "/bin/cat input; printf done > output")))
    report["execute"] = [result.returncode, result.stdout.decode(), result.stderr.decode(), result.timed_out]
    if PRIVATE in lease.capabilities:
        reference = environment.import_private_file(attachment, PrivateFile("secret", b"canary"))
        bound = environment.execute(
            attachment,
            Command(
                ("/bin/sh", "-c", '/bin/cat "$PRIVATE/secret"; printf after > "$PRIVATE/secret"'),
                private_roots={"PRIVATE": reference},
            ),
        )
        exported = environment.export_private_file(attachment, reference)
        cleaned = environment.cleanup_private_files(attachment)
        report["private"] = {
            "execute": [bound.returncode, bound.stdout.decode(), bound.stderr.decode()],
            "export": [exported.name, exported.content.decode()],
            "cleanup": [cleaned.disposition.value, cleaned.removed, cleaned.verified],
        }
    else:
        report["private"] = None
    report["export"] = files(environment.export(attachment))
    destroyed = environment.destroy(provisioned)
    report["destroy"] = [destroyed.disposition.value, destroyed.detail]
    if lease != provisioned:
        destroyed = environment.destroy(lease)
        report["destroy_new"] = [destroyed.disposition.value, destroyed.detail]
    else:
        report["destroy_new"] = None
    report["after"] = describe(environment.lookup(operation), provisioned, lease)
    after = environment.reconcile(operation)
    report["reconcile_after"] = [after.classification.value, after.detail]
    print(json.dumps(report, sort_keys=True))


def main() -> None:
    command, *arguments = sys.argv[1:]
    {"provision": provision, "resume": resume}[command](*arguments)


if __name__ == "__main__":
    main()
