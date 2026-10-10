"""Generate the hand-built Net-definition / Net-document differential corpus.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python -I ../../packages/petrus-impetus/differential/hand_built_corpus.py

The script writes ``hand_built_corpus.json`` next to itself.
``HandBuiltCorpusSpec`` asserts that the Haskell port agrees on every case.

A Haskell record built with its constructor checks nothing: it is the
reference's ``Model.model_construct(...)``. The ``mk*`` functions are the
reference's validating constructors, ``Model(field=..., ...)`` with nested
models passed as already-built instances. This corpus pins both:

* ``construct``: one validating constructor call with typed arguments
  (nested models built with ``model_construct``), and the reference's
  ``ValidationError`` text or success.
* ``compile`` / ``serialize-definition``: ``compile_net_definition`` and
  ``serialize_net_definition`` of a ``model_construct``-built definition
  holding typed mutations of a valid one (one to three at a time, so the
  order of refusals is pinned too).
* ``serialize-document``: ``serialize_net_document`` of a
  ``model_construct``-built document (mutated definition, view, and
  lineage, including token data and metadata nested around Pydantic's
  serialization depth limit and CPython's recursion limit, mixed with
  other errors).
* ``project-document``: ``project_net_document(net, positions,
  lineage=...)`` with mutated positions and a ``model_construct``-built
  lineage.
* ``parse-document``: ``parse_net_document`` then ``serialize_net_document``
  of payloads with deep token data or metadata.

Every call is made as from a module's top level: the reference's recursion
limit counts Python frames, so the script raises the limit by however many
extra frames sit below its own calls.

Encoding. Model trees use the models' JSON field names. Arbitrary JSON
values (token data, metadata) are tagged: ``{"$float": "nan" | "inf" |
"-inf"}`` is a non-finite float, ``{"$nest": [n, "list" | "dict", leaf]}``
is ``leaf`` wrapped in ``n`` one-element lists (or ``{"k": ...}`` objects),
and ``{"$object": [[key, value], ...]}`` is an object with arbitrary keys;
any other value is itself. Huge integers are plain JSON integers.
"""

from __future__ import annotations

import copy
import hashlib
import json
import random
import sys
import traceback
from pathlib import Path

from petrus.impetus.net_definition import (
    AnonymousBehavior,
    ArcDefinition,
    CelBehavior,
    CelExpression,
    DelayDefinition,
    NetDefinitionBody,
    NetDefinitionV3,
    PlaceDefinition,
    SymbolBehavior,
    SymbolExpression,
    TransitionDefinition,
    UntilDefinition,
    compile_net_definition,
    project_net_definition,
    serialize_net_definition,
)
from petrus.impetus.net_document import (
    ExecutionLineage,
    LineageEntry,
    MarkingToken,
    NetDocumentV1,
    NodePosition,
    PlaceMarking,
    PortableViewV1,
    parse_net_document,
    project_net_document,
    serialize_net_document,
)
from petrus.impetus.petrinet import ANONYMOUS, Arc, ArcMode, Cel, Delay, Net, NetPath, Place, Transition, Until

OUTPUT = Path(__file__).with_name("hand_built_corpus.json")
SEED = 20261010


def top(function, *arguments):
    """``function(*arguments)`` as a module's top level would call it."""
    below = len(traceback.extract_stack())
    previous = sys.getrecursionlimit()
    sys.setrecursionlimit(1000 + below - 1)
    try:
        return function(*arguments)
    finally:
        sys.setrecursionlimit(previous)


def outcome(function, *arguments) -> dict[str, object]:
    try:
        result = top(function, *arguments)
    except Exception as error:  # noqa: BLE001 - every refusal is recorded
        return {"error": str(error)}
    if isinstance(result, bytes):
        return {"sha256": hashlib.sha256(result).hexdigest()}
    return {"ok": True}


# ---------------------------------------------------------------------------
# Tagged JSON values


def data(tagged: object) -> object:
    if isinstance(tagged, list):
        return [data(item) for item in tagged]
    if isinstance(tagged, dict):
        if len(tagged) == 1:
            ((key, value),) = tagged.items()
            if key == "$float":
                return float(value)
            if key == "$object":
                return {k: data(v) for k, v in value}
            if key == "$nest":
                depth, kind, leaf = value
                result = data(leaf)
                for _ in range(depth):
                    result = [result] if kind == "list" else {"k": result}
                return result
        return {key: data(value) for key, value in tagged.items()}
    return tagged


def nest(depth: int, kind: str = "list", leaf: object = 1) -> dict[str, object]:
    return {"$nest": [depth, kind, leaf]}


# ---------------------------------------------------------------------------
# Building models without validation


def pure(tree):
    if tree is None:
        return None
    if tree["kind"] == "symbol":
        return SymbolExpression.model_construct(kind="symbol", name=tree["name"])
    return CelExpression.model_construct(kind="cel", expression=tree["expression"])


def behavior(tree):
    if tree is None:
        return None
    if tree["kind"] == "symbol":
        return SymbolBehavior.model_construct(kind="symbol", name=tree["name"], uri=tree["uri"])
    if tree["kind"] == "cel":
        return CelBehavior.model_construct(kind="cel", expression=tree["expression"], uri=tree["uri"])
    return AnonymousBehavior.model_construct(kind="anonymous", uri=tree["uri"])


def timer(tree):
    if tree["kind"] == "delay":
        return DelayDefinition.model_construct(kind="delay", duration=tree["duration"])
    return UntilDefinition.model_construct(kind="until", instant=tree["instant"])


def place(tree):
    return PlaceDefinition.model_construct(path=tree["path"], color=tree["color"])


def transition(tree):
    return TransitionDefinition.model_construct(
        path=tree["path"],
        handler=behavior(tree["handler"]),
        guards=tuple(behavior(g) for g in tree["guards"]),
        timers=tuple(timer(t) for t in tree["timers"]),
    )


def arc(tree):
    return ArcDefinition.model_construct(
        position=tree["position"],
        source=tree["source"],
        target=tree["target"],
        mode=tree["mode"],
        weight=tree["weight"],
        color=tree["color"],
        filter=pure(tree["filter"]),
    )


def body(tree):
    return NetDefinitionBody.model_construct(
        name=tree["name"],
        time_domain="integer",
        places=tuple(place(p) for p in tree["places"]),
        transitions=tuple(transition(t) for t in tree["transitions"]),
        arcs=tuple(arc(a) for a in tree["arcs"]),
        completion=pure(tree["completion"]),
    )


def definition(tree):
    return NetDefinitionV3.model_construct(format="petrus-net-definition", version=3, definition=body(tree["definition"]))


def node(tree):
    return NodePosition.model_construct(node=tree["node"], x=data(tree["x"]), y=data(tree["y"]))


def view(tree):
    if tree is None:
        return None
    return PortableViewV1.model_construct(version=1, nodes=tuple(node(n) for n in tree["nodes"]))


def token(tree):
    return MarkingToken.model_construct(color=tree["color"], data=data(tree["data"]))


def marking(tree):
    return PlaceMarking.model_construct(place=tree["place"], tokens=tuple(token(t) for t in tree["tokens"]))


def entry(tree):
    return LineageEntry.model_construct(
        id=tree["id"],
        parent=tree["parent"],
        provenance=tree["provenance"],
        marking=tuple(marking(m) for m in tree["marking"]),
        metadata=data({"$object": [[k, v] for k, v in tree["metadata"].items()]}),
    )


def lineage(tree):
    if tree is None:
        return None
    return ExecutionLineage.model_construct(head=tree["head"], entries=tuple(entry(e) for e in tree["entries"]))


def document(tree):
    return NetDocumentV1.model_construct(
        format="petrus-net-document",
        version=1,
        definition=definition(tree["definition"]),
        view=view(tree["view"]),
        lineage=lineage(tree["lineage"]),
    )


# ---------------------------------------------------------------------------
# Bases


def base_net() -> Net:
    source, pending, context, blocked, done, review = map(
        NetPath, ("source", "review.pending", "review.context", "review.blocked", "review.done", "review.run")
    )
    return Net(
        places=(Place(pending, "Work"), Place(context, "Context"), Place(blocked, "Block"), Place(done, "Done")),
        transitions=(
            Transition(source, handler="emit"),
            Transition(
                review,
                handler=ANONYMOUS,
                guards=("ready", Cel("size(review.pending) > 0"), ANONYMOUS),
                timers=(Delay(3), Until(11)),
            ),
        ),
        arcs=(
            Arc(source, pending),
            Arc(pending, review, filter=Cel("priority >= 1")),
            Arc(context, review, ArcMode.READ, filter="visible"),
            Arc(blocked, review, ArcMode.INHIBIT),
            Arc(review, done, weight=2),
        ),
        completion=Cel("size(review.done) > 0"),
        name="portable-review",
    )


NET = base_net()
DEFINITION = project_net_definition(NET).model_dump(mode="json")
LINEAGE = {
    "head": 1,
    "entries": [
        {
            "id": 0,
            "parent": None,
            "provenance": "observed",
            "marking": [
                {"place": "review.context", "tokens": [{"color": "Context", "data": {"n": 1}}]},
                {"place": "review.pending", "tokens": [{"color": "Work", "data": [1, "two", 3.5]}, {"color": "Work", "data": None}]},
            ],
            "metadata": {"instance": "i-1", "values": [True, None, 2.5, -3]},
        },
        {
            "id": 1,
            "parent": 0,
            "provenance": "simulated",
            "marking": [{"place": "review.done", "tokens": [{"color": "Done", "data": "ok"}]}],
            "metadata": {},
        },
        {"id": 2, "parent": 0, "provenance": "manual", "marking": [], "metadata": {"note": "empty"}},
    ],
}
VIEW = {"nodes": [{"node": "review.pending", "x": 0, "y": 1.5}, {"node": "review.run", "x": -20.25, "y": 40}]}
DOCUMENT = {"definition": DEFINITION, "view": VIEW, "lineage": LINEAGE}
PROJECTION = {"view": VIEW, "lineage": LINEAGE}


# ---------------------------------------------------------------------------
# Typed mutations: every leaf keeps its Haskell type.

BIG = [-1, 0, 2**53 - 1, 2**53, -(2**53) + 1, -(2**53), 2**63, 2**70]
PATHS = ["", "a..b", ".a", "a.", "zz", "review.zz", " review.run", "Ünï", "review.run.x"]
NAMES = ["", "$x", "$", "x", "other"]
CELS = ["", "size(", "1 +", "true"]
COLORS = [None, "", "Other", "Work"]


def string_options(path: tuple, value: str) -> list[object]:
    field = path[-1]
    if field in ("path", "source", "target", "place", "node"):
        return PATHS + [value + ".x"]
    if field == "name" and len(path) > 1 and path[-2] != "definition":
        return NAMES
    if field == "expression":
        return CELS
    if field == "uri":
        return ["", "x", value + "x", "petrus:other"]
    if field == "mode":
        return ["consume", "read", "inhibit"]
    if field == "provenance":
        return ["observed", "simulated", "manual"]
    if field in ("color", "name"):
        return [None, "", "Other", "Work", "Ünï"]
    return ["", "x"]


def int_options(path: tuple, value: int) -> list[object]:
    field = path[-1]
    out = list(BIG) + [value + 1, value - 1]
    if field == "parent":
        out.append(None)
    return out


def leaves(value: object, prefix: tuple = ()) -> list[tuple]:
    found = [prefix]
    if isinstance(value, dict) and not (len(value) == 1 and next(iter(value)).startswith("$")):
        for key, item in value.items():
            found.extend(leaves(item, (*prefix, key)))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(leaves(item, (*prefix, index)))
    return found


def get(value: object, path: tuple) -> object:
    for step in path:
        value = value[step]  # type: ignore[index]
    return value


def set_at(value: object, path: tuple, new: object) -> object:
    if not path:
        return new
    get(value, path[:-1])[path[-1]] = new  # type: ignore[index]
    return value


def in_data(path: tuple) -> bool:
    return "data" in path or "metadata" in path or path[-1:] in (("x",), ("y",))


def options(tree: object, path: tuple) -> list[object]:
    """The typed replacement values for one position."""
    if not path or path[-1] in ("format", "version", "time_domain", "kind"):
        return []
    value = get(tree, path)
    field = path[-1]
    out: list[object] = []
    if in_data(path) and field not in ("metadata",):
        if field in ("x", "y"):
            return [0, -0.0, 1.5, 2**70, 10**400, {"$float": "nan"}, {"$float": "inf"}, {"$float": "-inf"}, 1e308]
        return [None, 2**53, -(2**53), 2**53 - 1, 1.5, 9007199254740992.0, {"$float": "nan"}, {"$float": "inf"}, nest(300), nest(260, "dict", "s"), "x"]
    if field == "metadata":
        return [{}, {"deep": nest(255)}, {"deep": nest(256)}, {"deep": nest(300, "dict", None)}, {"bad": {"$float": "nan"}}, {"big": 2**60}, {"deep": nest(498)}, {"deep": nest(499)}, {"deep": nest(500, "dict", 1)}]
    if isinstance(value, bool):
        return []
    if isinstance(value, int):
        return int_options(path, value)
    if isinstance(value, str):
        out = [o for o in string_options(path, value) if o != value]
        return out
    if value is None:
        if field == "color":
            return ["", "Work", "Other"]
        if field == "name":
            return ["", "x"]
        if field == "parent":
            return [0, 5, -1]
        if field in ("handler", "filter", "completion"):
            return [{"kind": "symbol", "name": n} for n in ("ok", "", "$x")] + [{"kind": "cel", "expression": e} for e in ("", "size(", "1 > 0")]
        return []
    if isinstance(value, list):
        if not value:
            return []
        return [list(reversed(value)), [copy.deepcopy(value[0]), *value], value[1:], []]
    if isinstance(value, dict) and field in ("handler", "filter", "completion"):
        return [None]
    if isinstance(value, dict) and field in ("view", "lineage"):
        return [None]
    return out


def edited(base: object, edits: list[list[object]]) -> object:
    """``base`` with each ``[path, value]`` edit applied in order."""
    tree = copy.deepcopy(base)
    for path, value in edits:
        tree = set_at(tree, tuple(path), copy.deepcopy(value))  # type: ignore[arg-type]
    return tree


def mutate(base: object, rng: random.Random, count: int) -> tuple[object, list[list[object]]]:
    """A typed mutation of ``base``, and its edits."""
    tree = copy.deepcopy(base)
    edits: list[list[object]] = []
    for _ in range(count):
        candidates = [p for p in leaves(tree) if options(tree, p)]
        if not candidates:
            break
        path = rng.choice(candidates)
        new = copy.deepcopy(rng.choice(options(tree, path)))
        # A handler or guard needs a uri; a filter or completion has none.
        if isinstance(new, dict) and path[-1] == "handler" and "uri" not in new:
            if new["kind"] == "cel":
                new = {"kind": "anonymous", "uri": "petrus:x"}
            else:
                new = {**new, "uri": "petrus:x"}
        tree = set_at(tree, path, new)
        edits.append([list(path), new])
    return tree, edits


# ---------------------------------------------------------------------------
# Validating constructors


def construct_cases(rng: random.Random) -> list[dict[str, object]]:
    sample_place = DEFINITION["definition"]["places"][0]
    sample_transition = DEFINITION["definition"]["transitions"][1]
    sample_arc = DEFINITION["definition"]["arcs"][1]
    sample_entry = LINEAGE["entries"][0]
    sample_marking = sample_entry["marking"][1]
    cases: list[dict[str, object]] = []

    def add(model: str, args: dict[str, object]) -> None:
        cases.append({"model": model, "args": args})

    for n in ["ok", "", "$x", "$", "a b", "Ünï"]:
        add("SymbolExpression", {"name": n})
        add("SymbolBehavior", {"name": n, "uri": "petrus:t"})
    for e in ["", "x > 1", "size("]:
        add("CelExpression", {"expression": e})
        add("CelBehavior", {"expression": e, "uri": ""})
    for i in BIG + [5]:
        add("DelayDefinition", {"duration": i})
        add("UntilDefinition", {"instant": -i})
    for p in PATHS + ["review.run"]:
        for c in [None, "", "Work"]:
            add("PlaceDefinition", {"path": p, "color": c})
    for p in PATHS + ["review.run"]:
        add("TransitionDefinition", {**sample_transition, "path": p})
    add("TransitionDefinition", {**sample_transition, "handler": None, "guards": [], "timers": []})
    add(
        "TransitionDefinition",
        {**sample_transition, "guards": [{"kind": "symbol", "name": "", "uri": ""}], "timers": [{"kind": "delay", "duration": -(2**60)}]},
    )
    for _ in range(80):
        args = dict(sample_arc)
        for _ in range(rng.randint(1, 4)):
            key = rng.choice(["position", "source", "target", "mode", "weight", "color", "filter"])
            if key in ("position", "weight"):
                args[key] = rng.choice(BIG + [1, 3])
            elif key in ("source", "target"):
                args[key] = rng.choice(PATHS + ["review.run"])
            elif key == "mode":
                args[key] = rng.choice(["consume", "read", "inhibit"])
            elif key == "color":
                args[key] = rng.choice(COLORS)
            else:
                args[key] = rng.choice([None, {"kind": "symbol", "name": ""}, {"kind": "cel", "expression": ""}])
        add("ArcDefinition", args)
    for _ in range(60):
        tree, _ = mutate(DEFINITION["definition"], rng, rng.randint(1, 3))
        add("NetDefinitionBody", {key: tree[key] for key in ("name", "places", "transitions", "arcs", "completion")})
    for p in PATHS + ["review.run"]:
        for x, y in [(0, 1.5), ({"$float": "nan"}, 1), (1, {"$float": "-inf"}), (10**400, 2**70), (1e308, -0.0)]:
            add("NodePosition", {"node": p, "x": x, "y": y})
    for nodes in [VIEW["nodes"], list(reversed(VIEW["nodes"])), VIEW["nodes"] * 2, [], [{"node": "", "x": 0, "y": 0}]]:
        add("PortableViewV1", {"nodes": nodes})
    tagged = [None, 1, 2**53, -(2**53) + 1, 1.5, 9007199254740992.0, -9007199254740992.0, {"$float": "nan"}, {"$float": "inf"}, "s", [1, [2, {"a": None}]], {"$object": [["", 1], ["b", [{"$float": "-inf"}]]]}]
    tagged += [nest(n, kind, leaf) for n in (495, 496, 497, 498, 499, 500, 501) for kind in ("list", "dict") for leaf in (1, "s", None)]
    for value in tagged:
        for c in [None, "", "Work"]:
            add("MarkingToken", {"color": c, "data": value})
    for p in PATHS + ["review.pending"]:
        add("PlaceMarking", {"place": p, "tokens": sample_marking["tokens"]})
    add("PlaceMarking", {"place": "x", "tokens": []})
    metadata = [{}, {"a": 1}, {"bad": {"$float": "nan"}}, {"big": 2**53}, {"deep": nest(255)}, {"deep": nest(300)}]
    metadata += [{"deep": nest(n, kind, leaf)} for n in (494, 495, 496, 497, 498, 499) for kind in ("list", "dict") for leaf in (1, None)]
    for _ in range(70):
        identifier = rng.choice(BIG + [0, 1])
        parent = rng.choice([None, 0, -1, 2**53])
        meta = rng.choice(metadata)
        add(
            "LineageEntry",
            {"id": identifier, "parent": parent, "provenance": rng.choice(["observed", "manual"]), "marking": sample_entry["marking"], "metadata": meta},
        )
    for meta in metadata:
        add("LineageEntry", {**sample_entry, "metadata": meta})
        add("LineageEntry", {**sample_entry, "id": -1, "parent": -2, "metadata": meta})
    for h in BIG + [1]:
        add("ExecutionLineage", {"head": h, "entries": LINEAGE["entries"]})
    return cases


def build_argument(model: str, key: str, value: object) -> object:
    """The keyword argument as the constructor receives it."""
    if key in ("data", "x", "y"):
        return data(value)
    if key == "metadata":
        return data({"$object": [[k, v] for k, v in value.items()]})  # type: ignore[union-attr]
    if key in ("filter", "completion"):
        return pure(value)
    if key == "handler":
        return behavior(value)
    if key == "guards":
        return tuple(behavior(g) for g in value)  # type: ignore[union-attr]
    if key == "timers":
        return tuple(timer(t) for t in value)  # type: ignore[union-attr]
    if key == "places":
        return tuple(place(p) for p in value)  # type: ignore[union-attr]
    if key == "transitions":
        return tuple(transition(t) for t in value)  # type: ignore[union-attr]
    if key == "arcs":
        return tuple(arc(a) for a in value)  # type: ignore[union-attr]
    if key == "nodes":
        return tuple(node(n) for n in value)  # type: ignore[union-attr]
    if key == "tokens":
        return tuple(token(t) for t in value)  # type: ignore[union-attr]
    if key == "marking":
        return tuple(marking(m) for m in value)  # type: ignore[union-attr]
    if key == "entries":
        return tuple(entry(e) for e in value)  # type: ignore[union-attr]
    return value


MODELS = {
    "SymbolExpression": (SymbolExpression, {"kind": "symbol"}),
    "CelExpression": (CelExpression, {"kind": "cel"}),
    "SymbolBehavior": (SymbolBehavior, {"kind": "symbol"}),
    "CelBehavior": (CelBehavior, {"kind": "cel"}),
    "DelayDefinition": (DelayDefinition, {"kind": "delay"}),
    "UntilDefinition": (UntilDefinition, {"kind": "until"}),
    "PlaceDefinition": (PlaceDefinition, {}),
    "TransitionDefinition": (TransitionDefinition, {}),
    "ArcDefinition": (ArcDefinition, {}),
    "NetDefinitionBody": (NetDefinitionBody, {}),
    "NodePosition": (NodePosition, {}),
    "PortableViewV1": (PortableViewV1, {"version": 1}),
    "MarkingToken": (MarkingToken, {}),
    "PlaceMarking": (PlaceMarking, {}),
    "LineageEntry": (LineageEntry, {}),
    "ExecutionLineage": (ExecutionLineage, {}),
}


# ---------------------------------------------------------------------------
# Corpus


CASES: list[dict[str, object]] = []


def add_case(case: dict[str, object], result: dict[str, object]) -> None:
    CASES.append({**case, **result})


def main() -> None:
    rng = random.Random(SEED)

    for case in construct_cases(rng):
        add_case({"op": "construct", **case}, call_constructor_top(case))

    # Definitions: compile, then serialize, each from scratch.
    definitions: list[list[list[object]]] = [[]]
    for _ in range(420):
        definitions.append(mutate(DEFINITION, rng, rng.choice((1, 1, 2, 3)))[1])
    for edits in definitions:
        tree = edited(DEFINITION, edits)
        add_case(
            {"op": "definition", "edits": edits},
            {"compile": outcome(compile_net_definition, definition(tree)), "serialize": outcome(serialize_net_definition, definition(tree))},
        )

    # Documents: serialize.
    bare = [[["view"], None], [["lineage"], None]]
    documents: list[list[list[object]]] = [[], bare]
    for _ in range(520):
        documents.append(mutate(DOCUMENT, rng, rng.choice((1, 1, 2, 3)))[1])
    for n in (254, 255, 256, 257, 300, 480, 490, 494, 495, 496, 497, 498, 499, 500):
        for kind in ("list", "dict"):
            for leaf in (1, None):
                for where in (["lineage", "entries", 1, "marking", 0, "tokens", 0, "data"], ["lineage", "entries", 2, "metadata", "deep"]):
                    deep = [[where, nest(n, kind, leaf)]]
                    documents.append(deep)
                    documents.append(deep + mutate(edited(DOCUMENT, deep), rng, 2)[1])
    for edits in documents:
        add_case({"op": "serialize-document", "edits": edits}, outcome(serialize_net_document, document(edited(DOCUMENT, edits))))

    # Projections: the base net with mutated positions and lineage.
    for _ in range(220):
        tree, edits = mutate(PROJECTION, rng, rng.choice((1, 1, 2, 3)))
        positions = None
        if tree["view"] is not None:
            # Positions are a mapping: the last spelling of a node wins.
            positions = {n["node"]: (data(n["x"]), data(n["y"])) for n in tree["view"]["nodes"]}
        add_case({"op": "project-document", "edits": edits}, outcome(project, positions, lineage(tree["lineage"])))

    # Parsing: deep token data and metadata, then serializing the result.
    for n in (254, 255, 256, 257, 300, 450):
        for kind in ("list", "dict"):
            for where in (["lineage", "entries", 1, "marking", 0, "tokens", 0, "data"], ["lineage", "entries", 2, "metadata", "deep"]):
                edits = [[where, nest(n, kind, 1)]]
                payload = json.dumps(wire(edited(DOCUMENT, edits)), ensure_ascii=False).encode()
                parsed = outcome(parse_net_document, payload)
                result: dict[str, object] = {"parse": parsed}
                if "error" not in parsed:
                    result["serialize"] = outcome(serialize_net_document, top(parse_net_document, payload))
                add_case({"op": "parse-document", "edits": edits}, result)

    corpus = {
        "generator": "packages/petrus-impetus/differential/hand_built_corpus.py",
        "seed": SEED,
        "definition": DEFINITION,
        "document": DOCUMENT,
        "projection": PROJECTION,
        "cases": CASES,
    }
    head = json.dumps({key: corpus[key] for key in ("generator", "seed", "definition", "document", "projection")}, ensure_ascii=False)
    lines = ",\n".join(json.dumps(case, ensure_ascii=False) for case in CASES)
    OUTPUT.write_text(head[:-1] + ', "cases": [\n' + lines + "\n]}\n", encoding="utf-8")
    digest = hashlib.sha256(OUTPUT.read_bytes()).hexdigest()
    counts: dict[str, int] = {}
    for case in CASES:
        counts[str(case["op"])] = counts.get(str(case["op"]), 0) + 1
    print(f"{len(CASES)} cases {counts}, {OUTPUT.stat().st_size} bytes, sha256 {digest}")


def project(positions, built_lineage):
    return project_net_document(NET, positions, lineage=built_lineage)


def call_constructor_top(case: dict[str, object]) -> dict[str, object]:
    model, fixed = MODELS[str(case["model"])]
    arguments = dict(fixed)
    args = case["args"]
    assert isinstance(args, dict)
    for key, value in args.items():
        if model is NetDefinitionBody and key == "places":
            arguments["time_domain"] = "integer"
        arguments[key] = build_argument(str(case["model"]), key, value)
    try:
        below = len(traceback.extract_stack())
        previous = sys.getrecursionlimit()
        # ``model(**arguments)`` runs ``BaseModel.__init__`` one frame
        # below this one, as a top-level call runs it at frame 2.
        sys.setrecursionlimit(1000 + below - 1)
        try:
            model(**arguments)
        finally:
            sys.setrecursionlimit(previous)
    except Exception as error:  # noqa: BLE001 - every refusal is recorded
        return {"error": str(error)}
    return {"ok": True}


def wire(tree: dict) -> dict:
    """The JSON payload of a document tree (tagged values resolved)."""
    out = copy.deepcopy(tree)
    out = {"format": "petrus-net-document", "version": 1, **out}
    out["view"] = {"version": 1, **out["view"]}
    for e in out["lineage"]["entries"]:
        e["metadata"] = data({"$object": [[k, v] for k, v in e["metadata"].items()]})
        for m in e["marking"]:
            for t in m["tokens"]:
                t["data"] = data(t["data"])
    return out


if __name__ == "__main__":
    main()
