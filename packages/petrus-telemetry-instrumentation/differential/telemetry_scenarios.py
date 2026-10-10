"""Generate the telemetry instrumentation differential: every ``impetus_*``
event the reference's kernel doors, Engine coordinator, and JSONL store emit
over a fixed set of scenarios.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-telemetry-instrumentation/differential/telemetry_scenarios.py

The script writes ``telemetry_scenarios.json`` next to itself (or to the path
given as its one argument). Each scenario
runs under ``telemetry.capture()`` (a recorder: payloads without ``ts``) and
records:

- ``events``: the payloads, in order, with their field order, after
  normalising the wall-clock-dependent fields — every ``*_ms`` field (which
  must be an ``int >= 0``) becomes ``0``, ``max_rss_mb`` (a ``float > 0``)
  becomes ``0.0``, and ``current_rss_mb`` (a ``float`` or ``None``) becomes
  ``None``. The generator asserts those types before normalising; the
  Haskell side asserts the same types on its own values.
- ``lines``: each normalised payload as the routed line ``JsonLogger``
  writes, ``json.dumps({**payload, "ts": TS}, default=str)``, with ``ts``
  pinned.

``pinned`` holds fixed payloads rendered through the real ``JsonLogger`` with
``time.time`` pinned, so the Haskell ``jsonLoggerWith`` must produce the
same bytes.

``DifferentialSpec`` (``test/Petrus/Telemetry/DifferentialSpec.hs``) runs the
same scenarios through the Haskell Instance, Engine, and JSONL store and
compares names, fields, order, and values exactly.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import sys
import tempfile
from pathlib import Path

import petrus.telemetry as telemetry
from petrus.engine import Delivery, Engine
from petrus.impetus.history_store import InMemoryHistoryStore, JsonlHistoryStore
from petrus.impetus.instance import Instance
from petrus.impetus.petrinet import Arc, Delay, Marking, Net, NetPath, Place, Token, Transition
from petrus.impetus.selection import SelectionPipeline
from petrus.motus.activity import ActivityInvocation
from petrus.motus.dispatch import InlineDispatch, InMemoryDispatch

OUTPUT = Path(__file__).with_name("telemetry_scenarios.json")
TS = 1700000000123

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "petrus-engine", "test", "interop")
)

import engine_interop as orders  # noqa: E402

P = NetPath


# ── nets (twins in test/Petrus/Telemetry/Scenarios.hs) ───────


def fork_net(name: str | None = None) -> Net:
    """a -> t -> {b, c}."""
    return Net(
        places=[Place(P("a")), Place(P("b")), Place(P("c"))],
        transitions=[Transition(P("t"))],
        arcs=[Arc(P("a"), P("t")), Arc(P("t"), P("b")), Arc(P("t"), P("c"))],
        name=name,
    )


def source_net() -> Net:
    """s (source) -> b."""
    return Net(places=[Place(P("b"))], transitions=[Transition(P("s"))], arcs=[Arc(P("s"), P("b"))])


def two_source_net() -> Net:
    """s -> b, u -> b."""
    return Net(
        places=[Place(P("b"))],
        transitions=[Transition(P("s")), Transition(P("u"))],
        arcs=[Arc(P("s"), P("b")), Arc(P("u"), P("b"))],
    )


def handled_net(handler: str, timers=()) -> Net:
    """a -> t[handler] -> b."""
    return Net(
        places=[Place(P("a")), Place(P("b"))],
        transitions=[Transition(P("t"), handler=handler, timers=timers)],
        arcs=[Arc(P("a"), P("t")), Arc(P("t"), P("b"))],
    )


def timer_net() -> Net:
    """a -> t (Delay 10) -> b."""
    return Net(
        places=[Place(P("a")), Place(P("b"))],
        transitions=[Transition(P("t"), timers=(Delay(10),))],
        arcs=[Arc(P("a"), P("t")), Arc(P("t"), P("b"))],
    )


def chain_net(length: int) -> Net:
    """p0 -> t0 -> p1 -> ... -> p{length}."""
    arcs = []
    for i in range(length):
        arcs.append(Arc(P(f"p{i}"), P(f"t{i}")))
        arcs.append(Arc(P(f"t{i}"), P(f"p{i + 1}")))
    return Net(
        places=[Place(P(f"p{i}")) for i in range(length + 1)],
        transitions=[Transition(P(f"t{i}")) for i in range(length)],
        arcs=arcs,
    )


def scoped_activity_net() -> Net:
    """s (source) -> q -> work[charge] -> done."""
    return Net(
        places=[Place(P("q")), Place(P("done"))],
        transitions=[Transition(P("s")), Transition(P("work"), handler="charge")],
        arcs=[Arc(P("s"), P("q")), Arc(P("q"), P("work")), Arc(P("work"), P("done"))],
    )


# ── implementations ──────────────────────────────────────────


def boom(binding, outputs):
    raise RuntimeError("handler broke")


def double(binding, outputs):
    return {P("b"): (binding.tokens[0], binding.tokens[0])}


class Charge:
    """An Activity: prepare an invocation from the token, project the result to b/done."""

    def __init__(self, target: str = "b"):
        self.target = target

    def prepare(self, binding):
        return ActivityInvocation("charge_card", input={"token": binding.tokens[0].data})

    def project(self, binding, result):
        return {P(self.target): (Token("Receipt", result),)}


def x() -> Token:
    return Token("X")


# ── scenarios ────────────────────────────────────────────────

SCENARIOS = []


def scenario(level: str = "facts"):
    def register(body):
        SCENARIOS.append((body.__name__, level, body))
        return body

    return register


@scenario()
def instance_created():
    Instance(fork_net(), Marking({P("a"): (x(),)}), at=5, instance_id="i-1")
    Instance(fork_net("order-fulfillment"), at=2.5, instance_id="i-2")
    Instance(source_net(), Marking({P("b"): (x(), Token("Y", {"n": 1}))}), instance_id="i-3")


@scenario()
def step_and_run():
    instance = Instance(fork_net(), Marking({P("a"): (x(), x())}), instance_id="i-1")
    instance.step(at=7)
    instance.step(at=7.5)
    assert instance.step() is None
    chain = Instance(chain_net(3), Marking({P("p0"): (x(), x())}), instance_id="chain-1")
    chain.run()


@scenario()
def failing_handler():
    instance = Instance(handled_net("boom"), Marking({P("a"): (Token.black(),)}), handlers={"boom": boom}, instance_id="i-1")
    try:
        instance.step(at=3)
    except RuntimeError:
        pass
    else:
        raise AssertionError("the handler should raise")


@scenario()
def delivery_lifecycle():
    instance = Instance(two_source_net(), instance_id="i-1")
    accepted = instance.accept_delivery("s", x(), identity="evt-1", at=1)
    instance.complete_delivery(accepted, at=2)
    instance.accept_delivery("s", x(), identity="evt-1")
    try:
        instance.accept_delivery("s", Token("Y"), identity="evt-1")
    except ValueError:
        pass
    else:
        raise AssertionError("conflicting reuse should refuse")
    two = instance.accept_delivery("u", (x(), Token("Z", {"k": "é"})), identity="evt-2", at=4)
    instance.accept_delivery("u", (x(), Token("Z", {"k": "é"})), identity="evt-2")
    instance.complete_delivery(two)
    instance.accept_delivery("u", x(), identity="evt-3", scope="job")
    instance.accept_delivery("u", x(), identity="evt-3", scope="job")
    try:
        instance.accept_delivery("s", x(), identity="evt-3", scope="job")
    except ValueError:
        pass
    else:
        raise AssertionError("conflicting reuse should refuse")


@scenario()
def seal_and_wake():
    instance = Instance(two_source_net(), instance_id="i-1")
    instance.seal("s", at=3)
    instance.seal("u")
    timed = Instance(timer_net(), Marking({P("a"): (Token.black(), Token.black())}), instance_id="i-2")
    assert timed.wake(5) is None
    timed.wake(10)
    timed.step()
    timed.wake(20.5)


@scenario()
def resume():
    instance = Instance(fork_net(), Marking({P("a"): (x(),)}), at=4, instance_id="i-1")
    instance.run()
    Instance.resume(fork_net(), instance.history)
    flying = Instance(handled_net("charge"), Marking({P("a"): (x(), x())}), handlers={"charge": Charge()}, instance_id="i-2")
    flying.begin(flying.candidates()[0], at=6)
    resumed = Instance.resume(handled_net("charge"), flying.history, handlers={"charge": Charge()})
    resumed.begin(resumed.candidates()[0], at=8)


@scenario()
def activity_seam():
    instance = Instance(handled_net("charge"), Marking({P("a"): (x(), x(), x())}), handlers={"charge": Charge()}, instance_id="i-1")
    first = instance.begin(instance.candidates()[0], at=1)
    instance.record_activity_completion(first, {"ok": True}, at=2)
    instance.record_activity_completion(first, {"ok": True}, at=3)
    instance.complete(first, at=4)
    instance.record_activity_completion(first, {"ok": True})
    second = instance.begin(instance.candidates()[0])
    instance.fail(second, "card declined", at=5)
    third = instance.begin(instance.candidates()[0])
    from petrus.motus.activity import ActivityFailure

    failure = ActivityFailure("gateway down", kind="Timeout")
    instance.record_activity_failure(third, failure, at=6)
    instance.record_activity_failure(third, failure)
    instance.fail(third, failure, at=7)


@scenario()
def jsonl_commits():
    directory = tempfile.mkdtemp(prefix="petrus-telemetry-differential")
    try:
        path = os.path.join(directory, "history.jsonl")
        instance = Instance(
            fork_net(),
            Marking({P("a"): (Token("X", {"note": "café ☕"}), x())}),
            history=JsonlHistoryStore(path),
            instance_id="jsonl-1",
        )
        instance.run()
        Instance.resume(fork_net(), JsonlHistoryStore(path))
        sourced = Instance(source_net(), history=JsonlHistoryStore(os.path.join(directory, "s.jsonl")), instance_id="jsonl-2")
        sourced.complete_delivery(sourced.accept_delivery("s", Token("Y", {"emoji": "😀"}), identity="e-1"))
        sourced.seal("s")
    finally:
        shutil.rmtree(directory)


def _engine(net, identity, marking=None, handlers=None, dispatch=None, history=None, **options):
    return Engine.create(
        net,
        identity,
        history=history if history is not None else InMemoryHistoryStore(),
        dispatch=dispatch if dispatch is not None else InMemoryDispatch(),
        marking=marking,
        handlers=handlers,
        **options,
    )


def _until_rest(engine):
    while engine.advance().ready:
        pass


@scenario()
def engine_advance():
    engine = _engine(fork_net(), "span", Marking({P("a"): (x(),)}))
    engine.advance()
    engine.advance()
    named = _engine(fork_net("order-fulfillment"), "order-7", Marking({P("a"): (x(), x())}), at=3)
    _until_rest(named)


@scenario()
def engine_failing_handler():
    engine = _engine(handled_net("boom"), "failed-span", Marking({P("a"): (Token.black(),)}), {"boom": boom})
    try:
        engine.advance()
    except RuntimeError:
        pass
    else:
        raise AssertionError("the handler should raise")


@scenario(level="profile")
def engine_gauges():
    engine = _engine(fork_net(), "gauges", Marking({P("a"): (x(), x())}))
    _until_rest(engine)


@scenario()
def engine_declined():
    engine = _engine(
        fork_net(), "declined", Marking({P("a"): (x(), x())}), selection=SelectionPipeline(filters=(lambda binding: False,))
    )
    engine.advance()


@scenario()
def engine_orders():
    engine = Engine.create(
        orders.order_net(),
        orders.IDENTITY,
        history=InMemoryHistoryStore(),
        dispatch=InlineDispatch({"charge_card": orders.charge_card}),
        handlers=orders.handlers(),
    )
    for n in (1, 2):
        engine.deliver(orders.INTAKE, Token("Order", {"id": f"o-{n}", "amount": n}), identity=f"evt_{n}")
    engine.deliver(orders.INTAKE, Token("Order", {"id": "o-1", "amount": 1}), identity="evt_1")
    engine.seal(orders.INTAKE)
    _until_rest(engine)


@scenario()
def engine_sensor():
    batches = [[Delivery(P("s"), (x(),), identity="sensed-1"), Delivery(P("s"), (Token("Y"),), identity="sensed-2")]]

    def sensor():
        return batches.pop(0) if batches else []

    engine = _engine(source_net(), "sensed", sensor=sensor)
    _until_rest(engine)


@scenario()
def engine_activities():
    pool = InMemoryDispatch()
    engine = _engine(handled_net("charge"), "acts", Marking({P("a"): (x(), x())}), {"charge": Charge()}, dispatch=pool)
    _until_rest(engine)
    (first,) = pool.pending
    pool.complete(first, {"status": "captured"})
    _until_rest(engine)
    (second,) = pool.pending
    pool.fail(second, "card declined")
    try:
        _until_rest(engine)
    except RuntimeError:
        pass
    else:
        raise AssertionError("a terminal activity failure should halt")


@scenario()
def engine_reconcile():
    directory = tempfile.mkdtemp(prefix="petrus-telemetry-differential")
    try:
        path = os.path.join(directory, "history.jsonl")
        crashed = _engine(
            handled_net("charge"),
            "reconcile",
            Marking({P("a"): (x(),)}),
            {"charge": Charge()},
            history=JsonlHistoryStore(path),
        )
        _until_rest(crashed)
        loaded = Engine.load(
            handled_net("charge"),
            "reconcile",
            history=JsonlHistoryStore(path),
            dispatch=InlineDispatch({"charge_card": lambda invocation, *, context: {"status": "captured"}}),
            handlers={"charge": Charge()},
        )
        _until_rest(loaded)
    finally:
        shutil.rmtree(directory)


@scenario()
def engine_cancellation():
    pool = InMemoryDispatch()
    engine = _engine(scoped_activity_net(), "scoped", handlers={"charge": Charge("done")}, dispatch=pool)
    scope = engine.open_scope("job")
    engine.deliver("s", x(), identity="job-1", scope=scope)
    _until_rest(engine)
    assert len(pool.pending) == 1
    engine.close_scope(scope)
    _until_rest(engine)
    (fenced,) = pool._cancelled
    pool.complete(fenced, {"status": "late"})
    _until_rest(engine)
    second = engine.open_scope("job")
    engine.deliver("s", x(), identity="job-2", scope=second)
    _until_rest(engine)
    engine.reset_scope(second)
    _until_rest(engine)


@scenario()
def engine_reconcile_pure():
    history = InMemoryHistoryStore()
    instance = Instance(
        handled_net("double"), Marking({P("a"): (x(), x())}), handlers={"double": double}, history=history, instance_id="pure"
    )
    instance.begin(instance.candidates()[0], at=2)
    loaded = Engine.load(handled_net("double"), "pure", history=history, dispatch=InMemoryDispatch(), handlers={"double": double})
    _until_rest(loaded)


class NeverDue:
    """A Clock whose timers are never due: AdvanceTime is offered but cannot apply."""

    def now(self):
        return 1

    def observe(self, instant):
        return None


@scenario()
def engine_clock_not_due():
    engine = _engine(timer_net(), "not-due", Marking({P("a"): (Token.black(),)}), clock=NeverDue())
    engine.advance()
    engine.advance()


class ChargeProjectingFailure(Charge):
    def project_failure(self, binding, failure):
        return {P("b"): (Token("Declined", {"error": failure.error}),)}


@scenario(level="profile")
def engine_failure_projection():
    pool = InMemoryDispatch()
    directory = tempfile.mkdtemp(prefix="petrus-telemetry-differential")
    try:
        engine = _engine(
            handled_net("charge"),
            "projects",
            Marking({P("a"): (x(),)}),
            {"charge": ChargeProjectingFailure()},
            dispatch=pool,
            history=JsonlHistoryStore(os.path.join(directory, "history.jsonl")),
        )
        _until_rest(engine)
        (occurrence,) = pool.pending
        pool.fail(occurrence, "card declined")
        _until_rest(engine)
    finally:
        shutil.rmtree(directory)


@scenario()
def engine_failing_source_projection():
    net = Net(places=[Place(P("b"))], transitions=[Transition(P("s"), handler="boom")], arcs=[Arc(P("s"), P("b"))])
    engine = _engine(net, "bad-source", handlers={"boom": boom})
    try:
        engine.deliver("s", x(), identity="evt-1")
    except RuntimeError:
        pass
    else:
        raise AssertionError("the source projection should raise")


@scenario(level="debug")
def engine_debug_level():
    # The ladder: debug admits everything profile does (the gauges).
    _until_rest(_engine(fork_net(), "debug", Marking({P("a"): (x(),)})))


@scenario(level="off")
def level_off():
    # Off silences every door, span, gauge, and commit.
    engine_orders()
    jsonl_commits()


# ── normalisation and output ─────────────────────────────────


def normalised(payload: dict) -> dict:
    out = {}
    for key, value in payload.items():
        if key.endswith("_ms"):
            assert type(value) is int and value >= 0, (key, value)
            value = 0
        elif key == "max_rss_mb":
            assert type(value) is float and value > 0, (key, value)
            value = 0.0
        elif key == "current_rss_mb":
            assert value is None or type(value) is float, (key, value)
            value = None
        out[key] = value
    return out


def line(payload: dict) -> str:
    return json.dumps({**payload, "ts": TS}, default=str)


def pinned_lines() -> list[dict]:
    payloads = [
        {"event": "impetus_firing_completed", "instance": "i-1", "net": "n", "transition": "t", "occurrence": 1, "instant": 7, "records": 3},
        {"event": "impetus_x", "instance": "é \U0001f600", "ratio": 0.1, "big": 10**20, "huge": 1e300, "neg": -0.0, "ok": True, "none": None},
        {"event": "impetus_x", "nan": float("nan"), "inf": float("inf"), "ninf": float("-inf"), "ts": 3, "list": [1, "a"]},
    ]
    stream = []

    class Collect(logging.Handler):
        def emit(self, record):
            stream.append(record.getMessage())

    logger = logging.getLogger("petrus-telemetry-differential")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    logger.addHandler(Collect())
    sink = telemetry.JsonLogger(logger)
    real = telemetry.time.time
    telemetry.time.time = lambda: TS / 1000
    try:
        for payload in payloads:
            sink.info(payload)
    finally:
        telemetry.time.time = real
    return [{"payload": payload, "line": text} for payload, text in zip(payloads, stream, strict=True)]


def main() -> None:
    cases = []
    for name, level, body in SCENARIOS:
        with telemetry.capture(level=level) as events:
            body()
        payloads = [normalised(dict(event)) for event in events]
        cases.append({"name": name, "level": level, "events": payloads, "lines": [line(p) for p in payloads]})
    document = {"ts": TS, "scenarios": cases, "pinned": pinned_lines()}
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    output.write_text(json.dumps(document, indent=1, ensure_ascii=False, default=str) + "\n", encoding="utf-8")
    print(f"wrote {output} ({sum(len(c['events']) for c in cases)} events in {len(cases)} scenarios)")


if __name__ == "__main__":
    main()
