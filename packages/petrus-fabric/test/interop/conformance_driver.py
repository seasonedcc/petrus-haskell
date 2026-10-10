"""The reference's side of the Fabric and process-lifecycle conformance harness.

Run from upstream/petrus with the pinned environment (psycopg from the
``postgres`` extra). The Haskell suites (petrus-fabric and petrus-processes)
write one JSON request per line on stdin:

    {"op": NAME, ...arguments}

and read one JSON answer per line on stdout:

    {"ok": VALUE}  or  {"error": {"category": C, "type": PYTHON_CLASS, "message": M}}

The categories are spec/fabric.md §12's: invalid, conflict, denied,
not-found, schema-refused, storage. Every operation calls the pinned
reference (petrus.fabric, petrus.processes) directly; this file only
translates JSON to the reference's arguments and its answers back to JSON.
The Haskell suites run the same requests against an in-process twin of this
driver (Petrus.Fabric.Conformance.Haskell), so every check is written once
and holds for both implementations.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.getcwd())

import psycopg  # noqa: E402

from petrus.fabric import Endpoint, Envelope, ReplyRoute  # noqa: E402
from petrus.fabric.model import _canonical  # noqa: E402
from petrus.fabric.postgres import (  # noqa: E402
    PostgresFabric,
    _credential,
    ensure_fabric_schema,
    issue_credential,
    register_process,
)
from petrus.fabric.ingress import FabricInbox  # noqa: E402
from petrus.impetus.instance import FiringOutcome, PriorAcknowledgement  # noqa: E402
from petrus.impetus.petrinet import NetPath  # noqa: E402
from petrus.motus.activity import ActivityInvocation  # noqa: E402
from petrus.processes import (  # noqa: E402
    CallError,
    CallRequest,
    CallResult,
    Lineage,
    Provisioning,
    SpawnClaim,
    SpawnOutcome,
    SpawnSpec,
    child_identity,
    error_envelope,
    reply_from_envelope,
    request_envelope,
    request_from_envelope,
    result_envelope,
)
from petrus.processes.postgres import PostgresSpawnRegistry, ensure_lifecycle_schema  # noqa: E402
from petrus.processes.spawn import SpawnActivity, spawn_idempotency  # noqa: E402

CONFLICT_MARKERS = ("conflict", "already accepted by occurrence", "different credential")
HANDLES: dict[int, object] = {}
UNSUPPORTED = object()


def classify(error: BaseException) -> str:
    if isinstance(error, psycopg.Error):
        return "storage"
    if isinstance(error, PermissionError):
        return "denied"
    if isinstance(error, LookupError):
        return "not-found"
    if isinstance(error, RuntimeError):
        return "schema-refused"
    if isinstance(error, (ValueError, TypeError)):
        message = str(error)
        return "conflict" if any(marker in message for marker in CONFLICT_MARKERS) else "invalid"
    return "other"


def handle(value: object) -> int:
    key = len(HANDLES) + 1
    HANDLES[key] = value
    return key


def stamp(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f+00:00")


def route(value) -> ReplyRoute | None:
    return None if value is None else ReplyRoute(value[0], value[1])


def envelope_out(item: Envelope) -> dict:
    return {
        "data": item.to_data(),
        "digest": item.digest,
        "ingress_identity": item.ingress_identity,
        "canonical": _canonical(item.to_data()).decode(),
    }


def envelope_in(args: dict) -> Envelope:
    return Envelope(
        args["delivery_id"],
        args["sender"],
        args["recipient"],
        args["source"],
        args["correlation"],
        args["payload"],
        route(args.get("reply_route")),
    )


def receipt_out(receipt) -> dict | None:
    if receipt is None:
        return None
    return {
        "sender": receipt.sender,
        "delivery_id": receipt.delivery_id,
        "recipient": receipt.recipient,
        "source": receipt.source,
        "digest": receipt.digest,
        "state": receipt.state,
        "occurrence": receipt.occurrence,
        "accepted_at": stamp(receipt.accepted_at),
        "payload_retained": receipt.payload_retained,
    }


def spec_out(spec: SpawnSpec) -> dict:
    return {
        "data": spec.to_data(),
        "digest": spec.digest,
        "child": spec.child,
        "canonical": _canonical(spec.to_data()).decode(),
    }


def spec_in(args: dict) -> SpawnSpec:
    return SpawnSpec(
        args["parent"],
        args["spawn_id"],
        args["process_kind"],
        args["source"],
        args["capabilities"],
        args["config"],
        reply_route=route(args.get("reply_route")),
    )


def lineage_out(value: Lineage | None):
    return None if value is None else [value.parent, value.spawn_id, value.child]


def claim_out(value: SpawnClaim) -> list:
    return [value.parent, value.spawn_id, value.child, value.prior_claim]


def reply_out(value) -> dict:
    kind = "result" if isinstance(value, CallResult) else "error"
    return {"kind": kind, "data": value.to_data()}


def invocation_in(args: dict) -> ActivityInvocation:
    return ActivityInvocation(
        args["activity"],
        input=args["input"],
        correlation=args.get("correlation"),
        idempotency=args.get("idempotency"),
    )


class FakeRegistry:
    """test_processes' in-memory registries: "memory" claims the spec's own
    identity (prior after the first claim); "wrong" answers another identity."""

    def __init__(self, kind: str, events: list):
        self.kind = kind
        self.events = events
        self.prior = False

    def claim(self, value):
        self.events.append("claim")
        if self.kind == "wrong":
            return SpawnClaim("other-parent", "other-spawn", child_identity("other-parent", "other-spawn"), False)
        answer = SpawnClaim(value.parent, value.spawn_id, value.child, self.prior)
        self.prior = True
        return answer


class FakeProvisioner:
    """"record" records each Provisioning; "fail-first" raises RuntimeError on
    its first call; "live" returns a live object; "observe" records whether
    the claim row is visible from an independent connection to ``dsn``;
    "reference" also runs the lifecycle demo's DemoProvisioner (the §13.2
    reference profile) with the given parent credential and workspace key."""

    def __init__(self, kind: str, events: list, seen: list, options: dict | None = None):
        self.kind = kind
        self.events = events
        self.seen = seen
        self.options = options or {}
        self.reference = None
        if kind == "reference":
            self.reference = lifecycle_module().DemoProvisioner(
                self.options["dsn"],
                None,
                self.options["parent_credential"],
                bytes.fromhex(self.options["workspace_key"]),
            )

    def ensure(self, value):
        self.events.append("ensure")
        record = {
            "parent": value.parent,
            "spawn_id": value.spawn_id,
            "child": value.child,
            "process_kind": value.process_kind,
            "endpoint": value.endpoint.to_data(),
            "config": _thaw(value.config),
            "reply_route": None if value.reply_route is None else value.reply_route.to_data(),
            "has_credential": hasattr(value, "credential"),
        }
        if self.kind == "observe":
            with psycopg.connect(self.options["dsn"], autocommit=True) as independent:
                record["claim_visible"] = independent.execute(
                    "SELECT count(*) FROM impetus_lifecycle.spawns WHERE parent = %s AND spawn_id = %s",
                    (value.parent, value.spawn_id),
                ).fetchone()[0]
        self.seen.append(record)
        if self.kind == "fail-first" and len(self.seen) == 1:
            raise RuntimeError("lost after claim")
        if self.kind == "live":
            return object()
        if self.reference is not None:
            self.reference.ensure(value)
        return None


class FakeDoor:
    """test_fabric's FakeDoor: "fresh" answers FiringOutcome(source, N), "prior"
    PriorAcknowledgement(identity, N); call number ``fail_on`` raises
    ("raise") or answers a value of another type ("other")."""

    def __init__(self, mode: str, occurrence: int, fail_on):
        self.mode = mode
        self.occurrence = occurrence
        self.fail_on = fail_on
        self.calls: list = []

    def deliver(self, source, tokens, *, identity):
        self.calls.append(
            {"source": source, "colors": [token.color for token in tokens], "identity": identity,
             "data": [_thaw(token.data) for token in tokens]}
        )
        if self.fail_on is not None and len(self.calls) == self.fail_on[1]:
            if self.fail_on[0] == "raise":
                raise RuntimeError("door refused the delivery")
            return ("not", "an", "outcome")
        if self.mode == "prior":
            return PriorAcknowledgement(identity, self.occurrence)
        return FiringOutcome(NetPath(source), self.occurrence, (), (), ())


_DEMO = None


def demo_module():
    global _DEMO
    if _DEMO is None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("cv5_fabric_demo", os.path.join(os.getcwd(), "scripts", "cv5-fabric-demo.py"))
        _DEMO = importlib.util.module_from_spec(spec)
        sys.modules["cv5_fabric_demo"] = _DEMO  # dataclasses resolve their module through sys.modules
        spec.loader.exec_module(_DEMO)
    return _DEMO


_LIFECYCLE = None


def lifecycle_module():
    global _LIFECYCLE
    if _LIFECYCLE is None:
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "cv5_lifecycle_demo", os.path.join(os.getcwd(), "scripts", "cv5-lifecycle-demo.py")
        )
        _LIFECYCLE = importlib.util.module_from_spec(spec)
        sys.modules["cv5_lifecycle_demo"] = _LIFECYCLE
        spec.loader.exec_module(_LIFECYCLE)
    return _LIFECYCLE


def _thaw(value):
    if hasattr(value, "items"):
        return {key: _thaw(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_thaw(item) for item in value]
    return value


def run(op: str, args: dict):  # noqa: C901 - one flat dispatch table
    # -- values ------------------------------------------------------------
    if op == "canonical":
        raw = _canonical(args["value"])
        import hashlib

        return {"text": raw.decode(), "sha256": hashlib.sha256(raw).hexdigest()}
    if op == "envelope":
        return envelope_out(envelope_in(args))
    if op == "envelope_from_data":
        return envelope_out(Envelope.from_data(args["data"]))
    if op == "envelope_host_value":
        payload = {"items": [object()]} if args["kind"] == "object" else {1: "non-string key"}
        return envelope_out(envelope_in({**args["envelope"], "payload": payload}))
    if op == "envelope_from_data_int_key":
        data = Envelope.from_data(args["data"]).to_data()
        return envelope_out(Envelope.from_data({**data, 7: "non-text key"}))
    if op == "envelope_lone_surrogate":
        return envelope_out(envelope_in({**args["envelope"], "source": "\ud800"}))
    if op == "envelope_detached":
        payload = {"nested": [1, {"ok": True}]}
        item = envelope_in({**args["envelope"], "payload": payload})
        payload["nested"][1]["ok"] = False
        mutable = True
        try:
            item.payload["new"] = "mutation"
        except TypeError:
            mutable = False
        return {"payload": _thaw(item.payload), "mutable": mutable}
    if op == "reply_route_from_data":
        value = ReplyRoute.from_data(args["data"])
        return [value.instance_id, value.source]
    if op == "endpoint":
        return Endpoint(args["recipient"], args["source"], args["capabilities"]).to_data()
    if op == "endpoint_from_data":
        return Endpoint.from_data(args["data"]).to_data()
    if op == "credential_ok":
        _credential(args["credential"])
        return True
    if op == "issue_credential":
        return issue_credential()
    # -- connections -------------------------------------------------------
    if op == "connect":
        return handle(psycopg.connect(args["dsn"], autocommit=args["autocommit"]))
    if op == "close":
        HANDLES[args["conn"]].close()
        return None
    if op == "commit":
        HANDLES[args["conn"]].commit()
        return None
    if op == "rollback":
        HANDLES[args["conn"]].rollback()
        return None
    # -- fabric storage ----------------------------------------------------
    if op == "ensure_fabric_schema":
        ensure_fabric_schema(HANDLES[args["conn"]])
        return None
    if op == "register":
        register_process(HANDLES[args["conn"]], args["instance"], args["credential"])
        return None
    if op == "client":
        return handle(PostgresFabric(HANDLES[args["conn"]], args["instance"], args["credential"]))
    client = HANDLES.get(args.get("client")) if "client" in args else None
    if op == "authenticate":
        client.authenticate()
        return None
    if op == "expose":
        client.expose_source(args["source"])
        return None
    if op == "offer":
        client.offer_service(args["source"], args["service"], args["capabilities"])
        return None
    if op == "grant":
        client.grant(args["sender"], args["source"])
        return None
    if op == "revoke":
        client.revoke(args["sender"], args["source"])
        return None
    if op == "discover":
        return [item.to_data() for item in client.discover(args["service"], args.get("capabilities"))]
    if op == "submit":
        submission = client.submit(envelope_in(args["envelope"]))
        return {
            "sender": submission.sender,
            "delivery_id": submission.delivery_id,
            "state": submission.state,
            "duplicate": submission.duplicate,
            "occurrence": submission.occurrence,
            "accepted_at": stamp(submission.accepted_at),
        }
    if op == "pending":
        return [envelope_out(item) for item in client.pending(args["limit"])]
    if op == "acknowledge":
        return receipt_out(client.acknowledge(args["sender"], args["delivery_id"], args["occurrence"]))
    if op == "receipt":
        return receipt_out(client.receipt(args["delivery_id"]))
    if op == "prune":
        return client.prune_accepted(datetime.fromisoformat(args["before"]))
    if op == "drain_fake":
        door = FakeDoor(args.get("mode", "fresh"), args.get("occurrence", 7), args.get("fail_on"))
        try:
            receipts = FabricInbox(client, door).drain(args.get("limit", 100))
        except Exception as error:  # noqa: BLE001 - reported with the calls made
            return {"calls": door.calls, "error": error_out(error)}
        return {"calls": door.calls, "receipts": [receipt_out(item) for item in receipts]}
    if op == "send_activity":
        activity = demo_module().SendActivity(args["dsn"], args["instance"], args["credential"])
        try:
            return activity(invocation_in(args["invocation"]), context=None)
        finally:
            activity.close()
    # -- calls -------------------------------------------------------------
    if op == "call_request":
        return CallRequest(args["call_id"], args["operation"], args["input"]).to_data()
    if op == "call_request_from_data":
        return CallRequest.from_data(args["data"]).to_data()
    if op == "call_request_detached":
        input_data = {"nested": [1]}
        request = CallRequest("call-1", "answer", input_data)
        input_data["nested"].append(2)
        mutable = True
        try:
            request.input["new"] = True
        except TypeError:
            mutable = False
        return {"input": _thaw(request.input), "mutable": mutable}
    if op == "call_result":
        return CallResult(args["call_id"], args["result"]).to_data()
    if op == "call_result_from_data":
        return CallResult.from_data(args["data"]).to_data()
    if op == "call_error":
        if "details" in args:
            return CallError(args["call_id"], args["code"], args["message"], args["details"]).to_data()
        return CallError(args["call_id"], args["code"], args["message"]).to_data()
    if op == "call_error_from_data":
        return CallError.from_data(args["data"]).to_data()
    if op == "request_envelope":
        return envelope_out(
            request_envelope(
                request=CallRequest.from_data(args["request"]),
                sender=args["sender"],
                recipient=args["recipient"],
                source=args["source"],
                reply_route=route(args["reply_route"]),
                delivery_id=args.get("delivery_id"),
            )
        )
    if op in ("result_envelope", "error_envelope"):
        request = Envelope.from_data(args["request"])
        if op == "result_envelope":
            value = CallResult.from_data(args["result"])
            built = result_envelope(result=value, request=request, sender=args["sender"], delivery_id=args.get("delivery_id"))
        else:
            value = CallError.from_data(args["error"])
            built = error_envelope(error=value, request=request, sender=args["sender"], delivery_id=args.get("delivery_id"))
        return envelope_out(built)
    if op == "request_from_envelope":
        return request_from_envelope(Envelope.from_data(args["envelope"])).to_data()
    if op == "reply_from_envelope":
        return reply_out(reply_from_envelope(Envelope.from_data(args["envelope"]), request=Envelope.from_data(args["request"])))
    # -- spawn values ------------------------------------------------------
    if op == "child_credential":
        provisioner = lifecycle_module().DemoProvisioner(None, None, None, bytes.fromhex(args["workspace_key"]))
        return provisioner.child_credential(args["child"])
    if op == "child_identity":
        return child_identity(args["parent"], args["spawn_id"])
    if op == "spawn_idempotency":
        return spawn_idempotency(args["parent"], args["spawn_id"])
    if op == "spawn_spec":
        return spec_out(spec_in(args))
    if op == "spawn_spec_from_data":
        return spec_out(SpawnSpec.from_data(args["data"]))
    if op == "spawn_spec_detached":
        config = {"nested": [1]}
        item = spec_in({**args["spec"], "config": config})
        config["nested"].append(2)
        mutable = True
        try:
            item.config["other"] = True
        except TypeError:
            mutable = False
        return {"config": item.to_data()["config"], "mutable": mutable}
    if op == "spawn_outcome":
        return SpawnOutcome(
            args["parent"], args["spawn_id"], args["child"], Endpoint.from_data(args["endpoint"]), args["prior_claim"]
        ).to_data()
    if op == "spawn_outcome_from_data":
        return SpawnOutcome.from_data(args["data"]).to_data()
    if op == "provisioning":
        value = Provisioning(
            args["parent"],
            args["spawn_id"],
            args["child"],
            args["process_kind"],
            Endpoint.from_data(args["endpoint"]),
            args["config"],
            route(args.get("reply_route")),
        )
        return {"config": _thaw(value.config), "child": value.child}
    if op == "spawn_claim":
        return claim_out(SpawnClaim(args["parent"], args["spawn_id"], args["child"], args["prior_claim"]))
    if op == "lineage":
        return lineage_out(Lineage(args["parent"], args["spawn_id"], args["child"]))
    if op == "fake_spawn":
        events: list = []
        seen: list = []
        activity = SpawnActivity(
            FakeRegistry(args["registry"], events), FakeProvisioner(args["provisioner"], events, seen)
        )
        attempts = []
        for _ in range(args.get("times", 1)):
            try:
                attempts.append({"ok": activity(invocation_in(args["invocation"]), context=None)})
            except Exception as error:  # noqa: BLE001 - classified below
                attempts.append({"error": error_out(error)})
        return {"attempts": attempts, "events": events, "provisionings": seen}
    # -- lineage registry --------------------------------------------------
    if op == "ensure_lifecycle_schema":
        ensure_lifecycle_schema(HANDLES[args["conn"]])
        return None
    if op == "registry":
        return handle(PostgresSpawnRegistry(HANDLES[args["conn"]], args["parent"], args["credential"]))
    registry = HANDLES.get(args.get("registry")) if "registry" in args else None
    if op == "claim":
        return claim_out(registry.claim(SpawnSpec.from_data(args["spec"])))
    if op == "child_of":
        return lineage_out(registry.child_of(args["parent"], args["spawn_id"]))
    if op == "children_of":
        return [lineage_out(item) for item in registry.children_of(args["parent"])]
    if op == "parent_of":
        return lineage_out(registry.parent_of(args["child"]))
    if op == "spawn":
        provisioner = FakeProvisioner(args.get("provisioner", "record"), [], [], args.get("options"))
        activity = SpawnActivity(registry, provisioner)
        attempts = []
        for _ in range(args.get("times", 1)):
            try:
                attempts.append({"ok": activity(invocation_in(args["invocation"]), context=None)})
            except Exception as error:  # noqa: BLE001 - classified below
                attempts.append({"error": error_out(error)})
        return {"attempts": attempts, "provisionings": provisioner.seen}
    return UNSUPPORTED


def error_out(error: BaseException) -> dict:
    return {"category": classify(error), "type": type(error).__name__, "message": str(error)}


def main() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        request = json.loads(line)
        op = request.pop("op")
        try:
            value = run(op, request)
            answer = {"unsupported": op} if value is UNSUPPORTED else {"ok": value}
        except Exception as error:  # noqa: BLE001 - classified by category
            answer = {"error": error_out(error)}
        sys.stdout.write(json.dumps(answer, ensure_ascii=False, allow_nan=True) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
