"""Random implementation-free scenarios and the upstream runner's outcomes.

Usage: python -I corpus_simulation.py SEED COUNT

Writes COUNT JSON lines. Each holds a generated Net definition v3 document
(``definition``, the serialized text), an initial marking in the protocol-v1
shape (``marking``), ``max_actions``, and what ``petrus.simulation.simulate``
did with the compiled definition: ``{"ok": <result text>}``,
``{"profile_error": <message>}`` or ``{"error": <exception type>}``.
Nets that the Petrus Net constructor refuses are regenerated.
"""

import json
import random
import sys
import warnings

from petrus.impetus.dsl import BuiltNet
from petrus.impetus.net_definition import (
    compile_net_definition,
    parse_net_definition,
    project_net_definition,
    serialize_net_definition,
)
from petrus.impetus.petrinet import Arc, ArcMode, Cel, Delay, Net, NetPath, Place, Transition, Until
from petrus.simulation import SimulationProfileError, simulate
from petrus.simulation_http import _decode_marking

DATA = [
    lambda rng: {"priority": rng.randint(0, 6)},
    lambda rng: {"priority": rng.randint(1, 6)},
    lambda rng: {"priority": rng.randint(1, 3), "id": f"item-{rng.randint(0, 99)}"},
    lambda rng: {"priority": rng.randint(0, 6), "id": f"item-{rng.randint(0, 99)}"},
    lambda rng: {"priority": rng.choice([1.5, -0.0, 2.25])},
    lambda rng: None,
    lambda rng: "text",
    lambda rng: {},
    lambda rng: {"priority": 3, "tags": ["a", "é", "😀"], "nested": {"ok": True}},
]


def generate_net(rng: random.Random) -> Net:
    count = rng.randint(1, 5)
    names = [f"p{index}" for index in range(count)]
    colors = {name: rng.choice([None, None, None, "C", "D"]) for name in names}
    places = [Place(NetPath(name), colors[name]) for name in names]

    def guard_over(place: str) -> Cel:
        # A guard may read only its transition's consume/read input places.
        return Cel(
            rng.choice(
                [
                    f"size({place}) > 0",
                    f"size({place}) < {rng.randint(1, 4)}",
                    f"size({place}) >= {rng.randint(1, 3)}",
                    "true",
                    "false",
                ]
            )
        )

    transitions = []
    arcs = []
    for index in range(rng.randint(1, 5) if rng.random() < 0.9 else 0):
        path = NetPath(f"t{index}")
        source = rng.choice(names) if rng.random() < 0.85 else None
        if source is not None:
            guards = tuple(guard_over(source) for _ in range(rng.choice([0, 0, 1, 2])))
        else:
            guards = (Cel("true"),) if rng.random() < 0.2 else ()
        timers = tuple(
            rng.choice([Delay, Until])(rng.randint(0, 10)) for _ in range(rng.choice([0, 0, 0, 1, 2]))
        )
        transitions.append(Transition(path, guards=guards, timers=timers))
        if source is not None:
            filter_ = (
                Cel(rng.choice(["priority >= 1", "priority < 5", "true", "priority == 2"]))
                if rng.random() < 0.4
                else None
            )
            color = colors[source] if rng.random() < 0.2 else None
            arcs.append(Arc(NetPath(source), path, filter=filter_, color=color))
        for _ in range(rng.choice([0, 0, 0, 0, 0, 1, 2])):
            arcs.append(Arc(NetPath(rng.choice(names)), path, mode=ArcMode.INHIBIT))
        if rng.random() < 0.02:
            arcs.append(Arc(NetPath(rng.choice(names)), path, mode=ArcMode.READ))
        for _ in range(rng.choice([0, 1, 1, 1, 1, 1, 1, 1, 1, 2])):
            arcs.append(Arc(path, NetPath(rng.choice(names))))
    completion = Cel(f"size({rng.choice(names)}) > 0") if rng.random() < 0.4 else None
    name = rng.choice([None, "generated"])
    return Net(places, transitions, arcs, completion=completion, name=name)


def generate_marking(rng: random.Random, net: Net) -> list[object]:
    entries = []
    heavy = rng.random() < 0.05
    for place in sorted(net.places.values(), key=lambda place: str(place.path)):
        count = rng.randint(0, 3) if not heavy else rng.randint(50, 600 // len(net.places))
        if not count:
            continue
        tokens = []
        for _ in range(count):
            color = place.color if rng.random() < 0.97 else rng.choice([None, "C", "D", "E"])
            tokens.append({"color": color, "data": rng.choice(DATA)(rng)})
        entries.append({"place": str(place.path), "tokens": tokens})
    return entries


def main() -> None:
    warnings.simplefilter("ignore")
    rng = random.Random(int(sys.argv[1]))
    count = int(sys.argv[2])
    written = 0
    while written < count:
        try:
            net = generate_net(rng)
        except ValueError:
            continue
        definition = serialize_net_definition(project_net_definition(net)).decode()
        compiled = compile_net_definition(parse_net_definition(definition))
        marking = generate_marking(rng, compiled)
        max_actions = rng.choice([1, 2, 3, 8, 16, 40, 256])
        try:
            outcome = {"ok": simulate(BuiltNet(compiled), _decode_marking(marking), max_actions=max_actions).decode()}
        except SimulationProfileError as error:
            outcome = {"profile_error": str(error)}
        except Exception as error:  # noqa: BLE001 - the category is the evidence
            outcome = {"error": type(error).__name__}
        line = {"definition": definition, "marking": marking, "max_actions": max_actions, "outcome": outcome}
        print(json.dumps(line, separators=(",", ":")))
        written += 1


if __name__ == "__main__":
    main()
