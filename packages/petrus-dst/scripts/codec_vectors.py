"""Decode verdicts of the pinned Python reference for the codec suite.

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/codec_vectors.py \
        ../../packages/petrus-dst/test/data/codec-vectors.json

Three corpora:

* ``fixtures``: every committed fixture file and its ``decode_artifact``
  verdict (the digest and length of the canonical re-encoding, or the
  exception).
* ``mutations``: structural mutations of one fixture per artifact version.
  Each mutation is described by a path and an operation; both runtimes
  apply it to the parsed fixture and decode the canonical bytes of the
  result. A refusal records every pydantic error (location, type, message)
  or the ``ValueError`` message.
* ``raw``: hand-written byte strings for the strict JSON loader.
* ``nesting``: every ``JsonValue`` location of the mutated fixtures (and
  locations inside them) replaced by a value nested in lists, objects, or
  both, at the deepest admitted depth and the first refused one, so the
  port must find pydantic's recursion-guard boundary exactly. A refusal
  records pydantic's first error only: once the guard trips, pydantic-core
  also refuses later values it has seen by identity (small integers, for
  one), which the port does not reproduce.
"""

from __future__ import annotations

import codecs
import hashlib
import json
import sys
from copy import deepcopy
from pathlib import Path

from pydantic import ValidationError

from petrus.testing.dst import decode_artifact, encode_artifact

FIXTURES = Path("tests/dst/fixtures")
MUTATED = [
    "projection-crash-recovery-world-v1.json",
    "action-budget-exhaustion-world-v2.json",
    "terminal-checker-failure-world-v2.json",
    "seeded-projection-crash-recovery-world-v3.json",
    "history-record-budget-exhaustion-world-v4.json",
    "generated-runtime-minimized-fair-regression-v4.json",
]
REPLACEMENTS = [None, True, 1.5, "x", -1, 0, [], {}, 2**53]


def canonical(value) -> bytes:
    return json.dumps(value, allow_nan=False, separators=(",", ":"), sort_keys=True).encode()


def verdict(payload: bytes) -> dict:
    try:
        artifact = decode_artifact(payload)
    except ValidationError as error:
        return {
            "validation": [[list(e["loc"]), e["type"], e["msg"]] for e in error.errors()],
            "title": error.title,
        }
    except ValueError as error:
        return {"value_error": str(error)}
    encoded = encode_artifact(artifact)
    return {"encoded": "sha256:" + hashlib.sha256(encoded).hexdigest(), "bytes": len(encoded)}


def paths(value, prefix=()):
    """Every member path, pruning arrays to their first and last items."""

    yield prefix
    if isinstance(value, dict):
        for key in sorted(value):
            yield from paths(value[key], prefix + (key,))
    elif isinstance(value, list):
        indices = sorted({0, len(value) - 1}) if value else []
        for index in indices:
            yield from paths(value[index], prefix + (index,))


def resolve(value, path):
    for step in path:
        value = value[step]
    return value


def mutate(value, path, operation, replacement):
    mutated = deepcopy(value)
    if operation == "extra":
        target = resolve(mutated, path)
        target["zz_extra"] = True
        return mutated
    parent = resolve(mutated, path[:-1])
    if operation == "delete":
        del parent[path[-1]]
    else:
        parent[path[-1]] = replacement
    return mutated


def mutations() -> list:
    out = []
    for name in MUTATED:
        base = json.loads((FIXTURES / name).read_bytes())
        for path in paths(base):
            target = resolve(base, path)
            operations = []
            if isinstance(target, dict):
                operations.append(("extra", None))
            if path and isinstance(path[-1], str):
                operations.append(("delete", None))
            if path:
                operations.extend(("replace", r) for r in REPLACEMENTS if r != target or type(r) is not type(target))
            for operation, replacement in operations:
                mutated = mutate(base, path, operation, replacement)
                out.append(
                    {
                        "fixture": name,
                        "path": list(path),
                        "operation": operation,
                        "value": replacement,
                        "verdict": verdict(canonical(mutated)),
                    }
                )
    return out


NESTED_KEYS = ("payload", "value", "detail")
NESTED_KINDS = ("list", "dict", "mixed")


def nested(kind: str, depth: int) -> object:
    """A leaf 0 inside ``depth`` containers, outermost first in the kind."""

    value: object = 0
    for level in reversed(range(depth)):
        if kind == "list" or (kind == "mixed" and level % 2 == 0):
            value = [value]
        else:
            value = {"k": value}
    return value


def admitted(payload: bytes) -> bool:
    try:
        decode_artifact(payload)
    except ValueError:
        return False
    return True


def nesting() -> list:
    out = []
    for name in MUTATED:
        base = json.loads((FIXTURES / name).read_bytes())
        shapes = set()
        for path in paths(base):
            shape = tuple("#" if isinstance(step, int) else step for step in path)
            if not path or path[-1] not in NESTED_KEYS or shape in shapes:
                continue
            shapes.add(shape)
            if not admitted(canonical(mutate(base, path, "replace", 0))):
                continue
            for kind in NESTED_KINDS:
                low, high = 0, 600
                while low < high:
                    middle = (low + high) // 2
                    if admitted(canonical(mutate(base, path, "replace", nested(kind, middle)))):
                        low = middle + 1
                    else:
                        high = middle
                for depth in (low - 1, low):
                    result = verdict(canonical(mutate(base, path, "replace", nested(kind, depth))))
                    if "validation" in result:
                        result["validation"] = result["validation"][:1]
                    out.append({"fixture": name, "path": list(path), "kind": kind, "depth": depth, "verdict": result})
    return out


def raw_cases() -> list[bytes]:
    legacy = (FIXTURES / "projection-crash-recovery-world-v1.json").read_bytes()
    seeded = (FIXTURES / "seeded-projection-crash-recovery-world-v3.json").read_bytes().rstrip(b"\n")
    cases = [
        b"",
        b" ",
        b"[",
        b"[1,]",
        b'{"a":1,}',
        b'{"a" 1}',
        b'{"a":1 "b":2}',
        b"[1 2]",
        b'{1:2}',
        b'"\\x"',
        b'"\\u12"',
        b'"\\u12zz"',
        b'"abc',
        b'"a\x01b"',
        b"nul",
        b"tru",
        b"-",
        b"01",
        b"1.",
        b"1e",
        b"1e400",
        b"-1e400",
        b"NaN",
        b"Infinity",
        b"-Infinity",
        b'{"a":NaN}',
        b'{"a":1,"a":2}',
        b'{"a":1,"a":2,"b":NaN}',
        b'{"format":"petrus-dst-world","format":"other"}',
        b'{"value":NaN}',
        b'{"a":{"b":1,"b":2}}',
        b"\xff",
        b'"\xc3"',
        b'{"a":"\xed\xa0\x80"}',
        b'{"a":"\xe2\x82"}',
        codecs.BOM_UTF8 + b"{}",
        "{}".encode("utf-16"),
        "{}".encode("utf-16-le"),
        "{}".encode("utf-16-be"),
        "{}".encode("utf-32"),
        b"1" * 4300,
        b"1" * 4301,
        b"-" + b"1" * 4301,
        b"[]",
        b"3",
        b'"s"',
        b"null",
        b"{}",
        b'{"version":5}',
        b'{"version":null}',
        b'{"version":"1"}',
        b'{"version":1.0}',
        b'{"version":true}',
        b"{}x",
        b"{} ",
        b"\n{}\n",
        b"[" * 5 + b"]" * 5,
        legacy,
        legacy.rstrip(b"\n") + b"   ",
        seeded.replace(b'"version":3', b'"version":3.0'),
        seeded.replace(b'"seed":1729', b'"seed":1729.0'),
        seeded.replace(b'"seed":1729', b'"seed":true'),
        b"\x00",
        b'{"a":"\\ud83d\\ude00"}',
        b'{"\\u00e9":1}',
        # Lone surrogates in a string value: from an escape, from
        # surrogatepass bytes, and as a reversed pair (two lone surrogates).
        seeded.replace(b'"InstanceCreated"', b'"Instance\\ud800Created"', 1),
        seeded.replace(b'"InstanceCreated"', b'"Instance\xed\xa0\x80Created"', 1),
        seeded.replace(b'"InstanceCreated"', b'"Instance\\udc00\\ud83dCreated"', 1),
        # A lone surrogate in a key, which the port refuses (DIVERGENCES.md).
        seeded.replace(b'"record_types"', b'"record\\ud800types"', 1),
    ]
    return cases


def main() -> int:
    fixtures = {}
    for path in sorted(FIXTURES.glob("*.json")):
        fixtures[path.name] = verdict(path.read_bytes())
    raw = [{"hex": case.hex(), "verdict": verdict(case)} for case in raw_cases()]
    out = {"fixtures": fixtures, "mutations": mutations(), "raw": raw, "nesting": nesting()}
    Path(sys.argv[1]).write_text(json.dumps(out, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
