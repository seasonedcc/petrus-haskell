"""Time the reference kernel on the same workloads as ``bench/Main.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-impetus/bench/python_bench.py

Each workload is built exactly as the Haskell benchmark builds it (same nets,
same markings, same sizes); every timing is the median of several runs after
one warm-up, printed in milliseconds together with a result size the Haskell
side prints too, so the two sides are seen to do the same work.
"""

from __future__ import annotations

import json
import statistics
import sys
import time

from petrus.impetus.history.codec import decode_record, encode_record
from petrus.impetus.history import replay_marking
from petrus.impetus.instance import Instance
from petrus.impetus.net_definition import (
    compile_net_definition,
    parse_net_definition,
    project_net_definition,
    serialize_net_definition,
)
from petrus.impetus.net_document import ExecutionLineage, parse_net_document, project_net_document, serialize_net_document
from petrus.impetus.petrinet import Arc, ArcMode, Delay, Marking, Net, NetPath, Place, Token, Transition, candidates

FANIN_PLACES = 6
FANIN_TOKENS = 3
FIFO_TOKENS = 10_000
WEIGHT_TOKENS = 30
FANOUT_PLACES = 50
FANOUT_TOKENS = 200
RUN_FIFO_TOKENS = 1_000
HISTORY_FIFO_TOKENS = 4_000
CHAIN_LENGTH = 200
TIMER_TOKENS = 50
TIMER_FIRINGS = 500
SCOPE_DELIVERIES = 200
LINEAGE_ENTRIES = 50


def item(n: int) -> Token:
    return Token("Item", {"seq": n})


def wide_fanin() -> tuple[Net, Marking]:
    places = [Place(NetPath(f"in{i}")) for i in range(FANIN_PLACES)] + [Place(NetPath("out"))]
    arcs = [Arc(NetPath(f"in{i}"), NetPath("t")) for i in range(FANIN_PLACES)] + [Arc(NetPath("t"), NetPath("out"))]
    net = Net(places=places, transitions=[Transition(NetPath("t"))], arcs=arcs)
    marking = Marking({NetPath(f"in{i}"): tuple(item(n) for n in range(FANIN_TOKENS)) for i in range(FANIN_PLACES)})
    return net, marking


def fifo(tokens: int, weight: int = 1) -> tuple[Net, Marking]:
    net = Net(
        places=[Place(NetPath("queue")), Place(NetPath("taken"))],
        transitions=[Transition(NetPath("take"))],
        arcs=[Arc(NetPath("queue"), NetPath("take"), ArcMode.CONSUME, weight), Arc(NetPath("take"), NetPath("taken"))],
    )
    return net, Marking({NetPath("queue"): tuple(item(n) for n in range(tokens))})


def wide_fanout() -> tuple[Net, Marking]:
    places = [Place(NetPath("src"))] + [Place(NetPath(f"out{i}")) for i in range(FANOUT_PLACES)]
    arcs = [Arc(NetPath("src"), NetPath("t"))] + [Arc(NetPath("t"), NetPath(f"out{i}")) for i in range(FANOUT_PLACES)]
    net = Net(places=places, transitions=[Transition(NetPath("t"))], arcs=arcs)
    return net, Marking({NetPath("src"): tuple(item(n) for n in range(FANOUT_TOKENS))})


def chain() -> Net:
    places = [Place(NetPath(f"p{i}"), "Item") for i in range(CHAIN_LENGTH)]
    transitions = [Transition(NetPath(f"t{i}")) for i in range(CHAIN_LENGTH - 1)]
    arcs = []
    for i in range(CHAIN_LENGTH - 1):
        arcs.append(Arc(NetPath(f"p{i}"), NetPath(f"t{i}")))
        arcs.append(Arc(NetPath(f"t{i}"), NetPath(f"p{i + 1}")))
    return Net(places=places, transitions=transitions, arcs=arcs, name="chain")


def chain_document():
    """The chain with a position for every node and a 50-entry lineage."""
    positions = {f"p{i}": (i * 10, 0) for i in range(CHAIN_LENGTH)}
    positions.update({f"t{i}": (i * 10 + 5, 1.5) for i in range(CHAIN_LENGTH - 1)})
    entries = [
        {
            "id": n,
            "parent": n - 1 if n else None,
            "provenance": "simulated",
            "marking": [{"place": f"p{n}", "tokens": [{"color": "Item", "data": {"seq": n}}]}],
            "metadata": {"step": n},
        }
        for n in range(LINEAGE_ENTRIES)
    ]
    lineage = ExecutionLineage.model_validate({"head": LINEAGE_ENTRIES - 1, "entries": entries})
    return project_net_document(chain(), positions, lineage=lineage)


def timer_ring() -> tuple[Net, Marking]:
    """A delayed self-loop: every firing re-enters its token, maturing a second later."""
    ring, tick = NetPath("ring"), NetPath("tick")
    net = Net(
        places=[Place(ring)],
        transitions=[Transition(tick, timers=(Delay(1),))],
        arcs=[Arc(ring, tick), Arc(tick, ring)],
    )
    return net, Marking({ring: tuple(item(n) for n in range(TIMER_TOKENS))})


def drive_timers(net: Net, marking: Marking) -> int:
    """Fire TIMER_FIRINGS matured bindings, waking at each next maturation."""
    instance = Instance(net, marking, instance_id="bench")
    fired = wakes = 0
    while fired < TIMER_FIRINGS:
        if instance.step() is None:
            instance.wake(instance.next_maturation)
            wakes += 1
        else:
            fired += 1
    return fired + wakes


SOURCE, QUEUE = NetPath("source"), NetPath("queue")


def filled_scope():
    """An Instance whose scope holds SCOPE_DELIVERIES delivered entries."""
    instance = Instance(
        Net(places=[Place(QUEUE)], transitions=[Transition(SOURCE)], arcs=[Arc(SOURCE, QUEUE)]),
        instance_id="bench",
    )
    scope = instance.open_scope("batch", at=1)
    for n in range(SCOPE_DELIVERIES):
        accepted = instance.accept_delivery(SOURCE, item(n), identity=f"d{n}", scope=scope, at=2)
        instance.complete_delivery(accepted, at=2)
    return instance, scope


def close_filled() -> int:
    instance, scope = filled_scope()
    return len(instance.close_scope(scope, at=3).discarded)


def reset_filled() -> int:
    instance, scope = filled_scope()
    return instance.reset_scope(scope, at=3).generation


def drained(tokens: int) -> Instance:
    net, marking = fifo(tokens)
    instance = Instance(net, marking, instance_id="bench")
    instance.run()
    return instance


def timed(name: str, action, repeats: int) -> None:
    size = action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    print(f"{name:32} {statistics.median(samples) * 1000:12.3f} ms   (size {size}, n={repeats})")
    sys.stdout.flush()


def main() -> None:
    fanin_net, fanin_marking = wide_fanin()
    fifo_net, fifo_marking = fifo(FIFO_TOKENS)
    weight_net, weight_marking = fifo(WEIGHT_TOKENS, 3)
    timed("candidates/wide-fanin", lambda: len(candidates(fanin_net, fanin_marking)), 20)
    timed("candidates/long-fifo", lambda: len(candidates(fifo_net, fifo_marking)), 20)
    timed("candidates/weight-3", lambda: len(candidates(weight_net, weight_marking)), 20)

    fanout_net, fanout_marking = wide_fanout()
    run_net, run_marking = fifo(RUN_FIFO_TOKENS)
    timed("instance-run/wide-fanout", lambda: len(Instance(fanout_net, fanout_marking, instance_id="bench").run()), 5)
    timed("instance-run/long-fifo", lambda: len(Instance(run_net, run_marking, instance_id="bench").run()), 3)

    history = tuple(drained(HISTORY_FIFO_TOKENS).history)
    text = json.dumps([encode_record(record) for record in history])
    timed("history/encode", lambda: len(json.dumps([encode_record(record) for record in history])), 5)
    timed("history/decode", lambda: len([decode_record(payload) for payload in json.loads(text)]), 5)
    timed("history/replay-marking", lambda: sum(len(tokens) for _, tokens in replay_marking(history)), 5)

    definition = project_net_definition(chain())
    payload = serialize_net_definition(definition)
    timed("net-definition/serialize", lambda: len(serialize_net_definition(definition)), 20)
    timed("net-definition/parse", lambda: len(parse_net_definition(payload).definition.places), 20)
    timed("net-definition/compile", lambda: len(compile_net_definition(definition).places), 20)

    document = chain_document()
    document_payload = serialize_net_document(document)
    timed("net-document/serialize", lambda: len(serialize_net_document(document)), 20)
    timed("net-document/parse", lambda: len(parse_net_document(document_payload).lineage.entries), 20)

    ring_net, ring_marking = timer_ring()
    timed("timers/delay-ring", lambda: drive_timers(ring_net, ring_marking), 5)

    timed("lifecycle-scope/fill", lambda: len(filled_scope()[0].marking.place(QUEUE)), 5)
    timed("lifecycle-scope/close", close_filled, 5)
    timed("lifecycle-scope/reset", reset_filled, 5)


if __name__ == "__main__":
    main()
