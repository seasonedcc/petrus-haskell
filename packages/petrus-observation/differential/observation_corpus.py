"""Generate the observation differential corpus from the pinned reference.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-observation/differential/observation_corpus.py

The script writes ``observation_corpus.json`` next to itself (or into the directory given as its first argument). Each scenario
drives a reference ``Engine`` (in-memory History, in-memory Dispatch, the
default simulated clock) the way ``tests/petrus/engine/test_observation.py``
does, and records the Engine's three read doors: ``snapshot()``,
``history_page(0, 1000)``, and ``net_document()``. ``CorpusSpec`` rebuilds
each state with the Haskell Instance doors and requires every projection to
be exactly equal, member order and int/float spelling included.

The ``errors`` section records the reference's refusal text for each
observation error the Haskell types can still reach.
"""

from __future__ import annotations

import json
import sys
import math
from pathlib import Path

from petrus.engine import Engine
from petrus.impetus.history_store import InMemoryHistoryStore
from petrus.impetus.observation import definition, net_document
from petrus.impetus.petrinet import Arc, Cel, Delay, Marking, Net, NetPath, Place, Token, Transition, Until
from petrus.motus.activity import ActivityFailure, ActivityInvocation
from petrus.motus.dispatch import InMemoryDispatch

OUTPUT_NAME = "observation_corpus.json"
A, B, C = NetPath("a"), NetPath("b"), NetPath("c")
SOURCE, WORK = NetPath("source"), NetPath("work")


class Bridge:
    def prepare(self, binding):
        return ActivityInvocation(
            "canonical.activity",
            input={"nested": [binding.tokens[0].data]},
            correlation="canonical-correlation",
            idempotency="canonical-idempotency",
        )

    def project(self, binding, result):
        return {B: (Token("Done", result),)}


def create(net, instance, marking=None, handlers=None, at=0):
    return Engine.create(
        net,
        instance,
        history=InMemoryHistoryStore(),
        dispatch=InMemoryDispatch(),
        marking=marking,
        handlers=handlers,
        at=at,
    )


def canonical():
    net = Net(
        places=[Place(C), Place(A, "Input"), Place(B, "Done")],
        transitions=[Transition(WORK, handler="bridge"), Transition(SOURCE)],
        arcs=[Arc(SOURCE, C), Arc(A, WORK), Arc(WORK, B)],
        completion=Cel("size(b) > 0"),
        name="canonical-observation",
    )
    engine = create(
        net,
        "canonical-instance",
        marking=Marking({A: (Token("Input", {"ordinal": 1}), Token("Input", {"ordinal": 2}))}),
        handlers={"bridge": Bridge()},
        at=7,
    )
    assert engine.advance().ready
    return engine


def reads(engine, *, document=True):
    result = {"snapshot": engine.snapshot(), "history_page": engine.history_page(0, 1000)}
    if document:
        result["net_document"] = engine.net_document()
    return result


def scenarios():
    yield "canonical", canonical()

    engine = canonical()
    engine._instance.record_activity_completion(engine.in_flight[0], {"nested": [{"value": 1}]}, at=8)
    yield "projection_pending_result", engine

    engine = canonical()
    engine._instance.record_activity_failure(
        engine.in_flight[0],
        ActivityFailure("invalid", kind="InvalidRequest", details={"field": "name"}, retryable=False, retry_after=9),
        at=8,
    )
    yield "projection_pending_failure", engine

    engine = canonical()
    engine._instance.record_activity_completion(engine.in_flight[0], {"total": 2.5}, at=8)
    assert engine.advance().ready
    yield "projected_and_next_begun", engine

    engine = create(
        Net([Place(A), Place(B)], [Transition(WORK)], [Arc(A, WORK), Arc(WORK, B)]),
        "pure-pending",
        marking=Marking({A: (Token("Input", {"nested": [1]}),)}),
    )
    engine._instance.begin(engine._instance.candidates()[0])
    yield "pure_pending", engine

    engine = create(
        Net([Place(A), Place(B)], [Transition(WORK, handler="bridge")], [Arc(A, WORK), Arc(WORK, B)]),
        "detached",
        marking=Marking({A: (Token("Input", {"items": [{"value": 1}]}),)}),
        handlers={"bridge": Bridge()},
    )
    engine.advance()
    yield "detached", engine

    yield "timed", create(
        Net([Place(A)], [Transition(WORK, timers=(Delay(5),))], [Arc(A, WORK)]),
        "timed",
        marking=Marking({A: (Token("X"),)}),
        at=2,
    )

    engine = canonical()
    scope = engine.open_scope("draft")
    engine.deliver(SOURCE, Token("External", 1), identity="draft-1", scope=scope)
    engine.close_scope(scope)
    yield "scoped", engine

    engine = canonical()
    engine.seal(SOURCE)
    yield "sealed", engine

    places = ["\U0001d538", "ｚ", "z", "Z", "é", "a.b", "a"]
    yield "unicode_places", create(
        Net([Place(NetPath(p)) for p in places], [], [], name="ordering é\U0001d538"),
        "unicode-é",
        marking=Marking(
            {
                NetPath(p): (Token("X", {"text": "café \U0001d538", "n": index, "f": index / 2}), Token(None))
                for index, p in enumerate(places)
            }
        ),
    )


def error(callable_):
    try:
        callable_()
    except Exception as exception:  # noqa: BLE001 - the refusal text is the datum
        return str(exception)
    raise AssertionError("expected a refusal")


def bad_data(data, at=0):
    return create(Net([Place(A)], [], []), "bad-data", marking=Marking({A: (Token("X", data),)}), at=at)


def errors():
    timed = lambda timer: Net([Place(A)], [Transition(WORK, timers=(timer,))], [Arc(A, WORK)])  # noqa: E731
    yield "delay_float", error(lambda: definition(timed(Delay(1.5))))
    yield "until_float", error(lambda: definition(timed(Until(1.5))))
    yield "until_unsafe", error(lambda: definition(timed(Until(2**60))))
    yield "snapshot_nan", error(lambda: bad_data({"bad": math.nan}).snapshot())
    yield "snapshot_inf", error(lambda: bad_data([1, {"bad": -math.inf}]).snapshot())
    yield "document_unsafe_integer", error(lambda: bad_data({"bad": 2**60}).net_document())
    yield "snapshot_float_watermark", error(lambda: bad_data(1, at=7.5).snapshot())
    engine = canonical()
    for after, limit in [(-1, 1), (True, 1), (0.5, 1), (0, 0), (0, True), (0, 1.5), (0, -3), (8, 1)]:
        yield f"history_page_{after!r}_{limit!r}", error(lambda: engine.history_page(after, limit))
    yield "document_empty", error(lambda: net_document(engine._instance, ()))


def main() -> None:
    corpus = {
        "scenarios": {name: reads(engine) for name, engine in scenarios()},
        "errors": dict(errors()),
    }
    output = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent) / OUTPUT_NAME
    output.write_text(json.dumps(corpus, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
