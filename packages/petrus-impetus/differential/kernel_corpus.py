"""Generate the kernel differential corpus: candidates, firings, and History.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-impetus/differential/kernel_corpus.py

The script writes ``kernel_corpus.json`` next to itself (or into the directory given as its first argument). Each case is a small
random net (seeded, so the corpus is reproducible) carried as its canonical
Net definition v3, an initial marking, and a script of Instance actions —
``step``, ``deliver`` (accept then complete), ``seal``, and ``wake`` at int,
float, or absent instants, with redelivered and conflicting identities. For
every action the reference's observable answer is recorded: the candidate
bindings before it, the firing outcome or refusal, the marking, the status,
the watermark, and the pending maturation; the case ends with the complete
encoded schema-5 History. ``DifferentialSpec`` drives the Haskell Instance
through the same script and asserts every recorded value, byte for byte
where the value has a canonical spelling.

The named implementations the nets declare (``even`` filter, ``small_total``
guard, ``tag`` handler) have exact Haskell twins in ``DifferentialSpec``.
"""

from __future__ import annotations

import json
import sys
import random
import warnings
from pathlib import Path

from petrus.impetus.history.codec import encode_record
from petrus.impetus.instance import AcceptedDelivery, Instance
from petrus.impetus.net_definition import project_net_definition, serialize_net_definition
from petrus.impetus.petrinet import Arc, ArcMode, Delay, Marking, Net, NetPath, Place, Token, Transition, Until

OUTPUT_NAME = "kernel_corpus.json"
SEED = 20261010
CASES = 240
COLORS = (None, "A", "B")


def number_of(value: object) -> float | int | None:
    if isinstance(value, dict):
        n = value.get("n")
        if isinstance(n, (int, float)) and not isinstance(n, bool):
            return n
    return None


def even(token: Token) -> bool:
    n = number_of(token.data)
    return n is not None and int(n) % 2 == 0


def small_total(binding) -> bool:
    total = sum(n for n in (number_of(token.data) for token in binding.peeked) if n is not None)
    return total < 10


def tag(binding, outputs):
    """Route every forwarded token to every output arc, adding a 'seen' mark to dict data."""
    routed: dict[NetPath, tuple[Token, ...]] = {}
    for arc in outputs:
        for token in binding.tokens:
            data = dict(token.data, seen=True) if isinstance(token.data, dict) else token.data
            color = arc.color if arc.color is not None else token.color
            routed[arc.target] = routed.get(arc.target, ()) + (Token(color, data),)
    return routed


def random_data(rng: random.Random, color: str | None) -> object:
    if color is None:
        return None
    roll = rng.random()
    if roll < 0.6:
        return {"n": rng.randint(0, 9)}
    if roll < 0.8:
        return {"n": rng.randint(0, 9) + 0.5}
    return rng.choice([rng.randint(0, 9), "s", [1, 2], {"k": None}])


def random_token(rng: random.Random, color: str | None) -> Token:
    return Token(color, random_data(rng, color))


def random_net(rng: random.Random, index: int) -> Net:
    places = []
    for i in range(rng.randint(2, 5)):
        places.append(Place(NetPath(f"p{i}"), rng.choice((None, None, "A", "B"))))
    place_color = {place.path: place.color for place in places}
    transitions = []
    arcs = []
    for t in range(rng.randint(1, 4)):
        path = NetPath(f"t{t}")
        source = rng.random() < 0.25
        inputs = [] if source else rng.sample(places, rng.randint(1, min(3, len(places))))
        for place in inputs:
            mode = rng.choices((ArcMode.CONSUME, ArcMode.READ, ArcMode.INHIBIT), (8, 2, 1))[0]
            weight = 1 if mode is ArcMode.INHIBIT else rng.choices((1, 2, 3), (6, 2, 1))[0]
            color = place_color[place.path] or rng.choice(COLORS)
            arc_filter = "even" if mode is not ArcMode.INHIBIT and color is not None and rng.random() < 0.2 else None
            arcs.append(Arc(place.path, path, mode, weight, color, arc_filter))
        outputs = rng.sample(places, rng.randint(0 if not source else 1, min(2, len(places))))
        for place in outputs:
            color = place_color[place.path] or rng.choice(COLORS)
            arcs.append(Arc(path, place.path, ArcMode.CONSUME, 1, color))
        guards = ("small_total",) if not source and rng.random() < 0.2 else ()
        handler = "tag" if rng.random() < 0.15 else None
        timers = ()
        if not source and rng.random() < 0.2:
            timers = (rng.choice((Delay(rng.choice((1, 2))), Until(rng.choice((2, 3))), Delay(3))),)
        transitions.append(Transition(path, handler=handler, guards=guards, timers=timers))
    return Net(places=places, transitions=transitions, arcs=arcs, name=f"differential-{index}")


def random_marking(rng: random.Random, net: Net) -> Marking:
    # Tokens mostly carry a color some outgoing arc asks for, so that enough
    # bindings exist for the walk to fire; the rest are random strays.
    entries = {}
    for path, place in net.places.items():
        count = rng.choices((0, 1, 2, 3, 4), (2, 3, 3, 2, 1))[0]
        wanted = [arc.color for arc in net.arcs if arc.source == path]
        if count:
            entries[path] = tuple(
                random_token(
                    rng,
                    place.color
                    if place.color is not None
                    else (rng.choice(wanted) if wanted and rng.random() < 0.8 else rng.choice(COLORS)),
                )
                for _ in range(count)
            )
    return Marking(entries)


def encoded_token(value: Token) -> dict[str, object]:
    return {"color": value.color, "data": value.data}


def encoded_binding(value) -> dict[str, object]:
    return {
        "transition": str(value.transition),
        "consumed": [{"place": str(p), "tokens": [encoded_token(t) for t in ts]} for p, ts in value.consumed],
        "read": [{"place": str(p), "tokens": [encoded_token(t) for t in ts]} for p, ts in value.read],
        "delivered": [encoded_token(t) for t in value.delivered],
    }


def encoded_marking(value: Marking) -> list[dict[str, object]]:
    return [
        {"place": str(place), "tokens": [encoded_token(item) for item in tokens]}
        for place, tokens in sorted(value, key=lambda entry: str(entry[0]))
    ]


def encoded_outcome(value) -> dict[str, object]:
    return {
        "occurrence": value.occurrence,
        "transition": str(value.transition),
        "consumed": [encoded_token(item) for item in value.consumed],
        "produced": [{"place": str(place), "token": encoded_token(item)} for place, item in value.produced],
    }


def random_instant(rng: random.Random, clock: list[float]) -> int | float | None:
    roll = rng.random()
    if roll < 0.15:
        return None
    if roll < 0.25:
        return max(0, int(clock[0]) - 1)  # an earlier instant clamps to the watermark
    clock[0] += rng.choice((0, 1, 1, 2))
    if rng.random() < 0.2:
        return clock[0] + 0.5
    return int(clock[0])


def random_actions(rng: random.Random, net: Net) -> list[dict[str, object]]:
    sources = [str(path) for path in net.transitions if net.is_source(path)]
    clock = [0.0]
    identities: list[tuple[str, str, list[dict[str, object]]]] = []
    actions = []
    for _ in range(rng.randint(4, 12)):
        roll = rng.random()
        if sources and roll < 0.3:
            if identities and rng.random() < 0.25:
                identity, source, tokens = rng.choice(identities)
                if rng.random() < 0.3:
                    tokens = [encoded_token(random_token(rng, rng.choice(COLORS)))]
            else:
                identity = f"delivery-{len(identities) + 1}"
                source = rng.choice(sources)
                tokens = [encoded_token(random_token(rng, rng.choice(COLORS))) for _ in range(rng.randint(1, 2))]
                identities.append((identity, source, tokens))
            actions.append(
                {"kind": "deliver", "source": source, "tokens": tokens, "identity": identity, "at": random_instant(rng, clock)}
            )
        elif sources and roll < 0.35:
            actions.append({"kind": "seal", "source": rng.choice(sources), "at": random_instant(rng, clock)})
        elif roll < 0.45:
            clock[0] += rng.choice((1, 2))
            actions.append({"kind": "wake", "at": int(clock[0])})
        else:
            actions.append({"kind": "step", "at": random_instant(rng, clock)})
    return actions


def refusal(error: Exception) -> dict[str, object]:
    return {"error": type(error).__name__, "message": str(error)}


def answer_of(instance: Instance, action: dict[str, object]) -> dict[str, object]:
    kind = action["kind"]
    at = action["at"]
    try:
        if kind == "step":
            outcome = instance.step(at=at)
            return {"outcome": encoded_outcome(outcome) if outcome is not None else None}
        if kind == "deliver":
            tokens = tuple(Token(value["color"], value["data"]) for value in action["tokens"])
            accepted = instance.accept_delivery(action["source"], tokens, at=at, identity=action["identity"])
            if not isinstance(accepted, AcceptedDelivery):
                return {"prior": accepted.occurrence}
            return {"outcome": encoded_outcome(instance.complete_delivery(accepted, at=at))}
        if kind == "seal":
            instance.seal(action["source"], at=at)
            return {"outcome": None}
        matured = instance.wake(at)
        return {"matured": None if matured is None else encode_record(matured)}
    except (ValueError, TypeError) as error:
        return refusal(error)


def generate_case(rng: random.Random, index: int) -> dict[str, object]:
    while True:
        try:
            net = random_net(rng, index)
            marking = random_marking(rng, net)
            instance = Instance(
                net,
                marking,
                guards={"small_total": small_total},
                handlers={"tag": tag} if any(t.handler for t in net.transitions.values()) else {},
                filters={"even": even} if any(a.filter for a in net.arcs) else {},
                instance_id=f"differential-{index}",
            )
            break
        except ValueError:
            continue
    definition = serialize_net_definition(project_net_definition(net)).decode()
    actions = random_actions(rng, net)
    walk = []
    for action in actions:
        candidates = [encoded_binding(value) for value in instance.candidates()]
        answer = answer_of(instance, action)
        walk.append(
            {
                "action": action,
                "candidatesBefore": candidates,
                **answer,
                "markingAfter": encoded_marking(instance.marking),
                "statusAfter": instance.status.value,
                "watermarkAfter": instance.watermark,
                "nextMaturationAfter": instance.next_maturation,
            }
        )
    return {
        "name": f"differential-{index}",
        "definition": definition,
        "initialMarking": [
            {"place": str(place), "tokens": [encoded_token(item) for item in tokens]} for place, tokens in marking
        ],
        "walk": walk,
        "history": [encode_record(record) for record in instance.history],
    }


def main() -> None:
    warnings.simplefilter("ignore")
    rng = random.Random(SEED)
    cases = [generate_case(rng, index) for index in range(CASES)]
    corpus = {"generator": "packages/petrus-impetus/differential/kernel_corpus.py", "seed": SEED, "cases": cases}
    output = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent) / OUTPUT_NAME
    output.write_text(json.dumps(corpus, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n")
    print(f"wrote {output.name}: {len(cases)} cases")


if __name__ == "__main__":
    main()
