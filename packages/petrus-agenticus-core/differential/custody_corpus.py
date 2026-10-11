"""Generate the Agent Connection custody differential corpus from the reference.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/differential/custody_corpus.py

It writes ``custody_corpus.json`` next to this script (or into the directory given as its first argument):

* ``schema``: ``sqlite_master`` rows of a fresh store (the DDL text SQLite keeps)
  and the initial payload row.
* ``key_contexts``: ``KeyContext`` validation outcomes and
  ``authenticated_data()`` bytes.
* ``payload_cases``: stored payload texts (real ones and mutations) with the
  outcome of ``_decode``: the canonical re-encoding, or the refusal.
* ``sessions``: seeded scripted custody sessions over a real SQLite file and
  materializer.  After every step the corpus records the step's outcome (a
  result summary or the refusal), the store revision, the SHA-256 of the exact
  stored payload text (the full text every ``FULL_PAYLOAD_EVERY`` steps and at
  the end), and the materialized file names.

The step interpreter (``run_steps``) is shared with ``custody_interop.py``,
which continues a session another implementation started.  Key operations are
deterministic and stateless (the AES-GCM nonce is derived from the context and
plaintext), and the fake provider is a pure function of its JSON state, so a
session can move between processes and implementations mid-run.
"""

from __future__ import annotations

import json
import sys
import math
import os
import random
import shutil
import sqlite3
import tempfile
from hashlib import sha256
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from petrus.agenticus.connection.custody import (
    AgentConnectionCustody,
    AttachmentFence,
    ConnectionIdentity,
    LeaseMode,
    Materialization,
    OpaqueState,
    _fence,
)
from petrus.agenticus.connection.key import KeyContext, KeyErasureEvidence, KeyOperationError
from petrus.agenticus.connection.materialization import MaterializedState, PrivateFileMaterializer
from petrus.agenticus.connection.storage import SqliteConnectionStorage, _decode, _encode


KEY = sha256(b"synthetic-installation-key-canary").digest()
PROVIDER = "fake-rotating-oauth"
PROFILE = "subscription_oauth"
FULL_PAYLOAD_EVERY = 10
SESSIONS = 30
STEPS = 50
HERE = Path(__file__).resolve().parent


class CorpusKeys:
    """Deterministic, stateless AEAD key operations for the corpus."""

    def __init__(self) -> None:
        self.fail_erasure = False

    def seal(self, context: KeyContext, plaintext: bytearray) -> bytes:
        aad = context.authenticated_data()
        nonce = sha256(b"petrus-custody-corpus-nonce\0" + aad + b"\0" + bytes(plaintext)).digest()[:12]
        return nonce + AESGCM(KEY).encrypt(nonce, bytes(plaintext), aad)

    def open(self, context: KeyContext, ciphertext: bytes) -> bytearray:
        try:
            return bytearray(AESGCM(KEY).decrypt(ciphertext[:12], ciphertext[12:], context.authenticated_data()))
        except (InvalidTag, ValueError) as error:
            raise KeyOperationError("encrypted connection state failed integrity verification") from error

    def erase(self, connection_id: str) -> KeyErasureEvidence:
        if self.fail_erasure:
            raise KeyOperationError("synthetic key erasure failed")
        return KeyErasureEvidence(connection_id=connection_id, erased=True)


def provider_state(account: str, generation: int) -> bytes:
    state = {
        "account": account,
        "generation": generation,
        "access_token": f"access-{account}-{generation}",
        "refresh_token": f"refresh-{account}-{generation}",
    }
    return json.dumps(state, sort_keys=True, separators=(",", ":")).encode()


def fingerprint(account: str) -> str:
    return sha256(f"fp-{account}".encode()).hexdigest()


def number(value: object) -> float:
    if value == "nan":
        return math.nan
    if value == "inf":
        return math.inf
    return float(value)  # type: ignore[arg-type]


def view_data(view) -> dict:
    return {
        "connection_id": view.identity.connection_id,
        "provider": view.identity.provider,
        "account_fingerprint": view.identity.account_fingerprint,
        "profile": view.identity.profile,
        "status": view.status.value,
        "authority_epoch": view.authority_epoch,
        "state_version": view.state_version,
        "state_digest": view.state_digest,
    }


def evidence_data(evidence) -> dict:
    return {
        "attachment_id": evidence.attachment_id,
        "removed": evidence.removed,
        "already_absent": evidence.already_absent,
        "bytes_overwritten": evidence.bytes_overwritten,
        "physical_erasure_guaranteed": evidence.physical_erasure_guaranteed,
        "security_violation": evidence.security_violation,
    }


def summary_data(summary) -> dict:
    return {
        "attempted": summary.attempted,
        "removed": summary.removed,
        "already_absent": summary.already_absent,
        "unresolved": summary.unresolved,
        "security_violations": summary.security_violations,
        "physical_erasure_guaranteed": summary.physical_erasure_guaranteed,
    }


def fence_data(fence: AttachmentFence) -> dict:
    return {
        "attachment_id": fence.attachment_id,
        "lease_id": fence.lease_id,
        "connection_id": fence.connection_id,
        "host_id": fence.host_id,
        "host_epoch": fence.host_epoch,
        "authority_epoch": fence.authority_epoch,
        "base_version": fence.base_version,
    }


class Session:
    """One custody installation under ``workdir`` plus the interpreter state."""

    def __init__(self, workdir: Path) -> None:
        self.root = workdir / "installation"
        self.keys = CorpusKeys()
        self.instant = 1_000.0
        self.storage = SqliteConnectionStorage(self.root / "connections.sqlite3")
        self.materializer = PrivateFileMaterializer(self.root / "materialized")
        self.custody = AgentConnectionCustody(self.storage, self.keys, self.materializer, clock=lambda: self.instant)
        self.slots: dict[str, Materialization] = {}

    def close(self) -> None:
        self.custody.close()

    def resume(self, earlier: list[dict]) -> None:
        """Rebuild the clock and the live views of ``earlier`` steps from the store."""
        leases = {lease.lease_id: lease for lease in self.storage.load().leases}
        for step in earlier:
            if step["op"] == "advance":
                self.instant += number(step["seconds"])
            elif step["op"] == "materialize":
                lease_id = "lease-" + sha256(step["operation_id"].encode()).hexdigest()[:32]
                lease = leases.get(lease_id)
                if lease is not None and step["operation_id"] not in self.slots:
                    self.slots[step["operation_id"]] = Materialization(
                        _fence(lease),
                        LeaseMode(lease.mode),
                        lease.expires_at,
                        MaterializedState(self.materializer, lease.attachment_id),
                    )

    def observe(self, index: int, last: bool) -> dict:
        with sqlite3.connect(self.root / "connections.sqlite3") as database:
            revision, payload = database.execute(
                "SELECT revision, payload FROM connection_custody WHERE singleton = 1"
            ).fetchone()
        database.close()
        record: dict = {
            "revision": revision,
            "payload_sha256": sha256(payload.encode()).hexdigest(),
            "files": sorted(os.listdir(self.root / "materialized")),
        }
        if last or (index + 1) % FULL_PAYLOAD_EVERY == 0:
            record["payload"] = payload
        return record

    def step(self, step: dict) -> dict:
        try:
            return {"ok": self._run(step)}
        except Exception as error:  # noqa: BLE001 - the refusal is the observation
            return {"error": {"class": type(error).__name__, "message": str(error)}}

    def _run(self, step: dict) -> object:
        op = step["op"]
        custody = self.custody
        if op == "advance":
            self.instant += number(step["seconds"])
            return None
        if op == "enroll":
            return custody.enroll_host(step["host"], operation_id=step["operation_id"])
        if op == "remove":
            removal = custody.remove_host(step["host"], operation_id=step["operation_id"])
            return {
                "host_id": removal.host_id,
                "canceled_leases": removal.canceled_leases,
                "cleanup": summary_data(removal.cleanup),
                "offline_erasure_limit": removal.offline_erasure_limit,
            }
        if op in {"authorize", "rotate"}:
            state = OpaqueState(provider_state(step["account"], step["generation"]))
            try:
                if op == "authorize":
                    identity = ConnectionIdentity(step["connection"], PROVIDER, fingerprint(step["account"]), PROFILE)
                    view = custody.authorize(identity, state, operation_id=step["operation_id"])
                else:
                    view = custody.rotate(step["connection"], state, operation_id=step["operation_id"])
            finally:
                step["_erased"] = state.erased
            return {"view": view_data(view), "opaque_erased": state.erased}
        if op == "materialize":
            materialization = custody.materialize(
                step["connection"],
                step["host"],
                mode=LeaseMode(step["mode"]),
                ttl=number(step["ttl"]),
                operation_id=step["operation_id"],
            )
            self.slots[step["operation_id"]] = materialization
            return {
                "fence": fence_data(materialization.fence),
                "mode": materialization.mode.value,
                "expires_at": materialization.expires_at,
                "home": materialization.home.read().decode(),
            }
        slot = self.slots.get(step.get("slot", ""))
        if op == "activate":
            return custody.activate(slot, operation_id=step["operation_id"])
        if op == "renew":
            renewal = custody.renew(slot, ttl=number(step["ttl"]), operation_id=step["operation_id"])
            return {"expires_at": renewal.expires_at}
        if op == "refresh_home":
            current = slot.home.read()
            if not current:
                return "empty"
            state = json.loads(current)
            slot.home.replace(provider_state(state["account"], state["generation"] + 1))
            return state["generation"] + 1
        if op == "empty_home":
            path = slot.home.path
            if path.exists() and not path.is_symlink():
                with open(path, "wb"):
                    pass
                return True
            return False
        if op == "checkpoint":
            publication = custody.checkpoint(slot, operation_id=step["operation_id"])
            return {"view": view_data(publication.connection), "cleanup": evidence_data(publication.cleanup)}
        if op == "release":
            release = custody.release(slot, operation_id=step["operation_id"])
            return {"cleanup": evidence_data(release.cleanup)}
        if op == "revoke":
            revocation = custody.revoke(step["connection"], operation_id=step["operation_id"])
            return {
                "view": view_data(revocation.connection),
                "cleanup": summary_data(revocation.cleanup),
                "provider_revocation": revocation.provider_revocation,
                "offline_erasure_limit": revocation.offline_erasure_limit,
            }
        if op == "erase":
            self.keys.fail_erasure = step["fail"]
            try:
                erasure = custody.erase(step["connection"], operation_id=step["operation_id"])
            finally:
                self.keys.fail_erasure = False
            return {
                "view": view_data(erasure.connection),
                "key_erasure": {
                    "connection_id": erasure.key_erasure.connection_id,
                    "erased": erasure.key_erasure.erased,
                },
                "cleanup": summary_data(erasure.cleanup),
                "physical_media_erasure_guaranteed": erasure.physical_media_erasure_guaranteed,
            }
        if op in {"admit_result", "admit_effect"}:
            fence = slot.fence
            if step["forge"]:
                fence = AttachmentFence(
                    "attachment-forged",
                    fence.lease_id,
                    fence.connection_id,
                    fence.host_id,
                    fence.host_epoch,
                    fence.authority_epoch,
                    fence.base_version,
                )
            admit = custody.admit_result if op == "admit_result" else custody.admit_effect
            admission = admit(fence, operation_id=step["operation_id"])
            return {
                "operation_id": admission.operation_id,
                "purpose": admission.purpose,
                "attachment_id": admission.attachment_id,
            }
        if op == "recover":
            recovery = custody.recover(operation_id=step["operation_id"])
            return {
                "expired_leases": recovery.expired_leases,
                "ambiguous_connections": list(recovery.ambiguous_connections),
                "cleanup": summary_data(recovery.cleanup),
            }
        if op == "lookup":
            view = custody.lookup_operation(step["operation_id"])
            if view is None:
                return None
            return {
                "operation_id": view.operation_id,
                "event_kind": view.event_kind,
                "connection_id": view.connection_id,
                "host_id": view.host_id,
                "lease_id": view.lease_id,
                "details": [list(item) for item in view.details],
            }
        if op == "connection":
            return view_data(custody.connection(step["connection"]))
        raise AssertionError(f"unknown step {op}")


def run_steps(workdir: Path, steps: list[dict], start: int, stop: int, *, total: int | None = None) -> list[dict]:
    """Run ``steps[start:stop]`` against the installation under ``workdir``."""
    session = Session(workdir)
    try:
        session.resume(steps[:start])
        records = []
        last_index = (len(steps) if total is None else total) - 1
        for index in range(start, stop):
            step = steps[index]
            outcome = session.step(dict(step))
            records.append({"outcome": outcome, **session.observe(index, index == last_index)})
        return records
    finally:
        session.close()


# ---------------------------------------------------------------------------
# Session generation


def generate_session(seed: int) -> dict:
    rng = random.Random(seed)
    workdir = Path(tempfile.mkdtemp(prefix="custody-corpus-"))
    session = Session(workdir)
    steps: list[dict] = []
    records: list[dict] = []
    published: list[str] = []
    failed_erasures: dict[str, str] = {}
    queued: list[dict] = []
    hosts = ["h1", "h2", "h3"]
    connections = ["c1", "c2"]
    enrolled: list[str] = []
    counter = 0

    def operation_id() -> str:
        nonlocal counter
        if published and rng.random() < 0.05:
            return rng.choice(published)
        counter += 1
        return f"op-{seed}-{counter}"

    def host() -> str:
        if enrolled and rng.random() < 0.85:
            return rng.choice(enrolled)
        return rng.choice(hosts + ([" h4"] if rng.random() < 0.1 else []))

    def connection() -> str:
        return rng.choice(connections + (["c3", " bad"] if rng.random() < 0.1 else []))

    def random_step() -> dict:
        slots = list(session.slots)
        choices = [
            ("enroll", 1),
            ("remove", 0.4),
            ("authorize", 0.8),
            ("rotate", 0.5),
            ("materialize", 3),
            ("advance", 1.2),
            ("revoke", 0.6),
            ("erase", 0.9),
            ("recover", 0.5),
            ("lookup", 0.5),
            ("connection", 0.5),
        ]
        if slots:
            choices += [
                ("activate", 1),
                ("renew", 1),
                ("refresh_home", 0.8),
                ("empty_home", 0.2),
                ("checkpoint", 1),
                ("release", 2),
                ("admit_result", 0.7),
                ("admit_effect", 0.7),
            ]
        op = rng.choices([name for name, _ in choices], [weight for _, weight in choices])[0]
        step: dict = {"op": op}
        if op in {"enroll", "remove"}:
            step["host"] = host()
        if op in {"authorize", "rotate", "revoke", "erase", "connection"}:
            step["connection"] = connection()
        if op in {"authorize", "rotate"}:
            step["account"] = rng.choice(["a1", "a1", "a2"])
            step["generation"] = rng.randrange(0, 4)
        if op == "materialize":
            step["connection"] = rng.choice(connections)
            step["host"] = host()
            step["mode"] = rng.choice(["read", "read", "refresh"])
            unusual = [0.25, 0, -1, "nan", "inf"]
            step["ttl"] = rng.choice([5, 10, 30, 60, 2.5] + (unusual if rng.random() < 0.15 else []))
        if op == "renew":
            step["ttl"] = rng.choice([5, 10, 30, 0.75, "inf", 0])
        if op == "advance":
            step["seconds"] = rng.choice([0.5, 1, 3, 6, 11, 31, 61])
        if op == "erase":
            step["fail"] = rng.random() < 0.3
        if op in {"admit_result", "admit_effect"}:
            step["forge"] = rng.random() < 0.2
        if slots and op in {
            "activate",
            "renew",
            "refresh_home",
            "empty_home",
            "checkpoint",
            "release",
            "admit_result",
            "admit_effect",
        }:
            refresh = [name for name in slots if session.slots[name].mode is LeaseMode.REFRESH]
            if op in {"activate", "checkpoint", "refresh_home"} and refresh and rng.random() < 0.8:
                step["slot"] = refresh[-1]
            else:
                step["slot"] = slots[-1] if rng.random() < 0.6 else rng.choice(slots)
        if op == "lookup":
            step["operation_id"] = rng.choice(published) if published and rng.random() < 0.8 else f"unknown-{seed}"
        elif op == "erase" and step["connection"] in failed_erasures and rng.random() < 0.7:
            step["operation_id"] = failed_erasures[step["connection"]]
        elif op not in {"advance", "refresh_home", "empty_home"}:
            step["operation_id"] = operation_id()
        return step

    def refresh_cycle() -> list[dict]:
        cycle = operation_id()
        return [
            {
                "op": "materialize",
                "connection": rng.choice(connections),
                "host": host(),
                "mode": "refresh",
                "ttl": 30,
                "operation_id": cycle,
            },
            {"op": "activate", "slot": cycle, "operation_id": operation_id()},
            {"op": "refresh_home", "slot": cycle},
            {"op": "checkpoint", "slot": cycle, "operation_id": operation_id()},
        ]

    opening = [
        {"op": "enroll", "host": "h1"},
        {"op": "enroll", "host": "h2"},
        {"op": "authorize", "connection": "c1", "account": "a1", "generation": 0},
    ]
    try:
        for index in range(STEPS):
            if index < len(opening):
                step = {**opening[index], "operation_id": operation_id()}
            else:
                if not queued and index < STEPS - 4 and rng.random() < 0.12:
                    queued = refresh_cycle()
                step = queued.pop(0) if queued else random_step()
            op = step["op"]
            outcome = session.step(dict(step))
            if op == "materialize" and "error" in outcome:
                queued = []
            if op == "enroll" and "ok" in outcome and step["host"] not in enrolled:
                enrolled.append(step["host"])
            if op == "remove" and "ok" in outcome and step["host"] in enrolled:
                enrolled.remove(step["host"])
            if op == "erase" and "error" in outcome and outcome["error"]["class"] == "KeyOperationError":
                failed_erasures[step["connection"]] = step["operation_id"]
            if "operation_id" in step and op != "lookup":
                published.append(step["operation_id"])
            steps.append(step)
            records.append({"outcome": outcome, **session.observe(index, index == STEPS - 1)})
    finally:
        session.close()
        shutil.rmtree(workdir, ignore_errors=True)
    return {"seed": seed, "steps": steps, "records": records}


# ---------------------------------------------------------------------------
# Schema, key contexts, and payload cases


def schema() -> dict:
    workdir = Path(tempfile.mkdtemp(prefix="custody-schema-"))
    try:
        path = workdir / "store" / "connections.sqlite3"
        SqliteConnectionStorage(path).close()
        with sqlite3.connect(path) as database:
            rows = database.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name").fetchall()
            initial = database.execute("SELECT singleton, revision, payload FROM connection_custody").fetchall()
        database.close()
        return {
            "sqlite_master": [list(row) for row in rows],
            "rows": [list(row) for row in initial],
        }
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def key_contexts() -> list[dict]:
    cases = []
    for connection_id, epoch, version in (
        ("connection-main", 1, 1),
        ("c", 7, 12),
        ("conexão-☃", 3, 99999999999),
        ("", 1, 1),
        ("c", 0, 1),
        ("c", 1, 0),
        ("c", -2, 1),
        (" spaced ", 1, 2),
    ):
        try:
            context = KeyContext(connection_id, epoch, version)
            outcome = {"ok": context.authenticated_data().hex()}
        except Exception as error:  # noqa: BLE001
            outcome = {"error": {"class": type(error).__name__, "message": str(error)}}
        cases.append({"connection_id": connection_id, "authority_epoch": epoch, "state_version": version, **outcome})
    return cases


def decode_outcome(payload: str) -> dict:
    try:
        return {"ok": _encode(_decode(payload))}
    except Exception as error:  # noqa: BLE001
        return {"error": {"class": type(error).__name__, "message": str(error)}}


def payload_cases(sessions: list[dict]) -> list[dict]:
    payloads = [record["payload"] for session in sessions for record in session["records"] if "payload" in record]
    rich = max(payloads, key=lambda text: (len(json.loads(text)["leases"]), len(text)))
    cases: list[tuple[str, str]] = [(f"session-payload-{index}", text) for index, text in enumerate(payloads[:12])]
    base = json.loads(rich)

    def variant(name: str, mutate) -> None:
        data = json.loads(rich)
        mutate(data)
        cases.append((name, json.dumps(data, allow_nan=True)))

    def first(kind: str, data: dict) -> dict:
        return data[kind][0]

    raw = [
        ("not-json", "{"),
        ("array", "[]"),
        ("empty-object", "{}"),
        ("bom", "﻿" + rich),
        ("string", '"payload"'),
        ("trailing-data", rich + " x"),
    ]
    cases += raw
    for key in ("schema_version", "revision", "hosts", "connections", "leases", "audit"):
        variant(f"missing-{key}", lambda data, key=key: data.pop(key))
    variant("schema-2", lambda data: data.update(schema_version=2))
    variant("schema-true", lambda data: data.update(schema_version=True))
    variant("schema-float", lambda data: data.update(schema_version=1.0))
    variant("revision-string", lambda data: data.update(revision="1"))
    variant("revision-negative", lambda data: data.update(revision=-1))
    variant("revision-mismatch", lambda data: data.update(revision=data["revision"] + 1))
    variant("hosts-object", lambda data: data.update(hosts={}))
    variant("extra-key", lambda data: data.update(extra=1))
    # json.loads keeps a lone surrogate escape, which _stored_text accepts;
    # an integer token past 4300 digits raises its ValueError.
    cases.append(("revision-4301-digits", rich.replace(f'"revision":{base["revision"]}', '"revision":' + "1" * 4301, 1)))
    if base["hosts"]:
        variant("host-id-surrogate", lambda data: first("hosts", data).update(host_id="h\ud800"))
    if base["audit"]:
        variant("audit-detail-surrogate", lambda data: first("audit", data)["details"].update(note="\udc80x"))
        variant("audit-detail-name-surrogate", lambda data: first("audit", data)["details"].update({"\ud800": 1}))
    if base["hosts"]:
        variant("host-missing-active", lambda data: first("hosts", data).pop("active"))
        variant("host-id-int", lambda data: first("hosts", data).update(host_id=1))
        variant("host-epoch-bool", lambda data: first("hosts", data).update(enrollment_epoch=True))
        variant("host-epoch-zero", lambda data: first("hosts", data).update(enrollment_epoch=0))
        variant("host-active-int", lambda data: first("hosts", data).update(active=1))
        variant("host-id-untrimmed", lambda data: first("hosts", data).update(host_id=" h1"))
        variant("host-id-control", lambda data: first("hosts", data).update(host_id="h\u0001"))
        variant("hosts-duplicated", lambda data: data.update(hosts=data["hosts"] + data["hosts"][:1]))
        variant("hosts-reversed", lambda data: data.update(hosts=list(reversed(data["hosts"]))))
    if base["connections"]:
        for value in ("@@@@", "QQ", "QQ=", "QR==", "", "A===", "QUJD\n", "é", "QUJD====", "=QUJ", "QU=D"):
            variant(f"base64-{value!r}", lambda data, value=value: first("connections", data).update(encrypted_state=value))
        variant("state-null-ready", lambda data: first("connections", data).update(encrypted_state=None, state_digest=None))
        variant("state-null-digest-kept", lambda data: first("connections", data).update(encrypted_state=None))
        variant("digest-mismatch", lambda data: first("connections", data).update(state_digest="0" * 64))
        variant("status-bogus", lambda data: first("connections", data).update(status="bogus"))
        variant("status-refreshing", lambda data: first("connections", data).update(status="refreshing"))
        variant("connection-version-zero", lambda data: first("connections", data).update(state_version=0))
        variant("connection-provider-empty", lambda data: first("connections", data).update(provider=""))
        variant("connection-long-profile", lambda data: first("connections", data).update(profile="p" * 300))
    if base["leases"]:
        variant("lease-expiry-int", lambda data: first("leases", data).update(expires_at=int(first("leases", data)["expires_at"])))
        variant("lease-expiry-nan", lambda data: first("leases", data).update(expires_at=math.nan))
        variant("lease-expiry-inf", lambda data: first("leases", data).update(expires_at=math.inf))
        variant("lease-expiry-huge", lambda data: first("leases", data).update(expires_at=1e308))
        variant("lease-expiry-string", lambda data: first("leases", data).update(expires_at="1"))
        variant("lease-expiry-bool", lambda data: first("leases", data).update(expires_at=True))
        variant("lease-mode-write", lambda data: first("leases", data).update(mode="write"))
        variant("lease-unknown-host", lambda data: first("leases", data).update(host_id="nowhere"))
        variant("lease-released-no-reason", lambda data: first("leases", data).update(released=True, release_reason=None))
        variant("lease-reason-unreleased", lambda data: first("leases", data).update(released=False, release_reason="x"))
        variant("lease-activated-read", lambda data: first("leases", data).update(mode="read", activated=True))
        variant("lease-live-stale-epoch", lambda data: first("leases", data).update(released=False, release_reason=None, authority_epoch=99))
        variant("leases-duplicated", lambda data: data.update(leases=data["leases"] + data["leases"][:1]))
        variant("leases-reversed", lambda data: data.update(leases=list(reversed(data["leases"]))))
    if base["audit"]:
        variant("audit-sequence-gap", lambda data: first("audit", data).update(sequence=5))
        variant("audit-details-nested", lambda data: first("audit", data)["details"].update(nested={"a": 1}))
        variant("audit-details-nan", lambda data: first("audit", data)["details"].update(ratio=math.nan))
        variant("audit-details-float", lambda data: first("audit", data)["details"].update(ratio=0.1))
        variant("audit-details-unsorted", lambda data: first("audit", data).update(details={"z": 1, "a": None, "m": "x"}))
        variant("audit-event-empty", lambda data: first("audit", data).update(event_kind=""))
        variant("audit-subject-untrimmed", lambda data: first("audit", data).update(connection_id="c1 "))
        variant("audit-operation-int", lambda data: first("audit", data).update(operation_id=7))
        variant("audit-duplicate-operation", lambda data: data["audit"][-1].update(operation_id=data["audit"][0]["operation_id"]))
    cases.append(("duplicate-member-last-wins", rich[:-1] + ',"revision":' + str(base["revision"]) + "}"))
    cases.append(("unicode-escapes", rich.replace('"fake-rotating-oauth"', '"fake-rotating-\\u00f6auth"')))
    cases.append(("non-ascii-provider", rich.replace('"fake-rotating-oauth"', '"fake-rotating-öauth"')))
    return [{"name": name, "payload": payload, **decode_outcome(payload)} for name, payload in cases]


def main() -> None:
    sessions = [generate_session(seed) for seed in range(SESSIONS)]
    corpus = {
        "schema": schema(),
        "key_contexts": key_contexts(),
        "payload_cases": payload_cases(sessions),
        "sessions": sessions,
    }
    output = (Path(sys.argv[1]) if len(sys.argv) > 1 else HERE) / "custody_corpus.json"
    output.write_text(json.dumps(corpus, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    print(f"wrote {output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
