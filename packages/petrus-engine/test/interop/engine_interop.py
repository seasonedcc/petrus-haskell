"""The reference's half of the Engine interop suite (run from upstream/petrus).

One order scenario, driven through the reference Engine over a JSONL History:
three identified deliveries, a pure validation, an Activity charge, and a
delayed settlement.

Subcommands:
  run PATH      deliver, then advance to rest with InlineDispatch (one process)
  crash PATH    deliver, then advance to rest with InMemoryDispatch: the first
                charge stays in flight and the process exits (a crash window)
  resume PATH   load PATH with InlineDispatch and advance to rest
  inspect PATH  load PATH; print the marking as canonical JSON and the record count
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.getcwd())

from petrus.engine import Engine  # noqa: E402
from petrus.impetus.history_store import JsonlHistoryStore  # noqa: E402
from petrus.impetus.petrinet import Arc, Delay, Net, NetPath, Place, Token, Transition  # noqa: E402
from petrus.motus.activity import ActivityInvocation  # noqa: E402
from petrus.motus.dispatch import InlineDispatch, InMemoryDispatch  # noqa: E402

INTAKE, ORDERS, VALIDATE = NetPath("intake"), NetPath("orders"), NetPath("validate")
QUEUE, CHARGE, CHARGED = NetPath("queue"), NetPath("charge"), NetPath("charged")
SETTLE, DONE = NetPath("settle"), NetPath("done")
IDENTITY = "order-interop"


def order_net() -> Net:
    return Net(
        places=[Place(ORDERS), Place(QUEUE), Place(CHARGED), Place(DONE)],
        transitions=[
            Transition(INTAKE),
            Transition(VALIDATE, handler="validate"),
            Transition(CHARGE, handler="charge"),
            Transition(SETTLE, handler="settle", timers=(Delay(5),)),
        ],
        arcs=[
            Arc(INTAKE, ORDERS),
            Arc(ORDERS, VALIDATE),
            Arc(VALIDATE, QUEUE),
            Arc(QUEUE, CHARGE),
            Arc(CHARGE, CHARGED),
            Arc(CHARGED, SETTLE),
            Arc(SETTLE, DONE),
        ],
    )


def validate(binding, outputs):
    order = binding.tokens[0].data
    return {QUEUE: (Token("Valid", {"id": order["id"], "amount": order["amount"] * 100}),)}


def settle(binding, outputs):
    receipt = binding.tokens[0].data
    return {DONE: (Token("Settled", {"id": receipt["id"], "status": receipt["status"]}),)}


class Charge:
    def prepare(self, binding):
        valid = binding.tokens[0].data
        return ActivityInvocation("charge_card", input={"id": valid["id"], "cents": valid["amount"]})

    def project(self, binding, result):
        return {CHARGED: (Token("Receipt", result),)}


def handlers():
    return {"validate": validate, "charge": Charge(), "settle": settle}


def charge_card(invocation, *, context):
    return {"id": invocation.input["id"], "status": "captured", "cents": invocation.input["cents"]}


def advance_until_rest(engine: Engine) -> None:
    while engine.advance().ready:
        pass


def create(path: str, dispatch) -> Engine:
    engine = Engine.create(
        order_net(), IDENTITY, history=JsonlHistoryStore(path), dispatch=dispatch, handlers=handlers()
    )
    for n in (1, 2, 3):
        engine.deliver(INTAKE, Token("Order", {"id": f"o-{n}", "amount": n}), identity=f"evt_{n}")
    return engine


def main(command: str, path: str) -> None:
    if command == "run":
        engine = create(path, InlineDispatch({"charge_card": charge_card}))
        advance_until_rest(engine)
        engine.close()
    elif command == "crash":
        engine = create(path, InMemoryDispatch())
        advance_until_rest(engine)
        assert len(engine.in_flight) == 1, engine.in_flight
        os._exit(0)
    elif command == "resume":
        engine = Engine.load(
            order_net(),
            IDENTITY,
            history=JsonlHistoryStore(path),
            dispatch=InlineDispatch({"charge_card": charge_card}),
            handlers=handlers(),
        )
        advance_until_rest(engine)
        engine.close()
    elif command == "inspect":
        engine = Engine.load(
            order_net(), IDENTITY, history=JsonlHistoryStore(path), dispatch=InMemoryDispatch(), handlers=handlers()
        )
        marking = {
            str(place): [[token.color, token.data] for token in tokens] for place, tokens in engine.marking
        }
        print(json.dumps(marking, sort_keys=True))
        print(len(engine.records))
        engine.close()
    else:
        raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
