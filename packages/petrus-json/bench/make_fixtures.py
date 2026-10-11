"""Write the realistic documents petrus-json's benchmarks parse and serialize.

Run once with the pinned reference, from the repository root:

    (cd upstream/petrus && "$(../../scripts/upstream-python)" -I -B ../../packages/petrus-json/bench/make_fixtures.py)

It writes ``packages/petrus-json/bench/fixtures/``, which is committed, so
both sides of the benchmark read the same bytes and neither needs the other
to run:

* ``history.jsonl``: the JSONL History (schema 5) an Instance writes while it
  drains 80 order tokens through a three-step net (``JsonlHistoryStore``,
  ``json.dumps(record, allow_nan=False)`` per line), 1 202 records with
  nested token data: names with accents and emoji, float amounts, item
  lists, an absent coupon;
* ``net-document.json``: a portable Net document v1 (``serialize_net_document``:
  ``indent=2, ensure_ascii=False, allow_nan=False``) of a 60-step pipeline
  with a view and a 20-entry execution lineage carrying token data;
* ``threads.jsonl``: the 32 largest agenticus Thread documents of
  ``packages/petrus-agenticus-core/differential/thread_corpus.json`` (each
  the ``json.dumps(thread.to_data())`` an accepted step produced), one per
  line.
"""

from __future__ import annotations

import json
import os
import random
from pathlib import Path

from petrus.impetus.history_store import JsonlHistoryStore
from petrus.impetus.instance import Instance
from petrus.impetus.net_document import (
    ExecutionLineage,
    LineageEntry,
    MarkingToken,
    PlaceMarking,
    project_net_document,
    serialize_net_document,
)
from petrus.impetus.petrinet import Arc, Marking, Net, NetPath, Place, Token, Transition

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "packages" / "petrus-json" / "bench" / "fixtures"

NAMES = ["Ana", "João", "Zoë", "Søren", "Łukasz", "Mei 美", "Olúwa", "Renée", "Ilsa 🚀", "Dmitri"]
PRODUCTS = ["coffee", "tea", "café au lait", "matcha", "chai", "cocoa"]


def order(rng: random.Random, number: int) -> dict:
    items = [
        {"sku": f"SKU-{rng.randrange(10_000):05d}", "name": rng.choice(PRODUCTS), "quantity": rng.randrange(1, 6), "price": round(rng.uniform(1, 40), 2)}
        for _ in range(rng.randrange(1, 5))
    ]
    return {
        "order": number,
        "customer": {"name": rng.choice(NAMES), "email": f"customer{number}@example.com", "vip": rng.random() < 0.2},
        "items": items,
        "total": round(sum(item["quantity"] * item["price"] for item in items), 2),
        "coupon": None,
        "notes": "deliver after 18:00 — ring twice" if rng.random() < 0.3 else "",
    }


def history(rng: random.Random) -> None:
    places = ["received", "paid", "packed", "shipped"]
    steps = ["pay", "pack", "ship"]
    net = Net(
        places=[Place(NetPath(name)) for name in places],
        transitions=[Transition(NetPath(name)) for name in steps],
        arcs=[arc for i, step in enumerate(steps) for arc in (Arc(NetPath(places[i]), NetPath(step)), Arc(NetPath(step), NetPath(places[i + 1])))],
    )
    marking = Marking({NetPath("received"): tuple(Token("Order", order(rng, n)) for n in range(80))})
    path = OUT / "history.jsonl"
    if path.exists():
        path.unlink()
    instance = Instance(net, marking, instance_id="orders-2026-10", history=JsonlHistoryStore(path))
    instance.run()


def net_document(rng: random.Random) -> None:
    count = 60
    places = [Place(NetPath(f"pipeline.stage{i:03d}.ready")) for i in range(count + 1)]
    transitions = [Transition(NetPath(f"pipeline.stage{i:03d}.work")) for i in range(count)]
    arcs = []
    for i in range(count):
        arcs.append(Arc(places[i].path, transitions[i].path))
        arcs.append(Arc(transitions[i].path, places[i + 1].path))
    net = Net(places=places, transitions=transitions, arcs=arcs)
    positions = {}
    for i, place in enumerate(places):
        positions[place.path] = (i * 140, 80 if i % 2 else 40.5)
    for i, transition in enumerate(transitions):
        positions[transition.path] = (i * 140 + 70, 60)
    entries = []
    for i in range(20):
        marking = tuple(
            PlaceMarking(
                place=str(places[(i * 4 + k) % (count + 1)].path),
                tokens=tuple(MarkingToken(color=None, data=order(rng, i * 10 + k)) for _ in range(1)),
            )
            for k in range(3)
        )
        entries.append(
            LineageEntry(
                id=i,
                parent=None if i == 0 else i - 1,
                provenance="observed" if i % 3 else "simulated",
                marking=tuple(sorted(marking, key=lambda m: m.place)),
                metadata={"note": f"step {i}", "operator": rng.choice(NAMES), "elapsed": round(rng.uniform(0, 3), 3)},
            )
        )
    document = project_net_document(net, positions, lineage=ExecutionLineage(head=19, entries=tuple(entries)))
    (OUT / "net-document.json").write_bytes(serialize_net_document(document))


def threads() -> None:
    corpus = json.loads((ROOT / "packages" / "petrus-agenticus-core" / "differential" / "thread_corpus.json").read_text())
    found = set()
    for trace in corpus["traces"]:
        for step in trace["steps"]:
            ok = step.get("result", {}).get("ok")
            if isinstance(ok, str) and '"episodes"' in ok[:200]:
                found.add(ok)
    largest = sorted(found, key=lambda text: (-len(text), text))[:32]
    (OUT / "threads.jsonl").write_text("".join(text + "\n" for text in largest), encoding="utf-8")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261011)
    history(rng)
    net_document(rng)
    threads()
    for name in sorted(os.listdir(OUT)):
        print(name, (OUT / name).stat().st_size)


main()
