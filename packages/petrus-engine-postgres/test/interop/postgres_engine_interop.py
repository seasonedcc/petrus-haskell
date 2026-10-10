"""The reference's half of the PostgreSQL Engine interop suite.

Run from upstream/petrus with the pinned environment (psycopg from the
``postgres`` extra). The first argument is a libpq connection string to the
scratch database the Haskell suite also uses; every Engine here is the
reference's ``petrus.engine.postgres`` composition over a join-mode
connection, so the authority fence, the joined History, and the commit
points are the reference's own.

Subcommands (DSN first):
  create INSTANCE IDENTITY        create over the provider net, deliver one black
                                  token with IDENTITY, close; print the state
  load-deliver INSTANCE IDENTITY  load, deliver one black token, close; print the state
  inspect INSTANCE                load, close; print the state
  hold INSTANCE                   load and hold the Engine (and its fence); print
                                  "held"; stdin "close" closes it and prints "closed"
  try-load INSTANCE               load; print {"loaded": true} or the refusal and
                                  whether the supplied connection was closed
  fail-projection INSTANCE        create over the projecting net, accept event-7,
                                  complete with a projection that raises
  prior INSTANCE                  load over the projecting net (a forwarding
                                  projection), redeliver event-7; print the answer
  retry-acceptance INSTANCE       load over the provider net, redeliver event-7,
                                  complete it; print the occurrence and output
  ring-results INSTANCE OCC JSON  in one transaction: record a result row in
                                  public.interop_results and pg_notify the results
                                  doorbell (Absurd's RESULTS_CHANNEL)
  fence-key INSTANCE              print the authority fence key

The state is {"output": len(marking.place(OUTPUT)), "records": [encode_record(r)]}.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.getcwd())

import psycopg  # noqa: E402

from petrus.engine._postgres import _fence_key  # noqa: E402
from petrus.engine.postgres import create_engine, load_engine  # noqa: E402
from petrus.impetus.history.codec import encode_record  # noqa: E402
from petrus.impetus.instance import AcceptedDelivery, PriorAcknowledgement  # noqa: E402
from petrus.impetus.petrinet import Arc, Net, NetPath, Place, Token, Transition  # noqa: E402
from petrus.motus.dispatch import InlineDispatch  # noqa: E402
from petrus.motus.dispatch.absurd import RESULTS_CHANNEL  # noqa: E402

SOURCE, OUTPUT = NetPath("source"), NetPath("output")
EVENT = Token("Event", 7)


def provider_net() -> Net:
    return Net(places=[Place(OUTPUT)], transitions=[Transition(SOURCE)], arcs=[Arc(SOURCE, OUTPUT)])


def projecting_net() -> Net:
    return Net(
        places=[Place(OUTPUT)],
        transitions=[Transition(SOURCE, handler="project")],
        arcs=[Arc(SOURCE, OUTPUT)],
    )


def _out(value) -> None:
    print(json.dumps(value), flush=True)


def _state(engine) -> dict:
    return {"output": len(engine.marking.place(OUTPUT)), "records": [encode_record(r) for r in engine.records]}


def _joined(dsn: str):
    return psycopg.connect(dsn, autocommit=False)


def main(dsn: str, command: str, arguments: list[str]) -> None:
    if command == "create":
        instance, identity = arguments
        engine = create_engine(_joined(dsn), provider_net(), instance, dispatch=InlineDispatch({}))
        engine.deliver(SOURCE, Token.black(), identity=identity)
        _out(_state(engine))
        engine.close()
    elif command == "load-deliver":
        instance, identity = arguments
        engine = load_engine(_joined(dsn), provider_net(), instance, dispatch=InlineDispatch({}))
        engine.deliver(SOURCE, Token.black(), identity=identity)
        _out(_state(engine))
        engine.close()
    elif command == "inspect":
        (instance,) = arguments
        engine = load_engine(_joined(dsn), provider_net(), instance, dispatch=InlineDispatch({}))
        _out(_state(engine))
        engine.close()
    elif command == "hold":
        (instance,) = arguments
        engine = load_engine(_joined(dsn), provider_net(), instance, dispatch=InlineDispatch({}))
        _out("held")
        for line in sys.stdin:
            if line.strip() == "close":
                engine.close()
                _out("closed")
                break
    elif command == "try-load":
        (instance,) = arguments
        connection = _joined(dsn)
        try:
            engine = load_engine(connection, provider_net(), instance, dispatch=InlineDispatch({}))
        except (RuntimeError, ValueError) as error:
            _out({"error": f"{type(error).__name__}: {error}", "closed": connection.closed})
        else:
            engine.close()
            _out({"loaded": True, "closed": connection.closed})
    elif command == "fail-projection":
        (instance,) = arguments

        def explode(binding, outputs):
            raise RuntimeError("projection failed")

        engine = create_engine(
            _joined(dsn), projecting_net(), instance, dispatch=InlineDispatch({}), handlers={"project": explode}
        )
        accepted = engine.accept_delivery(SOURCE, EVENT, identity="event-7")
        try:
            engine.complete_delivery(accepted)
        except RuntimeError as error:
            _out(f"failed: {error}")
        else:
            raise SystemExit("the projection did not fail")
    elif command == "prior":
        (instance,) = arguments
        engine = load_engine(
            _joined(dsn),
            projecting_net(),
            instance,
            dispatch=InlineDispatch({}),
            handlers={"project": lambda binding, outputs: {OUTPUT: binding.tokens}},
        )
        answer = engine.accept_delivery(SOURCE, EVENT, identity="event-7")
        assert isinstance(answer, PriorAcknowledgement), answer
        _out({"identity": answer.identity, "occurrence": answer.occurrence, "output": len(engine.marking.place(OUTPUT))})
        engine.close()
    elif command == "retry-acceptance":
        (instance,) = arguments
        engine = load_engine(_joined(dsn), provider_net(), instance, dispatch=InlineDispatch({}))
        accepted = engine.accept_delivery(SOURCE, EVENT, identity="event-7")
        assert isinstance(accepted, AcceptedDelivery), accepted
        outcome = engine.complete_delivery(accepted)
        _out({"accepted": accepted.occurrence, "completed": outcome.occurrence, **_state(engine)})
        engine.close()
    elif command == "ring-results":
        instance, occurrence, result = arguments
        with psycopg.connect(dsn, autocommit=False) as connection:
            connection.execute(
                "INSERT INTO public.interop_results (instance_id, occurrence, result) VALUES (%s, %s, %s::jsonb)",
                (instance, int(occurrence), result),
            )
            connection.execute("SELECT pg_notify(%s, %s)", (RESULTS_CHANNEL, "default"))
            connection.commit()
    elif command == "fence-key":
        (instance,) = arguments
        _out(_fence_key(instance))
    else:
        raise SystemExit(f"unknown command {command!r}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
