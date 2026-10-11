"""Generate the Net-definition / Net-document differential corpus.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-impetus/differential/net_definition_corpus.py

The script writes ``net_definition_corpus.json`` next to itself (or into the directory given as its first argument). Each case is
one payload handed to ``parse_net_definition`` or ``parse_net_document`` and
the reference's verdict: the canonical serialization of the admitted
document (plus, for documents, the definition identity) or the exact refusal
message. ``NetDefinitionCorpusSpec`` asserts that the Haskell port agrees on
every case.

The payloads are the spec fixtures, systematic structural mutations of a
small feature-complete definition and document (every member removed,
retyped, emptied, or made noncanonical; every list reordered, duplicated, or
truncated; extra members everywhere), byte-level fuzz of the canonical
fixture (deterministic seed), JSON syntax edge cases, malformed UTF-8, and
nesting at the reference's recursion limit.

The reference's recursion limit counts Python frames, so a verdict depends
on how deep the caller already is. The Haskell port fixes the depth of a
top-level call (the module frame plus the parser's frame); this script
raises the recursion limit by however many extra frames sit below its own
calls, so the recorded verdicts are those of a top-level call.
"""

from __future__ import annotations

import base64
import copy
import glob
import hashlib
import json
import random
import sys
import traceback
from pathlib import Path

from petrus.impetus.net_definition import parse_net_definition, project_net_definition, serialize_net_definition
from petrus.impetus.net_document import (
    ExecutionLineage,
    LineageEntry,
    MarkingToken,
    PlaceMarking,
    definition_identity,
    parse_net_document,
    project_net_document,
    serialize_net_document,
)
from petrus.impetus.petrinet import ANONYMOUS, Arc, ArcMode, Cel, Delay, Net, NetPath, Place, Transition, Until

OUTPUT_NAME = "net_definition_corpus.json"
SEED = 20260913


def verdict(kind: str, payload: bytes) -> dict[str, object]:
    """The reference's verdict, as a top-level call would see it."""
    below = len(traceback.extract_stack())
    previous = sys.getrecursionlimit()
    sys.setrecursionlimit(1000 + below - 1)
    try:
        if kind == "definition":
            document = parse_net_definition(payload)
            return {"canonical": serialize_net_definition(document).decode()}
        document = parse_net_document(payload)
        return {"canonical": serialize_net_document(document).decode(), "identity": definition_identity(document)}
    except Exception as error:  # noqa: BLE001 - every refusal is recorded
        return {"error": str(error)}
    finally:
        sys.setrecursionlimit(previous)


CASES: list[dict[str, object]] = []
SEEN: set[tuple[str, bytes]] = set()
BASES: dict[str, str] = {}


def add(kind: str, name: str, payload: bytes, spelling: dict[str, object] | None = None, full: bool = True) -> None:
    """Record one case. ``spelling`` says how to rebuild the payload from a
    base (to keep the corpus small); otherwise the payload is stored. A
    ``full`` verdict stores the canonical bytes, otherwise their SHA-256."""
    if (kind, payload) in SEEN:
        return
    SEEN.add((kind, payload))
    case: dict[str, object] = {"name": name, "kind": kind}
    if spelling is not None:
        case.update(spelling)
    else:
        try:
            case["text"] = payload.decode("utf-8")
        except UnicodeDecodeError:
            case["base64"] = base64.b64encode(payload).decode()
    result = verdict(kind, payload)
    if "canonical" in result and not full:
        result["canonical_sha256"] = hashlib.sha256(str(result.pop("canonical")).encode()).hexdigest()
    case.update(result)
    CASES.append(case)


def compact(value: object) -> bytes:
    """``json.dumps(value, ensure_ascii=False, separators=(",", ":"))``."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def repeated(prefix: bytes, unit: bytes, n: int, middle: bytes, closing: bytes, suffix: bytes) -> tuple[bytes, dict]:
    payload = prefix + unit * n + middle + closing * n + suffix
    spelling = {
        "repeat": {
            "prefix": prefix.decode(),
            "unit": unit.decode(),
            "n": n,
            "middle": middle.decode(),
            "closing": closing.decode(),
            "suffix": suffix.decode(),
        }
    }
    return payload, spelling


# ---------------------------------------------------------------------------
# Bases


def rich_net() -> Net:
    source, pending, context, blocked, done, review = map(
        NetPath, ("source", "review.pending", "review.context", "review.blocked", "review.done", "review.run")
    )
    return Net(
        places=(Place(pending, "Work"), Place(context, "Context"), Place(blocked, "Block"), Place(done, "Done")),
        transitions=(
            Transition(source),
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
            Arc(review, done),
        ),
        completion=Cel("size(review.done) > 0"),
        name="portable-review",
    )


def small_document() -> dict[str, object]:
    pending, done, work = map(NetPath, ("pending", "done", "work"))
    net = Net(
        places=(Place(pending, "Work"), Place(done, "Work")),
        transitions=(Transition(work, handler="worker"),),
        arcs=(Arc(pending, work), Arc(work, done)),
        name="small",
    )
    lineage = ExecutionLineage(
        head=1,
        entries=(
            LineageEntry(
                id=0,
                parent=None,
                provenance="observed",
                marking=(PlaceMarking(place="pending", tokens=(MarkingToken(color="Work", data={"n": 1}),)),),
                metadata={"instance": "i-1", "values": [True, None, 2.5, -3]},
            ),
            LineageEntry(
                id=1,
                parent=0,
                provenance="simulated",
                marking=(PlaceMarking(place="done", tokens=(MarkingToken(color="Work", data=[1, "two", 3.0]),)),),
                metadata={},
            ),
            LineageEntry(id=2, parent=0, provenance="manual", marking=(), metadata={"note": "empty"}),
        ),
    )
    document = project_net_document(net, {"pending": (0, 1.5), "work": (-20.25, 40)}, lineage=lineage)
    return json.loads(serialize_net_document(document))


# ---------------------------------------------------------------------------
# Structural mutations
#
# A mutation is stored as an operation on a named base value; the payload is
# the compact spelling of the mutated value. Operations: ``delete`` a member
# or item, ``replace`` it with ``value``, add an ``extra`` member
# (``"extra": [1, {"x": null}]``) at the end of an object, or ``reverse``,
# ``duplicate_first``, ``drop_first``, or ``empty`` a list.


EXTRA = [1, {"x": None}]


def paths(value: object, prefix: tuple = ()) -> list[tuple]:
    found = [prefix]
    if isinstance(value, dict):
        for key, item in value.items():
            found.extend(paths(item, (*prefix, key)))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(paths(item, (*prefix, index)))
    return found


def get(value: object, path: tuple) -> object:
    for step in path:
        value = value[step]  # type: ignore[index]
    return value


def apply(base: object, op: str, path: tuple, value: object = None) -> object:
    result = copy.deepcopy(base)
    if op == "delete":
        del get(result, path[:-1])[path[-1]]  # type: ignore[arg-type]
        return result
    original = get(result, path)
    if op == "replace":
        new = value
    elif op == "extra":
        new = dict(original)  # type: ignore[call-overload]
        new["extra"] = copy.deepcopy(EXTRA)
    elif op == "reverse":
        new = list(reversed(original))  # type: ignore[call-overload]
    elif op == "duplicate_first":
        new = [copy.deepcopy(original[0]), *original]  # type: ignore[index]
    elif op == "drop_first":
        new = original[1:]  # type: ignore[index]
    elif op == "empty":
        new = []
    else:
        raise ValueError(op)
    if not path:
        return new
    get(result, path[:-1])[path[-1]] = new  # type: ignore[index]
    return result


def replacements(original: object, documents: bool) -> list[object]:
    if isinstance(original, bool):
        options: list[object] = [None, 1, "true"]
    elif isinstance(original, int):
        options = [None, True, -1, 0, original + 1, 2**53 - 1, -(2**53) + 1, "1"]
        if documents:
            options += [float(original), 2**53]
    elif isinstance(original, float):
        options = [None, True, "1.5", 1, float("inf"), 1e300, 2.0**60]
    elif isinstance(original, str):
        options = [None, 7, "", "a..b", "$x", "x", original + ".x", "Ünï😀", "", "it's"]
    elif original is None:
        options = ["", "x", 1, {}, [], {"kind": "symbol"}]
    elif isinstance(original, dict):
        options = [None, [], "x", {}, {"kind": "nope"}, {"kind": 5}]
    else:
        options = [None, {}, "x", 3]
    return options


def mutations(base: object, documents: bool) -> list[tuple[str, dict[str, object]]]:
    out: list[tuple[str, dict[str, object]]] = []
    for path in paths(base):
        label = "/".join(map(str, path)) or "<root>"
        original = get(base, path)
        steps = list(path)
        if path and isinstance(get(base, path[:-1]), dict):
            out.append((f"delete {label}", {"op": "delete", "path": steps}))
        for new in replacements(original, documents):
            out.append((f"replace {label} with {new!r}", {"op": "replace", "path": steps, "value": new}))
        if isinstance(original, dict):
            out.append((f"extra member in {label}", {"op": "extra", "path": steps}))
        if isinstance(original, list) and original:
            for op in ("reverse", "duplicate_first", "drop_first", "empty"):
                out.append((f"{op} {label}", {"op": op, "path": steps}))
    return out


def add_mutations(kind: str, base_name: str, base: object, count: int, rng: random.Random) -> None:
    candidates = mutations(base, documents=kind == "document")
    rng.shuffle(candidates)
    for name, mutation in candidates[:count]:
        value = apply(base, str(mutation["op"]), tuple(mutation["path"]), mutation.get("value"))  # type: ignore[arg-type]
        add(kind, f"{base_name}: {name}", compact(value), {"mutation": {"base": base_name, **mutation}}, full=False)


# ---------------------------------------------------------------------------
# Byte-level fuzz
#
# A fuzz case is stored as its base and a list of byte edits
# ``[position, "insert" | "delete" | "replace", byte]`` applied in order to
# the base's UTF-8 bytes.

FUZZ_ALPHABET = b'{}[]",:0123456789-+.eE \n\t\\/ubfnrtaNIl\xc3\xa9\xff\x00'


def fuzzed(payload: bytes, rng: random.Random) -> tuple[bytes, list[list[object]]]:
    data = bytearray(payload)
    edits: list[list[object]] = []
    for _ in range(rng.randint(1, 3)):
        position = rng.randrange(len(data) + 1)
        action = rng.choice(("insert", "delete", "replace"))
        byte = rng.choice(FUZZ_ALPHABET)
        if action == "insert" or position >= len(data):
            data.insert(position, byte)
            edits.append([position, "insert", byte])
        elif action == "delete":
            del data[position]
            edits.append([position, "delete", 0])
        else:
            data[position] = byte
            edits.append([position, "replace", byte])
    return bytes(data), edits


def add_fuzz(kind: str, base_name: str, count: int, rng: random.Random) -> None:
    base = BASES[base_name].encode()
    for index in range(count):
        payload, edits = fuzzed(base, rng)
        add(kind, f"{base_name}: fuzz {index}", payload, {"fuzz": {"base": base_name, "edits": edits}}, full=False)


SYNTAX = [
    b"", b" ", b"{", b"[", b'{"a"', b'{"a":', b'{"a": }', b'{"a":1,}', b"[1,]", b"[1 2]", b'{"a" 1}', b"{1:2}",
    b'"abc', b'"a\\x"', b'"\\u12"', b'"\\u12', b'"\\u1234', b'"\\u123g"', b'"\\ud800\\u12"', b'"\\ud800\\udc0"',
    b'"\\ud800\\ud800"', b'"\\ud83d\\ude00"', b'"a\nb"', b'"a\x7f"', b"1 2", b"01", b"-", b"-a", b"1.", b"1e", b"1e+",
    b".5", b"NaN", b"Infinity", b"-Infinity", b"nul", b"tru", b"\xef\xbb\xbf{}", b'{"a":1}\n\nx', b"\n\n  [1,\n 2,, 3]",
    b"[1]  ", b'{"a":[1,{"b":2,"b":3}],"a":1.5}', b'{"a":1,"a":2,"c":1.5}', b'{"a":1,"a":2', b"[" * 10 + b"1.5e",
    b'"\\', b'"\\u"', b'"\xc3\xa9\\q"', b'["\xc3\xa9", nul]', b"\xc3", b"a\xe2\x82", b"\xe0\x80\x80", b"\xed\xa0\x80",
    b"\xf4\x90\x80\x80", b"ab\xf0\x9f\x98", b"\xf0\x9f\x98x", b"\xc0\xaf", b"\x80", b"\xf0\x80", b"\xf0\x90",
    b"\xf0\x90\x41", b"\xe0\xa0", b"\xed\xbf", b'{"a":"\\ud800"}', b'{"\\udc00":1}', b'{"\\udc00":1,"\\udc00":2}',
    b'{"version":3.0}', b'{"version":3e0}', b'{"version":9007199254740992}', b'{"version":-9007199254740992}',
    b'{"format":"x","version":1,"definition":{}}', b'{"definition":-0}', b"[1e400]", b"[-1e400]", b"[1e-400]",
    b"[9007199254740992.0]", b"[0.1e1]", b'{"a":2.5e15}', b"\t[\r\n]", b'"\x1f"', b'"\\/\\b\\f\\n\\r\\t\\"\\\\"', b"{}",
    b"[]", b"null", b"true", b'"x"', b"7", b'"\\u00e9\\u0000"', b'{"a":"\\ud800","a":1}', b'["\\udfff", 1.5]',
    b'{"view":null}', b'{"lineage":null,"view":null}', b'{"view":{}}',
]


def repeats() -> list[tuple[bytes, dict]]:
    """Huge integers and nesting on both sides of each parser's recursion
    limit, stored as repetitions."""
    out = [
        repeated(b"", b"1", 4300, b"", b"", b""),
        repeated(b"", b"1", 4301, b"", b"", b""),
        repeated(b"-", b"1", 4301, b"", b"", b""),
        repeated(b"[", b"1", 4301, b".5", b"", b"]"),
        repeated(b"", b"[", 3000, b"", b"", b""),
        repeated(b"", b"[", 2000, b"", b"]", b""),
    ]
    for n in (997, 998, 999):
        out.append(repeated(b"", b"[", n, b"", b"]", b""))
        out.append(repeated(b"", b"[", n, b"1", b"]", b""))
    for n in (995, 996, 997):
        out.append(repeated(b"", b"[", n, b'"s"', b"]", b""))
        out.append(repeated(b"", b'{"a":', n, b"1", b"}", b""))
    for n in (497, 498, 499, 500):
        out.append(repeated(b"", b"[", n, b"", b"]", b""))
        out.append(repeated(b"", b"[", n, b"1.5", b"]", b""))
        out.append(repeated(b'{"definition":', b"[", n, b"", b"]", b"}"))
        out.append(repeated(b"", b'{"a":', n, b'"s"', b"}", b""))
    return out


def main() -> None:
    rng = random.Random(SEED)
    spec = Path("spec")

    # Every spec fixture that is a Net definition or document, and every
    # Net definition embedded in a golden trace.
    for path in sorted(glob.glob(str(spec / "**" / "*.json"), recursive=True)):
        raw = Path(path).read_bytes()
        value = json.loads(raw)
        if isinstance(value, dict) and value.get("format") == "petrus-net-definition":
            add("definition", f"fixture {path}", raw)
        elif isinstance(value, dict) and value.get("format") == "petrus-net-document":
            add("document", f"fixture {path}", raw)
        elif isinstance(value, dict) and isinstance(value.get("net"), dict):
            add("definition", f"embedded {path}#net", json.dumps(value["net"]).encode())

    rich = project_net_definition(rich_net()).model_dump(mode="json")
    small = small_document()
    fixture = json.loads((spec / "net-definition-v3.json").read_bytes())
    interop = json.loads((spec / "net-definition-v3-interoperability.json").read_bytes())
    for name, value in (("rich-definition", rich), ("small-document", small), ("fixture-definition", fixture), ("interop-definition", interop)):
        BASES[name] = compact(value).decode()
    add("definition", "rich-definition", BASES["rich-definition"].encode())
    add("document", "small-document", BASES["small-document"].encode())
    add("definition", "fixture-definition", BASES["fixture-definition"].encode())
    add("definition", "interop-definition", BASES["interop-definition"].encode())

    add_mutations("definition", "rich-definition", rich, 560, rng)
    add_mutations("document", "small-document", small, 460, rng)
    add_mutations("definition", "fixture-definition", fixture, 120, rng)
    add_fuzz("definition", "interop-definition", 200, rng)
    add_fuzz("document", "small-document", 160, rng)

    for index, payload in enumerate(SYNTAX):
        add("definition", f"syntax {index}", payload)
        add("document", f"syntax {index}", payload)
    for index, (payload, spelling) in enumerate(repeats()):
        add("definition", f"repeat {index}", payload, spelling)
        add("document", f"repeat {index}", payload, spelling)

    corpus = {
        "generator": "packages/petrus-impetus/differential/net_definition_corpus.py",
        "seed": SEED,
        "bases": BASES,
        "cases": CASES,
    }
    # One case per line keeps the file small and its diffs readable.
    head = json.dumps({key: corpus[key] for key in ("generator", "seed", "bases")}, ensure_ascii=False)
    lines = ",\n".join(json.dumps(case, ensure_ascii=False) for case in CASES)
    output = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent) / OUTPUT_NAME
    output.write_text(head[:-1] + ', "cases": [\n' + lines + "\n]}\n", encoding="utf-8")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    outcomes = sum(1 for case in CASES if "error" not in case)
    print(f"{len(CASES)} cases ({outcomes} admitted), {output.stat().st_size} bytes, sha256 {digest}")


if __name__ == "__main__":
    main()
