"""Record and replay the reference host through its own injection points.

Nothing upstream is patched. ``HostService`` already takes the seams tier B
needs (``transport_factory``, ``runner``, ``clock``, ``application_factory``)
and ``GitHubAppClients`` takes an httpx transport; this module supplies:

- ``RecordingTransport``: the production ``GitHubKitTransport`` that appends
  every request and its answer to the tape (``transport_factory``);
- ``RecordingRunner`` and ``ReplayRunner``: an ``AgentRunner`` around the
  real one that appends every call to the tape, and one that answers from
  it, keyed by ``(kind, operation, attempt)``, failing on unknown keys;
- ``RecordingPublisher`` and ``ReplayPublisher``: the same for the Git
  publisher (``PrReadinessV5Application(mutation_publisher=...)``);
- ``StepClock``: the clock each step of the tape recorded;
- ``Redirect``: an httpx transport that sends GitHub requests to a local
  port;
- ``RecordingHost``: the step log (deliveries, processing, pumps, close).

Runs in the reference's environment (``scripts/upstream-python hamsterdan``).
"""

from __future__ import annotations

import functools
import json
import threading
from dataclasses import asdict
from pathlib import Path
from typing import Any

import httpx

from hamsterdan.agents.protocol import AgentProtocolError, AgentResultCategory, AgentCleanupCategory
from hamsterdan.agents.protocol import CodingResult, ConversationResult, ReviewResult
from hamsterdan.github_app.gateway import GitHubObjectWriteError
from hamsterdan.github_app.models import GitHubBoundaryError
from hamsterdan.github_app.transport import GitHubKitTransport
from hamsterdan.host.git_publish import GitPublishError, GitPublishResult, GitReconciliation, PublicationCategory
from hamsterdan.host.v5.application import PrReadinessV5Application

import tape as tapes

RESULT_TYPES = {"review": ReviewResult, "converse": ConversationResult, "code": CodingResult}


def plain(value: Any) -> Any:
    """A JSON value: dataclasses as ``asdict``, tuples as lists."""
    return json.loads(json.dumps(asdict(value) if hasattr(value, "__dataclass_fields__") else value))


class Context(threading.local):
    """Which part of the host is calling GitHub: the host, or its Git publisher."""

    current = "host"


class Redirect(httpx.HTTPTransport):
    """Send every request to a local port instead of api.github.com."""

    def __init__(self, port: int) -> None:
        super().__init__()
        self.port = port

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        request.url = request.url.copy_with(scheme="http", host="127.0.0.1", port=self.port)
        return super().handle_request(request)


# ---------------------------------------------------------------------------
# GitHub


class RecordingTransport(GitHubKitTransport):
    """``GitHubKitTransport`` that appends each exchange to ``github.jsonl``.

    ``pages`` goes through ``request``, so every page is recorded too.
    """

    def __init__(self, client: Any, writer: tapes.TapeWriter, context: Context) -> None:
        super().__init__(client)
        self._writer, self._context = writer, context

    def request(self, method: str, path: str, body: Any = None):
        sent = None if body is None else plain(dict(body))
        entry = {"method": method, "path": path, "body": sent, "context": self._context.current}
        try:
            response = super().request(method, path, body)
        except GitHubBoundaryError as error:
            self._writer.append(
                "github.jsonl",
                {
                    **entry,
                    "error": {
                        "class": type(error).__name__,
                        "message": str(error),
                        "failure_class": error.failure_class,
                        "provider_status": error.provider_status,
                        "provider_detail": error.provider_detail,
                    },
                },
            )
            raise
        self._writer.append(
            "github.jsonl",
            {**entry, "status": response.status, "response": plain(response.body), "next": response.next_path},
        )
        return response


def recording_transport_factory(writer: tapes.TapeWriter, context: Context):
    return lambda client: RecordingTransport(client, writer, context)


# ---------------------------------------------------------------------------
# Agents


def error_json(error: BaseException) -> dict[str, Any]:
    if isinstance(error, AgentProtocolError):
        return {
            "class": "AgentProtocolError",
            "reason": str(error),
            "canceled": error.canceled,
            "timed_out": error.timed_out,
            "result_category": None if error.result_category is None else error.result_category.value,
            "cleanup_category": None if error.cleanup_category is None else error.cleanup_category.value,
        }
    if isinstance(error, GitPublishError):
        return {"class": "GitPublishError", "category": error.category.value, "reason": str(error)}
    if isinstance(error, GitHubBoundaryError):
        return {
            "class": type(error).__name__,
            "message": str(error),
            "failure_class": error.failure_class,
            "provider_status": error.provider_status,
            "provider_detail": error.provider_detail,
        }
    return {"class": type(error).__name__, "reason": str(error)}


def raise_recorded(error: dict[str, Any]):
    kind = error["class"]
    if kind == "AgentProtocolError":
        raise AgentProtocolError(
            error["reason"],
            canceled=error["canceled"],
            timed_out=error["timed_out"],
            result_category=None if error["result_category"] is None else AgentResultCategory(error["result_category"]),
            cleanup_category=None
            if error["cleanup_category"] is None
            else AgentCleanupCategory(error["cleanup_category"]),
        )
    if kind == "GitPublishError":
        raise GitPublishError(PublicationCategory(error["category"]), error["reason"])
    if kind in ("GitHubBoundaryError", "GitHubObjectWriteError"):
        raise (GitHubObjectWriteError if kind == "GitHubObjectWriteError" else GitHubBoundaryError)(
            error["message"],
            failure_class=error["failure_class"],
            provider_status=error["provider_status"],
            provider_detail=error["provider_detail"],
        )
    raise RuntimeError(f"recorded {kind}: {error.get('reason', '')}")


class RecordingRunner:
    """An ``AgentRunner`` that appends every call of ``inner`` to ``agents.jsonl``."""

    def __init__(self, inner: Any, writer: tapes.TapeWriter) -> None:
        self.inner, self.writer = inner, writer

    def _call(self, kind: str, repository_url, request, *, operation, attempt, is_current=None):
        observed: list[bool] = []

        def current() -> bool:
            value = bool(is_current())
            observed.append(value)
            return value

        entry = {
            "kind": kind,
            "operation": operation,
            "attempt": attempt,
            "repository_url": repository_url,
            "request": plain(request),
        }
        try:
            result = getattr(self.inner, kind)(
                repository_url,
                request,
                operation=operation,
                attempt=attempt,
                is_current=None if is_current is None else current,
            )
        except Exception as error:
            self.writer.append("agents.jsonl", {**entry, "is_current": observed, "error": error_json(error)})
            raise
        self.writer.append("agents.jsonl", {**entry, "is_current": observed, "result": plain(result)})
        return result

    review = functools.partialmethod(_call, "review")
    converse = functools.partialmethod(_call, "converse")
    code = functools.partialmethod(_call, "code")


class ReplayRunner:
    """An ``AgentRunner`` that answers from ``agents.jsonl``.

    A call whose ``(kind, operation, attempt)`` the tape does not hold fails
    (``unknown``). A known call whose request differs from the recorded one
    is answered anyway and reported (``mismatches``). ``is_current`` is
    called as often as the recording called it, and its answers compared.
    """

    def __init__(self, tape: Path) -> None:
        self.calls: dict[tuple[str, str, int], list[dict[str, Any]]] = {}
        for record in tapes.read(tape, "agents.jsonl"):
            self.calls.setdefault((record["kind"], record["operation"], record["attempt"]), []).append(record)
        self.log: list[dict[str, Any]] = []
        self.unknown: list[dict[str, Any]] = []
        self.mismatches: list[dict[str, Any]] = []

    def _call(self, kind: str, repository_url, request, *, operation, attempt, is_current=None):
        key = (kind, operation, attempt)
        recorded = self.calls.get(key)
        if not recorded:
            self.unknown.append({"kind": kind, "operation": operation, "attempt": attempt})
            raise AgentProtocolError(f"replay: no recorded {kind} call for {operation} attempt {attempt}")
        record = recorded.pop(0)
        self.log.append({"kind": kind, "operation": operation, "attempt": attempt, "seq": record["seq"]})
        sent = plain(request)
        if tapes.canonical(sent) != tapes.canonical(record["request"]) or repository_url != record["repository_url"]:
            self.mismatches.append(
                {"kind": kind, "operation": operation, "attempt": attempt, "recorded": record["request"], "sent": sent}
            )
        for expected in record["is_current"]:
            observed = True if is_current is None else bool(is_current())
            if observed != expected:
                self.mismatches.append(
                    {"kind": kind, "operation": operation, "attempt": attempt, "is_current": [expected, observed]}
                )
        if "error" in record:
            raise_recorded(record["error"])
        return RESULT_TYPES[kind](**record["result"])

    review = functools.partialmethod(_call, "review")
    converse = functools.partialmethod(_call, "converse")
    code = functools.partialmethod(_call, "code")

    def report(self) -> dict[str, Any]:
        left = [{"kind": k, "operation": o, "attempt": a} for (k, o, a), items in self.calls.items() for _ in items]
        return {"calls": self.log, "unknown": self.unknown, "mismatches": self.mismatches, "unused": left}


class CarriedRunner:
    """An ``AgentRunner`` answering from another run's ``agents.jsonl`` (tier C).

    Tier C's deterministic pass (docs/hamsterdan.md §5.2, tier C step 2)
    replays the agent results one real run recorded into both hosts, each on
    its own repository, so the recorded operations, SHAs and ids are not the
    ones asked for. A call is keyed by ``(kind, tape.operation_shape(
    operation), attempt)`` and takes the recorded results of that key in
    order; the result is ``tape.carry_result`` of the recorded one. A call
    with no recorded result left fails (``AgentProtocolError``) and is
    reported in ``unknown``. ``is_current`` is not consulted. The Haskell
    twin is ``Hamsterdan.E2E.Agents.carriedRunner``.
    """

    def __init__(self, tape: Path) -> None:
        self.calls: dict[tuple[str, str, int], list[dict[str, Any]]] = {}
        for record in tapes.read(tape, "agents.jsonl"):
            key = (record["kind"], tapes.operation_shape(record["operation"]), record["attempt"])
            self.calls.setdefault(key, []).append(record)
        self.lock = threading.Lock()
        self.log: list[dict[str, Any]] = []
        self.unknown: list[dict[str, Any]] = []

    def answer(self, kind: str, operation: str, attempt: int, request: dict[str, Any]) -> dict[str, Any]:
        """The carried record for one call: ``{"result": ...}`` or ``{"error": ...}``."""
        key = (kind, tapes.operation_shape(operation), attempt)
        with self.lock:
            recorded = self.calls.get(key)
            if not recorded:
                self.unknown.append({"kind": kind, "operation": operation, "attempt": attempt})
                return {"error": {"class": "AgentProtocolError", "reason": f"carried: no recorded {kind} call for {key[1]} attempt {attempt}", "canceled": False, "timed_out": False, "result_category": None, "cleanup_category": None}}
            record = recorded.pop(0)
            self.log.append({"kind": kind, "operation": operation, "attempt": attempt, "seq": record["seq"]})
        if "error" in record:
            return {"error": record["error"]}
        return {"result": tapes.carry_result(record["request"], request, record["result"])}

    def _call(self, kind: str, repository_url, request, *, operation, attempt, is_current=None):
        del repository_url, is_current
        answered = self.answer(kind, operation, attempt, plain(request))
        if "error" in answered:
            raise_recorded(answered["error"])
        return RESULT_TYPES[kind](**answered["result"])

    review = functools.partialmethod(_call, "review")
    converse = functools.partialmethod(_call, "converse")
    code = functools.partialmethod(_call, "code")


# ---------------------------------------------------------------------------
# The Git publisher


def coding_result(value: dict[str, Any]) -> CodingResult:
    return CodingResult(**value)


class RecordingPublisher:
    """A ``MutationPublisher`` that appends each call of ``inner`` to ``publisher.jsonl``.

    The GitHub requests the publisher makes are tagged ``publisher``.
    """

    def __init__(self, inner: Any, writer: tapes.TapeWriter, context: Context) -> None:
        self.inner, self.writer, self.context = inner, writer, context

    def _record(self, method: str, arguments: dict[str, Any], call):
        previous = self.context.current
        self.context.current = "publisher"
        try:
            outcome = call()
        except Exception as error:
            self.writer.append("publisher.jsonl", {"method": method, "arguments": arguments, "error": error_json(error)})
            raise
        finally:
            self.context.current = previous
        self.writer.append("publisher.jsonl", {"method": method, "arguments": arguments, "outcome": plain(outcome)})
        return outcome

    def reconcile(self, **kwargs):
        return self._record("reconcile", plain(kwargs), lambda: self.inner.reconcile(**kwargs))

    def publish(self, result, **kwargs):
        arguments = {**plain(kwargs), "result": plain(result)}
        return self._record("publish", arguments, lambda: self.inner.publish(result, **kwargs))


class ReplayPublisher:
    """A ``MutationPublisher`` that answers from ``publisher.jsonl``, in order."""

    def __init__(self, tape: Path) -> None:
        self.records = tapes.read(tape, "publisher.jsonl")
        self.log: list[dict[str, Any]] = []
        self.mismatches: list[dict[str, Any]] = []

    def _answer(self, method: str, arguments: dict[str, Any], decode):
        if not self.records:
            self.mismatches.append({"method": method, "arguments": arguments, "recorded": None})
            raise GitPublishError(PublicationCategory.BOUNDARY_UNAVAILABLE, "replay: no recorded publisher call")
        record = self.records.pop(0)
        self.log.append({"method": method, "seq": record["seq"]})
        if record["method"] != method or tapes.canonical(record["arguments"]) != tapes.canonical(arguments):
            self.mismatches.append({"method": method, "arguments": arguments, "recorded": record})
        if "error" in record:
            raise_recorded(record["error"])
        return decode(record["outcome"])

    def reconcile(self, **kwargs):
        def decode(value):
            return GitReconciliation(value["disposition"], value["observed_head"], value["commit"], tuple(value["parents"]))

        return self._answer("reconcile", plain(kwargs), decode)

    def publish(self, result, **kwargs):
        return self._answer(
            "publish",
            {**plain(kwargs), "result": plain(result)},
            lambda value: GitPublishResult(value["head"], value["recovered"]),
        )

    def report(self) -> dict[str, Any]:
        return {"calls": self.log, "mismatches": self.mismatches, "unused": [r["seq"] for r in self.records]}


def application_factory(publisher_for):
    """``PrReadinessV5Application`` with ``mutation_publisher=publisher_for(authority, clone_url)``."""

    def factory(root, instance_id, authority, runner, **kwargs):
        publisher = publisher_for(authority, kwargs["public_clone_url"])
        return PrReadinessV5Application(root, instance_id, authority, runner, mutation_publisher=publisher, **kwargs)

    return factory


# ---------------------------------------------------------------------------
# Clock and steps


class StepClock:
    """The clock of the current step: constant within a step."""

    def __init__(self, value: float) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value


class RecordingHost:
    """Log the steps that drive ``host`` (the outermost calls only) to ``steps.jsonl``."""

    def __init__(self, host: Any, writer: tapes.TapeWriter, clock) -> None:
        self.host, self.writer, self.clock = host, writer, clock
        self.depth = 0
        for name in ("pump", "process", "close"):
            setattr(host, name, self._wrap(name, getattr(host, name)))
        receive = host.custody.receive
        reconcile = host.registry.reconcile

        def recorded_receive(headers, body):
            headers = list(headers)
            projected = {str(k).lower(): str(v) for k, v in headers}
            receipt = receive(headers, body)
            if self.depth == 0:
                self._append(
                    {
                        "op": "deliver",
                        "delivery": projected.get("x-github-delivery"),
                        "event": projected.get("x-github-event"),
                        "headers": tapes.unsigned(headers),
                        "body": body.decode("utf-8"),
                        "disposition": receipt.disposition,
                    }
                )
            return receipt

        def recorded_reconcile(inventories):
            inventories = tuple(inventories)
            result = reconcile(inventories)
            if self.depth == 0:
                self._append(
                    {
                        "op": "registry",
                        "inventories": [
                            [item.installation_id, item.account_id, [list(repo) for repo in item.repositories]]
                            for item in inventories
                        ],
                    }
                )
            return result

        host.custody.receive = recorded_receive
        host.registry.reconcile = recorded_reconcile

    def _append(self, step: dict[str, Any]) -> None:
        self.writer.append("steps.jsonl", {**step, "clock": self.clock()})

    def _wrap(self, name: str, inner):
        def wrapped(*args, **kwargs):
            outer = self.depth == 0
            clock = self.clock()
            self.depth += 1
            step: dict[str, Any] = {"op": name}
            if name == "pump":
                step["limit"] = args[0] if args else kwargs.get("limit", 20)
            if name == "process":
                step["delivery"] = args[0].delivery_id
            try:
                result = inner(*args, **kwargs)
            except Exception as error:
                if outer:
                    # The replays must raise here too, with the same message.
                    self.writer.append("steps.jsonl", {**step, "raises": str(error), "clock": clock})
                raise
            finally:
                self.depth -= 1
            if outer:
                if name == "pump":
                    step["processed"] = result
                self.writer.append("steps.jsonl", {**step, "clock": clock})
            return result

        return wrapped


class LiveRecorder:
    """The step log of a live host (tier B step 1 over a tier C host).

    A live host receives webhooks on its HTTP threads and pumps on its own
    worker, on the wall clock, so the replays cannot repeat its pumps one by
    one. This records what drove it instead:

    - ``registry`` for each ``registry.reconcile`` (startup registration);
    - ``deliver`` for each delivery the custody received (the webhook tee),
      with the recorded headers (no signature) and body;
    - ``sweep`` for each sweep that reconciled an Instance or exchanged with
      the world;
    - ``converge`` for each pump that processed work or exchanged with the
      world, at the clock it started (replays pump until quiescent there);
    - ``close``.
    """

    def __init__(self, host: Any, writer: tapes.TapeWriter, clock) -> None:
        self.host, self.writer, self.clock = host, writer, clock
        receive = host.custody.receive
        reconcile = host.registry.reconcile
        pump, sweep, close = host.pump, host.sweep, host.close

        def activity() -> tuple[int, ...]:
            github, _steps, agents, publisher = writer.counts()
            return (github, agents, publisher)

        def recorded_receive(headers, body):
            started = clock()
            headers = list(headers)
            projected = {str(k).lower(): str(v) for k, v in headers}
            receipt = receive(headers, body)
            self._append(
                {
                    "op": "deliver",
                    "delivery": projected.get("x-github-delivery"),
                    "event": projected.get("x-github-event"),
                    "headers": tapes.unsigned(headers),
                    "body": body.decode("utf-8"),
                    "disposition": receipt.disposition,
                },
                started,
            )
            return receipt

        def recorded_reconcile(inventories):
            started = clock()
            inventories = tuple(inventories)
            result = reconcile(inventories)
            self._append(
                {
                    "op": "registry",
                    "inventories": [
                        [item.installation_id, item.account_id, [list(repo) for repo in item.repositories]]
                        for item in inventories
                    ],
                },
                started,
            )
            return result

        def recorded_pump(limit: int = 20) -> int:
            started, before = clock(), activity()
            processed = pump(limit)
            if processed or activity() != before:
                self._append({"op": "converge"}, started)
            return processed

        def recorded_sweep(trigger: str = "periodic") -> int:
            started, before = clock(), activity()
            reconciled = sweep(trigger)
            if reconciled or activity() != before:
                self._append({"op": "sweep", "trigger": trigger, "reconciled": reconciled}, started)
            return reconciled

        def recorded_close() -> None:
            started = clock()
            try:
                close()
            finally:
                self._append({"op": "close"}, started)

        host.custody.receive = recorded_receive
        host.registry.reconcile = recorded_reconcile
        host.pump, host.sweep, host.close = recorded_pump, recorded_sweep, recorded_close

    def _append(self, step: dict[str, Any], clock: float) -> None:
        self.writer.append("steps.jsonl", {**step, "clock": clock})
