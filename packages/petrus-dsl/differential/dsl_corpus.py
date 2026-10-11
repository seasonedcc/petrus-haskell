"""Generate the DSL differential corpus from the reference DSL.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-dsl/differential/dsl_corpus.py

The script writes ``dsl_corpus.json`` next to itself (or into the directory given as its first argument). Every case authors one
net with the reference DSL (``petrus.impetus.dsl``): each net the upstream
DSL tests author (``tests/petrus/impetus/dsl/test_petrinet_dsl.py``), the
nets other upstream modules author with the DSL (the Agent-as-Net, the
bounded-simulation scenario, the observation inspection design), and a few
larger generated nets. For each case it records the reference's verdict:

- ``definition``: ``serialize_net_definition(project_net_definition(net))``,
  the canonical Net-definition v3 bytes;
- ``places`` / ``transitions``: the canonical net's authored (first-touch)
  order, which the v3 projection sorts away;
- ``arcs``: ``[source, target]`` per arc in authored order;
- ``handlers`` / ``guards``: the sorted canonical URIs of the
  implementation maps;
- ``display``: each anonymous declaration's non-semantic display name;
- or ``error``: the exact refusal text.

``DslCorpusSpec`` authors the same nets with the Haskell DSL
(``test/Petrus/Impetus/Dsl/Corpus.hs``) and asserts it agrees on every case,
byte for byte.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import sys
from pathlib import Path

from petrus.agenticus.program.agent_net import AGENT_AS_NET, agent_net_guards, agent_net_handlers
from petrus.impetus.dsl import NetBuilder, NetSpec, arc, direct, petri_guard, petri_handler, typed_guard
from petrus.impetus.net_definition import project_net_definition, serialize_net_definition
from petrus.impetus.petrinet import AnonymousDeclaration, Cel, Delay, Until

OUTPUT_NAME = "dsl_corpus.json"


@dataclass(frozen=True)
class Order:
    amount: int


@dataclass(frozen=True)
class Config:
    limit: int


@dataclass(frozen=True)
class Receipt:
    total: int


def verdict(net, handlers=(), guards=()) -> dict[str, object]:
    display = {}
    for path, transition in net.transitions.items():
        names = []
        if isinstance(transition.handler, AnonymousDeclaration):
            names.append(["handler", transition.handler.display_name])
        for index, guard in enumerate(transition.guards):
            if isinstance(guard, AnonymousDeclaration):
                names.append([f"guard:{index}", guard.display_name])
        if names:
            display[str(path)] = names
    return {
        "definition": serialize_net_definition(project_net_definition(net)).decode(),
        "places": [str(path) for path in net.places],
        "transitions": [str(path) for path in net.transitions],
        "arcs": [[str(item.source), str(item.target)] for item in net.arcs],
        "handlers": sorted(str(uri) for uri in handlers),
        "guards": sorted(str(uri) for uri in guards),
        "display": display,
    }


def built(spec) -> dict[str, object]:
    result = spec.build()
    return verdict(result.net, result.handlers, result.guards)


def handler(binding, outputs):
    return {}


def guard(binding):
    return True


@direct
def process(order: Order) -> Receipt:
    return Receipt(order.amount + 1)


def positive(order: Order) -> bool:
    return order.amount > 0


def within_limit(order: Order, config: Config) -> bool:
    return order.amount <= config.limit


CASES: dict[str, object] = {}


def case(name):
    def register(function):
        try:
            CASES[name] = function()
        except Exception as error:  # noqa: BLE001 - every refusal is recorded
            CASES[name] = {"error": str(error)}
        return function

    return register


@case("orders")
def _():
    net = NetSpec("orders")
    pending = net.place(net.p.pending, color=Order)
    receipt = net.place(net.p.receipt, color=Receipt)
    process_ = net.transition(net.t.process, handler="process")
    pending >> process_ >> receipt
    pending >> arc.read(weight=2, color=Order, filter="current") >> process_
    return built(net)


@case("multiplicity")
def _():
    net = NetSpec("multiplicity")
    inscription = arc(color=Order)
    (net.p.left, net.p.right) >> inscription >> (net.t.first, net.t.second)
    net.p.left >> inscription >> net.t.first
    return built(net)


def snapshots(late: bool):
    net = NetSpec("snapshots")
    net.p.pending >> net.t.first
    if late:
        net.t.first >> net.p.done
    return built(net)


case("snapshots.first")(lambda: snapshots(False))
case("snapshots.second")(lambda: snapshots(True))


@case("configuration")
def _():
    net = NetSpec("configuration")
    transition = net.t.process(handler="first", guards=("ready",), timers=(Delay(3),))
    net.p.pending(Order) >> transition
    transition(handler="first", guards=("ready",), timers=(Delay(3),))
    try:
        transition(handler="second")
    except ValueError:
        pass
    transition.override(handler="second")
    return built(net)


@case("configuration.conflict")
def _():
    net = NetSpec("configuration")
    transition = net.t.process(handler="first", guards=("ready",), timers=(Delay(3),))
    net.p.pending(Order) >> transition
    transition(handler="second")


@case("places.conflict")
def _():
    net = NetSpec("places")
    place = net.p.pending(Order)
    place(Receipt)


def place_overrides(stage: int):
    net = NetSpec("place-overrides")
    place = net.p.pending(Order)
    if stage >= 1:
        place.override(color=Receipt)
    if stage >= 2:
        place.override(color=None)
    return built(net)


case("place-overrides.before")(lambda: place_overrides(0))
case("place-overrides.changed")(lambda: place_overrides(1))
case("place-overrides.cleared")(lambda: place_overrides(2))


@case("place-overrides.undeclared")
def _():
    net = NetSpec("place-overrides")
    net.p.undeclared.override(color=Order)


def transition_overrides(stage: int):
    net = NetSpec("transition-overrides")
    transition = net.t.process(handler="process", guards=("ready",), timers=(Delay(3),))
    net.p.pending(Order) >> transition
    transition.override(handler=None)
    if stage >= 2:
        transition.override(guards=(), timers=())
    return built(net)


case("transition-overrides.handler")(lambda: transition_overrides(1))
case("transition-overrides.cleared")(lambda: transition_overrides(2))


@case("invalid-overrides.undeclared")
def _():
    net = NetSpec("invalid-overrides")
    net.t.undeclared.override(handler="process")


@case("invalid-overrides.empty")
def _():
    net = NetSpec("invalid-overrides")
    transition = net.t.process(handler="process")
    transition.override()


@case("atomic-overrides")
def _():
    net = NetSpec("atomic-overrides")
    transition = net.t.process(handler="process", guards=("ready",))
    net.p.pending(Order) >> transition
    try:
        transition.override(handler="changed", guards=net.t.other)
    except TypeError:
        pass
    return built(net)


@case("callable-specs")
def _():
    net = NetSpec("callable-specs")
    transition = net.t.publish
    published = net.p.published(Receipt)
    audited = net.p.audited(Receipt)
    transition(handler="publish")
    transition >> published
    transition >> audited
    return built(net)


def late_configuration(late: bool):
    net = NetSpec("late-configuration")
    transition = net.t.publish
    transition >> net.p.published(Receipt)
    if late:
        transition(handler="publish")
        transition >> net.p.audit(Receipt)
    return built(net)


case("late-configuration.before")(lambda: late_configuration(False))
case("late-configuration.after")(lambda: late_configuration(True))


@case("invalid.weight")
def _():
    net = NetSpec("invalid")
    net.p.left >> arc(weight=0) >> net.t.right
    return built(net)


@case("invalid.color")
def _():
    net = NetSpec("invalid")
    net.p.left(Order) >> arc(color=Receipt) >> net.t.right
    return built(net)


@case("typed")
def _():
    net = NetSpec("typed")
    pending = net.place(net.p.pending, color=Order)
    receipt = net.place(net.p.receipt, color=Receipt)
    transition = net.transition(net.t.process, handler=process, guards=positive)
    pending >> transition >> receipt
    return built(net)


@case("custom-guard")
def _():
    class RecordingConverter:
        def decode(self, value, annotation):
            return annotation(**{key: int(item) for key, item in value.items()})

        def encode(self, value, annotation):
            raise AssertionError("guards do not encode payloads")

    net = NetSpec("custom-guard")
    pending = net.place(net.p.pending, color=Order)
    configuration = net.place(net.p.configuration, color=Config)
    transition = net.transition(net.t.review, guards=typed_guard(within_limit, converter=RecordingConverter()))
    pending >> transition
    configuration >> arc.read() >> transition
    return built(net)


@case("exact-bool")
def _():
    def truthy(order: Order) -> bool:
        return "yes"

    net = NetSpec("exact-bool")
    pending = net.place(net.p.pending, color=Order)
    transition = net.transition(net.t.review, guards=typed_guard(truthy))
    pending >> transition
    return built(net)


@case("guards")
def _():
    net = NetSpec("guards")
    transition = net.t.review
    net.transition(transition, guards=("named", positive, Cel("true"), positive))
    net.place(net.p.pending, color=Order) >> transition
    return built(net)


@case("scalar")
def _():
    scalar = NetSpec("scalar")
    scalar.transition(scalar.t.review, guards="named")
    scalar.p.pending >> scalar.t.review
    return built(scalar)


@case("typed.untyped-input")
def _():
    net = NetSpec("typed-refusal")
    transition = net.transition(net.t.process, handler=process)
    net.p.pending >> transition >> net.p.receipt(Receipt)
    return built(net)


@case("identity")
def _():
    net = NetSpec("identity")
    transition = net.transition(net.t.process, handler=petri_handler(handler), guards=petri_guard(guard))
    net.p.pending >> transition
    return built(net)


@case("reuse")
def _():
    specification = petri_guard(guard)
    net = NetSpec("reuse")
    net.transition(net.t.left, guards=specification)
    net.transition(net.t.right, guards=specification)
    net.p.pending >> (net.t.left, net.t.right)
    return built(net)


def callable_snapshots(second: bool):
    def first_handler(binding, outputs):
        return {}

    def second_handler(binding, outputs):
        return {}

    net = NetSpec("callable-snapshots")
    transition = net.transition(net.t.process, handler=petri_handler(first_handler))
    net.p.pending >> transition
    if second:
        transition.override(handler=petri_handler(second_handler))
    return built(net)


case("callable-snapshots.first")(lambda: callable_snapshots(False))
case("callable-snapshots.second")(lambda: callable_snapshots(True))


@case("stamp-rebase")
def _():
    lens = NetSpec("review-lens")
    lens.p.work(Order) >> lens.t.review(handler=petri_handler(handler), guards=petri_guard(guard)) >> lens.p.done
    root = NetSpec("reviews")
    correctness = root.s.review.s.correctness.stamp(lens)
    risk = root.s.review.s.risk.stamp(lens)
    correctness.p.done(Receipt)
    risk.p.done(Receipt)
    correctness.t.review.override(handler="correctness")
    result = NetBuilder(root).build()
    return verdict(result.net, result.handlers, result.guards)


@case("flat-and-stamped")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.finish >> child.p.done
    root = NetSpec("root")
    review = root.s.review
    review.p.context >> review.t.publish
    stamped = review.s.correctness.stamp(child)
    stamped.p.done >> review.t.publish
    return built(root)


def live(second: bool):
    child = NetSpec("child")
    child.p.pending >> child.t.process >> child.p.done
    root = NetSpec("root")
    root.s.worker.stamp(child)
    if second:
        child.t.process >> child.p.audit
    return built(root)


case("live.first")(lambda: live(False))
case("live.second")(lambda: live(True))


@case("restamp")
def _():
    first = NetSpec("first")
    first.p.pending >> first.t.process(handler="first") >> first.p.done
    second = NetSpec("second")
    second.p.ready >> second.t.process(handler="second") >> second.p.complete
    root = NetSpec("root")
    worker = root.s.worker.stamp(first)
    worker.t.process.override(handler="specialized")
    worker.stamp(second)
    return built(root)


@case("restamp.kept-override")
def _():
    first = NetSpec("first")
    first.p.pending >> first.t.process(handler="first") >> first.p.done
    root = NetSpec("root")
    worker = root.s.worker.stamp(first)
    worker.t.process.override(handler="specialized")
    worker.p.done(Receipt)
    return built(root)


@case("stamp-direct-content.error")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process
    root = NetSpec("root")
    root.s.worker.p.local
    root.s.worker.stamp(child)


@case("stamp-direct-content.after")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process
    root = NetSpec("root")
    root.s.worker.p.local
    try:
        root.s.worker.stamp(child)
    except ValueError:
        pass
    return built(root)


@case("stamp-direct-content.owners")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process
    root = NetSpec("root")
    root.s.worker.p.local >> root.s.worker.t.act
    root.s.worker.s.inner.stamp(child)
    root.s.worker.stamp(child)


def stamp_diagnostics(which: str):
    child = NetSpec("child")
    child.p.pending >> child.t.process
    replacement = NetSpec()
    root = NetSpec("root")
    worker = root.s.worker.stamp(child)
    if which == "enclosing":
        worker.s.nested.stamp(replacement)
    elif which == "missing-transition":
        worker.t.missing.override(handler="missing")
    elif which == "missing-place":
        worker.p.missing(Order)
    elif which == "scope-itself":
        root.s.worker.p.pending.override(color=None)
    return built(root)


for which in ("enclosing", "missing-transition", "missing-place", "scope-itself"):
    case(f"stamp-diagnostics.{which}")(lambda which=which: stamp_diagnostics(which))


@case("root-stamp")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process
    NetSpec("root").s.stamp(child)


@case("missing-connection")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process
    root = NetSpec("root")
    worker = root.s.worker.stamp(child)
    worker.p.missing >> root.t.publish
    return built(root)


@case("nested-stamps")
def _():
    inner = NetSpec("inner")
    inner.p.pending >> inner.t.process >> inner.p.done
    outer = NetSpec("outer")
    outer.s.child.stamp(inner)
    root = NetSpec("root")
    root.s.parent.stamp(outer)
    return built(root)


@case("copy")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process >> child.p.done
    root = NetSpec("root")
    root.s.worker.stamp(child)
    copied = root.copy()
    return built(copied)


@case("copy.stamped")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process(handler="x") >> child.p.done(Order)
    outer = NetSpec("outer")
    outer.s.inner.stamp(child)
    outer.s.inner.t.process.override(handler="y")
    outer.s.inner.p.done.override(color="Receipt")
    flat = outer.copy()
    wrapper = NetSpec("wrapper")
    wrapper.s.a.stamp(flat)
    wrapper.s.b.stamp(flat)
    wrapper.s.a.s.inner.p.done >> wrapper.t.join
    wrapper.t.join >> wrapper.s.b.s.inner.p.pending
    return built(wrapper)


@case("inherited-configuration")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process >> child.p.done
    root = NetSpec("root")
    worker = root.s.worker.stamp(child)
    worker.p.pending("Order")
    worker.p.pending("Order")
    worker.t.process(handler="x", timers=(Delay(2),))
    worker.t.process(handler="x", timers=(Delay(2),))
    worker.t.process.override(guards=("g",))
    return built(root)


@case("inherited-configuration.conflict")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process(handler="x") >> child.p.done("Order")
    root = NetSpec("root")
    worker = root.s.worker.stamp(child)
    worker.t.process(handler="y")


@case("inherited-configuration.color-conflict")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process(handler="x") >> child.p.done("Order")
    root = NetSpec("root")
    worker = root.s.worker.stamp(child)
    worker.p.done("Receipt")


@case("stamped-completion")
def _():
    child = NetSpec("child", completion="complete")
    child.p.pending >> child.t.process
    root = NetSpec("root")
    root.s.worker.stamp(child)
    return built(root)


for segment in ("p", "t", "s", "stamp"):

    def reserved(segment=segment):
        net = NetSpec("reserved-scopes")
        scope = net.s[segment]
        scope.p.pending >> scope.t.process
        return built(net)

    case(f"reserved.{segment}")(reserved)


for segment in ("", "nested.scope"):

    def bad_segment(segment=segment):
        NetSpec().s[segment]

    case(f"scope-segment.{segment or 'empty'}")(bad_segment)


@case("apply.flat")
def _():
    flat = NetSpec("flat")
    flat.s.apply.p.pending >> flat.s.apply.t.process
    return built(flat)


@case("apply.composed")
def _():
    child = NetSpec("child")
    child.p.pending >> child.t.process
    composed = NetSpec("composed")
    composed.s.apply.stamp(child)
    return built(composed)


@case("unnamed")
def _():
    unnamed = NetSpec()
    unnamed.p.pending >> unnamed.t.process
    return built(unnamed)


@case("empty-name")
def _():
    NetSpec("")


@case("agent-net")
def _():
    return verdict(AGENT_AS_NET, agent_net_handlers(), agent_net_guards())


@case("simulation-scenario")
def _():
    spec = NetSpec("bounded-simulation-demo", completion=Cel("size(done) > 0"))
    spec.p.pending(color="SimulationItem")
    spec.p.done(color="SimulationItem")
    spec.t.finish(guards=Cel("size(pending) > 0"), timers=(Delay(5),))
    spec.p.pending >> arc(filter=Cel("priority >= 1")) >> spec.t.finish >> spec.p.done
    return built(spec)


@case("observation-inspection")
def _():
    lens = NetSpec("lens")
    review = lens.t.review(
        handler=petri_handler(handler),
        guards=("ready", Cel("true")),
        timers=(Delay(3), Until(11)),
    )
    lens.p.pending("Work") >> review >> lens.p.done("Done")
    lens.p.context("Context") >> arc.read(filter=Cel("true")) >> review
    lens.p.blocked("Block") >> arc.inhibit(filter="same_key") >> review
    root = NetSpec("canonical-design", completion=Cel("size(review.correctness.done) > 0"))
    correctness = root.s.review.s.correctness.stamp(lens)
    root.t.ingest >> correctness.p.pending
    correctness.t.review >> correctness.p.done
    return built(root)


def chain(size: int) -> NetSpec:
    """A flat chain of ``size`` places and ``size`` transitions (benchmark workload a)."""
    net = NetSpec(f"chain-{size}")
    for index in range(size):
        getattr(net.p, f"p{index}")("Item") >> getattr(net.t, f"t{index}")(handler="step") >> getattr(
            net.p, f"p{index + 1}"
        )("Item")
    return net


def stamped(scopes: int) -> NetSpec:
    """A 10-node child stamped at ``scopes`` scopes nested to depth 3 (benchmark workload b)."""
    child = NetSpec("unit")
    for index in range(5):
        getattr(child.p, f"in{index}")("Item") >> getattr(child.t, f"step{index}")(handler="step") >> child.p.out(
            "Item"
        )
    root = NetSpec(f"stamped-{scopes}")
    for index in range(scopes):
        root.s[f"a{index % 10}"].s[f"b{index // 10 % 10}"].s[f"c{index // 100}"].stamp(child)
    return root


case("chain-50")(lambda: built(chain(50)))
case("stamped-30")(lambda: built(stamped(30)))


def main() -> None:
    output = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent) / OUTPUT_NAME
    output.write_text(json.dumps(CASES, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {len(CASES)} cases to {output}")


if __name__ == "__main__":
    main()
