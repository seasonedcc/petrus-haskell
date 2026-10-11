"""Generate the end-to-end CEL Instance corpus: Instances whose nets declare
inline CEL guards, arc filters, and completion conditions, run by the pinned
Python reference.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-cel/test/gen-cel-instance.py

The script writes ``corpus/cel-instance.json`` next to itself (or
``cel-instance.json`` into the directory given as its first argument). Each case is a
hand-written net (carried as its canonical Net definition v3 text) and an
initial marking; the Instance is stepped until quiescent. Before every step
the candidate bindings and the enabledness warnings (filter and guard
evaluation errors) are recorded, then the firing outcome; at the end the
marking, the status with its completion warnings, and the complete encoded
schema-5 History. ``InstanceSpec`` replays each case through the Haskell
kernel with ``Petrus.Cel.Impetus.celCompilers`` and compares everything.

One normalisation: cel-python's "undeclared reference" errors embed
``repr()`` of the whole activation, which includes function addresses. The
script replaces ``Activation.__repr__`` with the fixed text
``<Activation>``, which is what the Haskell evaluator prints there.
"""

from __future__ import annotations

import json
import sys
import warnings
from pathlib import Path

import celpy.evaluation

from petrus.impetus.history.codec import encode_record
from petrus.impetus.instance import Instance
from petrus.impetus.net_definition import project_net_definition, serialize_net_definition
from petrus.impetus.petrinet import Arc, ArcMode, Cel, Marking, Net, NetPath, Place, Token, Transition

OUTPUT_NAME = "cel-instance.json"

celpy.evaluation.Activation.__repr__ = lambda self: "<Activation>"


def p(name: str) -> NetPath:
    return NetPath(name)


def encoded_token(value: Token) -> dict[str, object]:
    return {"color": value.color, "data": value.data}


def encoded_binding(value) -> dict[str, object]:
    return {
        "transition": str(value.transition),
        "consumed": [{"place": str(q), "tokens": [encoded_token(t) for t in ts]} for q, ts in value.consumed],
        "read": [{"place": str(q), "tokens": [encoded_token(t) for t in ts]} for q, ts in value.read],
        "delivered": [encoded_token(t) for t in value.delivered],
    }


def encoded_marking(value: Marking) -> list[dict[str, object]]:
    return [
        {"place": str(place), "tokens": [encoded_token(item) for item in tokens]}
        for place, tokens in sorted(value, key=lambda entry: str(entry[0]))
    ]


def encoded_outcome(value) -> dict[str, object] | None:
    if value is None:
        return None
    return {
        "occurrence": value.occurrence,
        "transition": str(value.transition),
        "consumed": [encoded_token(item) for item in value.consumed],
        "produced": [{"place": str(place), "token": encoded_token(item)} for place, item in value.produced],
    }


def payment(amount: object) -> Token:
    return Token("Payment", {"amount": amount, "currency": "USD"})


def case_routing() -> tuple[Net, Marking]:
    """Complementary CEL guards, a CEL arc filter, and a CEL completion."""
    pending, accept, reject, accepted, rejected = p("pending"), p("accept"), p("reject"), p("accepted"), p("rejected")
    net = Net(
        places=[Place(pending), Place(accepted), Place(rejected)],
        transitions=[
            Transition(accept, guards=(Cel("pending[0].data.amount >= 100"),)),
            Transition(reject, guards=(Cel("pending[0].data.amount < 100"),)),
        ],
        arcs=[
            Arc(pending, accept, filter=Cel('currency == "USD"')),
            Arc(pending, reject),
            Arc(accept, accepted),
            Arc(reject, rejected),
        ],
        completion=Cel("size(pending) == 0 && accepted.all(t, t.data.amount >= 100)"),
    )
    marking = Marking({pending: (payment(150), payment(40), Token("Payment", {"amount": 250, "currency": "EUR"}), payment(100))})
    return net, marking


def case_errors() -> tuple[Net, Marking]:
    """Evaluation errors: non-mapping data, undeclared fields, type errors, division by zero."""
    inbox, take, keep, out, kept = p("inbox"), p("take"), p("keep"), p("out"), p("kept")
    net = Net(
        places=[Place(inbox), Place(out), Place(kept)],
        transitions=[
            Transition(take, guards=(Cel("inbox[0].data.n / inbox[0].data.d > 1"),)),
            Transition(keep),
        ],
        arcs=[
            Arc(inbox, take, filter=Cel("n > 0")),
            Arc(inbox, keep, filter=Cel("has(keep) && keep")),
            Arc(take, out),
            Arc(keep, kept),
        ],
        completion=Cel("out[0].data.n > 0"),
    )
    marking = Marking(
        {
            inbox: (
                Token.black(),
                Token("Item", [1, 2]),
                Token("Item", {"m": 1}),
                Token("Item", {"n": "x", "d": 1}),
                Token("Item", {"n": 4, "d": 0}),
                Token("Item", {"n": 5, "d": 2, "keep": True}),
                Token("Item", {"n": 9, "d": 3}),
            )
        }
    )
    return net, marking


def case_correlation() -> tuple[Net, Marking]:
    """A read arc and a weighted arc correlated in one guard, with macros."""
    config, pending, approve, out = p("config"), p("pending"), p("approve"), p("out")
    net = Net(
        places=[Place(config), Place(pending), Place(out)],
        transitions=[
            Transition(
                approve,
                guards=(
                    Cel("pending.all(t, t.data.amount <= config[0].data.limit)"),
                    Cel("size(pending.filter(t, t.data.amount > 0)) == 2"),
                ),
            )
        ],
        arcs=[
            Arc(config, approve, mode=ArcMode.READ),
            Arc(pending, approve, weight=2),
            Arc(approve, out),
        ],
        completion=Cel('size(out) == 2 && out.exists_one(t, t.data.amount == 70) && config.map(c, c.data.limit) == [100]'),
    )
    marking = Marking(
        {
            config: (Token("Config", {"limit": 100}),),
            pending: (payment(150), payment(30), payment(70), payment(-5), payment(20)),
        }
    )
    return net, marking


def case_inhibit_and_black() -> tuple[Net, Marking]:
    """Guards over black tokens and an inhibit arc outside the guard's scope."""
    a, block, t, b = p("a"), p("block"), p("t"), p("b")
    net = Net(
        places=[Place(a), Place(block), Place(b)],
        transitions=[Transition(t, guards=(Cel("a[0].color == null && a[0].data == null && size(a) == 1"),))],
        arcs=[Arc(a, t), Arc(block, t, mode=ArcMode.INHIBIT), Arc(t, b)],
        completion=Cel('size(a) == 0 && b.exists(x, x.color == "Payment") || size(b) >= 2'),
    )
    marking = Marking({a: (Token.black(), Token.black())})
    return net, marking


def case_completion_errors() -> tuple[Net, Marking]:
    """A completion condition that raises on the final marking."""
    a, t, b = p("a"), p("t"), p("b")
    net = Net(
        places=[Place(a), Place(b)],
        transitions=[Transition(t)],
        arcs=[Arc(a, t), Arc(t, b)],
        completion=Cel("b[0].data.missing == 1 || a[0].data > 0"),
    )
    return net, Marking({a: (Token("X", {"k": 1}),)})


CASES = {
    "routing": case_routing,
    "errors": case_errors,
    "correlation": case_correlation,
    "inhibit-and-black": case_inhibit_and_black,
    "completion-errors": case_completion_errors,
}


def warned(action):
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        value = action()
    return value, [str(w.message) for w in caught]


def run_case(name: str, build) -> dict[str, object]:
    net, marking = build()
    instance = Instance(net, marking, instance_id=f"cel-{name}")
    steps = []
    while True:
        candidates, diagnostics = warned(instance.candidates)
        outcome, _ = warned(lambda: instance.step())
        steps.append(
            {
                "candidatesBefore": [encoded_binding(value) for value in candidates],
                "diagnosticsBefore": diagnostics,
                "outcome": encoded_outcome(outcome),
                "markingAfter": encoded_marking(instance.marking),
            }
        )
        if outcome is None:
            break
    status, status_diagnostics = warned(lambda: instance.status)
    return {
        "name": name,
        "definition": serialize_net_definition(project_net_definition(net)).decode(),
        "initialMarking": encoded_marking(marking),
        "steps": steps,
        "status": status.value,
        "statusDiagnostics": status_diagnostics,
        "history": [encode_record(record) for record in instance.history],
    }


def main() -> None:
    cases = [run_case(name, build) for name, build in CASES.items()]
    corpus = {"generator": "packages/petrus-cel/test/gen-cel-instance.py", "celpy": "0.5.0", "cases": cases}
    output = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "corpus") / OUTPUT_NAME
    output.write_text(json.dumps(corpus, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {output.name}: {len(cases)} cases, {sum(len(c['steps']) for c in cases)} steps")


if __name__ == "__main__":
    main()
