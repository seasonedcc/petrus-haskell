"""Generate the differential corpora for hamsterdan-contracts.

Run from the repository root against the pinned upstream environment:

    uv run --project upstream/hamsterdan --frozen --python 3.14 \
        python packages/hamsterdan-contracts/scripts/gen_corpus.py

Writes test/corpus/{contracts,projection,repr,literal_eval}.jsonl. Every expectation
is what the pinned Python actually did; the Haskell suite replays each line
and compares bytes. The generator is seeded, so reruns are reproducible.

contracts.jsonl  {"model", "input", "ok", "dump"?}
    input: the exact JSON text given to TypeAdapter(T).validate_json.
    dump:  json.dumps(TypeAdapter(T).dump_python(value, mode="json"),
                      ensure_ascii=False, separators=(",", ":")).
repr.jsonl       {"value", "repr"} | {"kind", "body", "entry", "digest"}
    value: a tagged encoding of a Python value (see tag()).
    body:  json.dumps(body, ensure_ascii=False) of a dashboard fact body;
    entry: f"{kind}:{body}"; digest: f"{kind}:{sorted(body.items())!r}".
literal_eval.jsonl {"source", "repr"} | {"source", "error"} | {"source", "unsupported"}
projection.jsonl {"tokens", "snapshot", "digest", "wait", "gates_ready"}
    tokens: the nine concern dumps given to project_readiness, in order.
"""

from __future__ import annotations

import ast
import dataclasses
import importlib
import json
import math
import random
import struct
import sys
import types
import typing
import warnings
from pathlib import Path

from pydantic import TypeAdapter

OUT = Path(__file__).resolve().parents[1] / "test" / "corpus"
MODULES = ["hamsterdan.contracts.readiness_v5", "hamsterdan.contracts.readiness"]
rng = random.Random(20261010)

# -- value pools ------------------------------------------------------------

TRICKY_CHARS = [
    "a", "Z", "0", " ", "'", '"', "\\", "\t", "\n", "\r", "\x00", "\x07", "\x1b", "\x7f",
    "\x80", "\x9f", "\xa0", "\xad", "é", "ß", "ÿ", "Ā", "͸", " ", " ", "​",
    "　", "﻿", "", "￿", "€", "中", "\U0001f600", "\U000e0001", "\U0010ffff",
    "\U0001d400", "̀", "{", "}", ":", ",", "[", "]", "#", "/",
]


def text(max_len: int = 12) -> str:
    kind = rng.random()
    if kind < 0.3:
        return "".join(rng.choice("abcdefghijklmnopqrstuvwxyz_0123456789") for _ in range(rng.randint(0, max_len)))
    if kind < 0.85:
        return "".join(rng.choice(TRICKY_CHARS) for _ in range(rng.randint(0, max_len)))
    return "".join(scalar() for _ in range(rng.randint(1, max_len)))


def scalar() -> str:
    while True:
        code = rng.choice([rng.randint(0x20, 0x7E), rng.randint(0x80, 0xFFFF), rng.randint(0x10000, 0x10FFFF)])
        if not 0xD800 <= code <= 0xDFFF:
            return chr(code)


def integer() -> int:
    return rng.choice([0, 1, -1, 7, 42, -42, 2**31, 2**53 + 1, 2**63, -(2**63) - 1, 10**30, -(10**25), rng.randint(-1000, 1000)])


def finite_float() -> float:
    return rng.choice([0.0, -0.0, 1.0, -1.5, 0.1, 1e16, 1e-5, 1e-4, 123456789.125, 1e22, 1.7976931348623157e308, 5e-324, struct.unpack("<d", struct.pack("<Q", rng.getrandbits(62)))[0]])


def any_float() -> float:
    return rng.choice([finite_float(), finite_float(), math.inf, -math.inf, math.nan])


def json_value(depth: int = 0, floats=finite_float):
    choice = rng.randint(0, 9 if depth < 3 else 5)
    if choice == 0:
        return None
    if choice == 1:
        return rng.choice([True, False])
    if choice == 2:
        return integer()
    if choice == 3:
        return floats()
    if choice in (4, 5):
        return text()
    if choice in (6, 7):
        return [json_value(depth + 1, floats) for _ in range(rng.randint(0, 3))]
    return {text(6): json_value(depth + 1, floats) for _ in range(rng.randint(0, 3))}


def json_object(floats=finite_float) -> dict:
    return {text(6): json_value(1, floats) for _ in range(rng.randint(0, 4))}


# -- typed generation ---------------------------------------------------------


def hints(cls) -> dict:
    module = sys.modules[cls.__module__]
    return typing.get_type_hints(cls, vars(module))


def unalias(tp):
    while isinstance(tp, typing.TypeAliasType):
        tp = tp.__value__
    return tp


def generate(tp):
    tp = unalias(tp)
    origin = typing.get_origin(tp)
    args = typing.get_args(tp)
    if tp is type(None):
        return None
    if tp is str:
        return text()
    if tp is int:
        return integer()
    if tp is bool:
        return rng.choice([True, False])
    if tp is dict or tp is typing.Any:
        return json_object()
    if origin is typing.Literal:
        return rng.choice(args)
    if origin in (types.UnionType, typing.Union):
        if args == (tuple[int, int], tuple[()]):
            return rng.choice([[], [integer(), integer()]])
        return generate(rng.choice(args))
    if origin in (list, tuple):
        item = args[0] if args else typing.Any
        if item is typing.Any:
            item = dict
        return [generate(item) for _ in range(rng.randint(0, 3))]
    if origin is dict:
        return {text(6): generate(args[1]) for _ in range(rng.randint(0, 3))}
    if dataclasses.is_dataclass(tp):
        return payload(tp, omit_defaults=rng.random() < 0.3)
    raise SystemExit(f"cannot generate {tp!r}")


def payload(cls, omit_defaults: bool = False) -> dict:
    out = {}
    for f in dataclasses.fields(cls):
        has_default = f.default is not dataclasses.MISSING or f.default_factory is not dataclasses.MISSING
        if has_default and omit_defaults and rng.random() < 0.7:
            continue
        out[f.name] = generate(hints(cls)[f.name])
    return out


def minimal(cls) -> dict:
    return {
        f.name: generate(hints(cls)[f.name])
        for f in dataclasses.fields(cls)
        if f.default is dataclasses.MISSING and f.default_factory is dataclasses.MISSING
    }


def models():
    for module_name in MODULES:
        module = importlib.import_module(module_name)
        for name, cls in vars(module).items():
            if isinstance(cls, type) and dataclasses.is_dataclass(cls) and cls.__module__ == module_name:
                yield name, cls


def case(cls, name: str, source: str) -> dict:
    adapter = TypeAdapter(cls)
    try:
        value = adapter.validate_json(source)
    except Exception:
        return {"model": name, "input": source, "ok": False}
    dumped = json.dumps(adapter.dump_python(value, mode="json"), ensure_ascii=False, separators=(",", ":"))
    return {"model": name, "input": source, "ok": True, "dump": dumped}


def shuffled(obj: dict) -> dict:
    items = list(obj.items())
    rng.shuffle(items)
    return dict(items)


WRONG = [None, True, False, 0, 1, 1.0, 0.0, "s", "", [], {}, [1, 2], "running", "unable"]


def contract_cases():
    seen_models = 0
    for name, cls in models():
        seen_models += 1
        out = []
        for _ in range(6):
            body = payload(cls, omit_defaults=rng.random() < 0.5)
            out.append(case(cls, name, json.dumps(shuffled(body) if rng.random() < 0.3 else body, ensure_ascii=rng.random() < 0.5)))
        base = minimal(cls)
        out.append(case(cls, name, json.dumps(base)))
        out.append(case(cls, name, json.dumps(base | {"zz_extra": 1})))
        out.append(case(cls, name, json.dumps([])))
        out.append(case(cls, name, "null"))
        for field in base:
            out.append(case(cls, name, json.dumps({k: v for k, v in base.items() if k != field})))
        for f in dataclasses.fields(cls):
            for wrong in rng.sample(WRONG, 5):
                out.append(case(cls, name, json.dumps(base | {f.name: wrong})))
        # Untyped members with non-finite and extreme numbers.
        for f in dataclasses.fields(cls):
            tp = unalias(hints(cls)[f.name])
            if tp is dict or typing.get_args(tp)[1:] == (typing.Any,):
                body = json_object(floats=any_float) | {"n": math.nan, "i": math.inf}
                out.append(case(cls, name, json.dumps(base | {f.name: body})))
                out.append(case(cls, name, json.dumps(base | {f.name: {"big": 1}}).replace('"big": 1', '"big": 1e400, "dup": 1, "dup": 2')))
        yield from out
    assert seen_models == 159 == len(dict(models())), seen_models


def targeted_cases():
    raw = [
        ("CloseSeen", ' \n{"reason": "x"} \t'),
        ("CloseSeen", '{"reason": "a", "reason": "b"}'),
        ("CloseSeen", '{"reason": "\\u00e9\\ud83d\\ude00"}'),
        ("CloseSeen", '{"reason": "\\ud800"}'),
        ("CloseSeen", '{"reason": "\\udc00x"}'),
        ("CloseSeen", '{"reason": "x"} x'),
        ("CloseSeen", '{"reason": "x",}'),
        ("CloseSeen", "{'reason': 'x'}"),
        ("CloseSeen", ""),
        ("CloseSeen", '{"reason": "tab\there"}'),
        ("CloseSeen", '{"reason": "\\/"}'),
        ("GateFact", '{"kind": "k", "incarnation": 1, "body": {"a": NaN, "b": Infinity, "c": -Infinity, "d": 1e400, "e": -0.0, "f": 1E5, "g": 1e-400}}'),
        ("GateFact", '{"kind": "k", "incarnation": 12345678901234567890123456789012345678901234567890, "body": {}}'),
        ("GateFact", '{"kind": "k", "incarnation": -0, "body": {}}'),
        ("GateFact", '{"kind": "k", "incarnation": 1, "body": {"a": 1, "b": 2, "a": 3}}'),
        ("GateFact", '{"kind": "k", "incarnation": 01, "body": {}}'),
        ("GateFact", '{"kind": "k", "incarnation": 1.5e3, "body": {}}'),
    ]
    for value in ["0", "-0", "0.0", "-0.0", "0e0", "1e-400", "false", "true", "0.5", '"0"', "null", "1", "[]"]:
        raw.append(("FaultRaisedFact", '{"incarnation": %s, "body": {"where": "review", "op": "o", "status": "faulted", "reason": "r"}}' % value))
        raw.append(("FaultClearedFact", '{"incarnation": %s, "body": {"where": "rerun", "op": "o", "status": "resolved"}}' % value))
    for kind in ['"fault"', '"Fault"', "null", "0", '"state"']:
        raw.append(("FaultRaisedFact", '{"incarnation": 0, "body": {"where": "mutation", "op": "o", "reason": "r"}, "kind": %s}' % kind))
    for body in [
        '{"head": "h", "status": "unable"}',
        '{"head": "h", "status": "unable", "category": "protocol"}',
        '{"head": "h", "status": "clear", "category": "protocol"}',
        '{"head": "h", "status": "bogus"}',
        '{"head": "h"}',
        "[]",
    ]:
        raw.append(("ReviewFact", '{"incarnation": 3, "body": %s}' % body))
    for best in ["[]", "[1,2]", "[1,2,3]", "[1]", "[true,1]", "[1.0,2]", "{}", "null", "[[],[]]"]:
        raw.append(("CiState", '{"head":"h","base":"b","policy":"p","lineage":"l","incarnation":1,"best":%s,"status":"s","fingerprint":"f","parked":[]}' % best))
    for clock in [
        '{"kind": "none"}',
        '{"kind": "armed", "timer": {"id": "t", "incarnation": 1, "sequence": 2, "head": "h"}, "due_at": "d"}',
        '{"kind": "armed", "timer": {"id": "t", "incarnation": 1, "sequence": 2, "head": "h"}, "due_at": "d", "matured_at": "m"}',
        '{"kind": "overdue", "timer": {"id": "t", "incarnation": 1, "sequence": 2, "head": "h"}, "due_at": "d", "matured_at": "m"}',
        '{"kind": "nope"}',
        '{}',
    ]:
        raw.append(("RemState", '{"subject": "s", "lifecycle_incarnation": 1, "lifecycle_head": "h", "lifecycle_active": true, "desired_timer": null, "clock": %s, "command_generation": 0, "delay_s": 5, "matured": [], "snoozed": false, "pending": {}, "blocked": {}, "faulted": {}}' % clock))
    for observation in ['""', '"given"']:
        raw.append(("ActionsObservation", '{"epoch": 1, "head": "h", "run_id": "77", "attempt": 2, "conclusion": "failure", "observation": %s}' % observation))
    raw.append(("ActionsObservation", '{"epoch": 1, "head": "h", "run_id": "77", "attempt": 2, "conclusion": "in_progress"}'))
    by_name = dict(models())
    for name, source in raw:
        yield case(by_name[name], name, source)


# -- repr --------------------------------------------------------------------


def tag(value):
    """A JSON encoding that pins a Python value exactly."""
    if value is None or isinstance(value, (bool, str)):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return {"float": struct.unpack("<Q", struct.pack("<d", value))[0]}
    if isinstance(value, list):
        return {"list": [tag(item) for item in value]}
    if isinstance(value, tuple):
        return {"tuple": [tag(item) for item in value]}
    if isinstance(value, dict):
        return {"dict": [[tag(k), tag(v)] for k, v in value.items()]}
    raise TypeError(value)


def py_value(depth: int = 0):
    choice = rng.randint(0, 11 if depth < 3 else 6)
    if choice == 0:
        return None
    if choice == 1:
        return rng.choice([True, False])
    if choice == 2:
        return integer()
    if choice == 3:
        return any_float()
    if choice in (4, 5, 6):
        return text(16)
    if choice in (7, 8):
        return [py_value(depth + 1) for _ in range(rng.randint(0, 3))]
    if choice == 9:
        return tuple(py_value(depth + 1) for _ in range(rng.choice([0, 1, 1, 2, 3])))
    keys = [rng.choice([text(5), integer(), rng.choice([True, False, None]), finite_float(), (text(3), integer())]) for _ in range(rng.randint(0, 3))]
    return {key: py_value(depth + 1) for key in keys}


def repr_cases():
    for _ in range(1500):
        value = py_value()
        yield {"value": tag(value), "repr": repr(value)}
    for code in list(range(0, 0x3000)) + [rng.randint(0x3000, 0x10FFFF) for _ in range(3000)]:
        if 0xD800 <= code <= 0xDFFF:
            continue
        s = chr(code) + rng.choice(["", "'", '"', "'\""])
        yield {"value": s, "repr": repr(s)}
    for _ in range(600):
        kind = rng.choice(["state", "checks", "review", "findings", "human", "fault", "mutation_pending", "x"])
        body = json_object(floats=any_float)
        yield {
            "kind": kind,
            "body": json.dumps(body, ensure_ascii=False),
            "entry": f"{kind}:{body}",
            "digest": f"{kind}:{sorted(body.items())!r}",
        }


# -- literal_eval -------------------------------------------------------------

HANDCRAFTED = [
    "", " ", "\n", "#c", "1", " 1", "\t1", "  \t 1 ", "1 # comment", "1\n", "1\n\n  \n# x\n", "\n1", "\n 1", "# c\n1", "# c\n 1",
    "1\n2", "1;", "1,", "1, 2", "1,2,", ",", "(1)", "(1,)", "()", "( )", "(\n1\n,\n)", "[\n1,\n2 # c\n]", "[1,]", "[,]", "[1,,2]",
    "{}", "{1: 2}", "{1: 2,}", "{1: 2, 1: 3}", "{1: 'a', True: 'b', 1.0: 'c'}", "{0: 1, False: 2, 0.0: 3, -0.0: 4}",
    "{'a': 1, 'a': 2, 'b': 3}", "{[]: 1}", "{(1, []): 2}", "{{}: 1}", "{(1, 2): 3}", "{None: 1, (): 2}", "{float('nan'): 1}",
    "{1, 2}", "{1}", "set()", "set( )", "set(1)", "frozenset()", "{1: 2, **x}", "{**x}", "[*x]",
    "-1", "- 1", "+1", "--1", "-+1", "-(1)", "-(1,)", "-True", "-None", "-'a'", "-1.5", "-0.0", "-0", "+0.0", "1 + 2", "1 - 2", "1+2j", "-1-2j", "2j", "1J", "1e5j",
    "True", "False", "None", "true", "none", "x", "_", "nan", "inf", "-inf", "Ellipsis", "...", "print(1)", "a.b", "1 if 1 else 2", "lambda: 1", "not 1", "(yield)", "await x",
    "0", "00", "000_0", "01", "0_1", "0_0", "1_000", "1__000", "1_", "_1", "0x", "0xff", "0XFF", "0x_f", "0x__f", "0xg", "0o17", "0o8", "0b101", "0b2", "0b_1", "0B1_0",
    "1.", ".5", "1.5", "1.e5", "1e5", "1E-5", "1e+5", "1e", "1e+", "1_0.0_1e1_0", "1._5", "1.5_", "1e_5", "00.5", "01.5", "01e1", "1e400", "-1e400", "1e-400", "4.9e-324", "2e-324",
    "1.7976931348623157e308", "1.7976931348623159e308", "0.1", "0.30000000000000004", "123456789012345678901234567890.0", "1if 1 else 2", "1abc", "1.real", "1 .real", "0x1.5",
    "9" * 4300, "9" * 4301, "1" + "_0" * 4299, "1" + "_0" * 4300, "0" * 5000, "0x" + "f" * 5000, "-" + "9" * 4300,
    "'a'", '"a"', "'''a'''", '"""a"""', "'a' 'b'", "'a''b'", "'a'\n'b'", "('a'\n'b')", "'a' \\\n 'b'", "u'a'", "U'a'", "r'a\\n'", "R'\\x'", "ur'a'", "rb'a'", "b'a'", "B'a'", "br'a'",
    "'a' b'b'", "b'a' b'b'", "f'a'", "F'{1}'", "'a' f'b'", "t'a'", "rf'a'", "fr'a'", "Rt'a'", "x'a'", "'''a\nb'''", "'a\nb'", "'a\\\nb'", "r'a\\\nb'", "'a", "'a\\'", "r'a\\'", "r'\\''", "'\\''",
    "'\\\\'", "'\\a\\b\\f\\n\\r\\t\\v'", "'\\0'", "'\\00'", "'\\000'", "'\\0000'", "'\\101'", "'\\777'", "'\\8'", "'\\9'", "'\\x41'", "'\\x4'", "'\\xg1'", "'\\u0041'", "'\\u004'", "'\\U00000041'",
    "'\\U0010ffff'", "'\\U00110000'", "'\\ud800'", "'\\udc00\\ud800'", "'\\N{BULLET}'", "'\\N{bullet}'", "'\\q'", "'\\ '", "'\\é'", "'é'", "'\U0001f600'", "'\\u2028'", "' '", "'\x00'", "'a\x00'",
    "'''a'b''c'''", "'''a''''", "'''a\\''''", '"""a""""', '"a\'b"', "'a\"b'", "'\r'", "'a'\r\n", "'''a\r\nb'''", "'''a\rb'''", "[1,\r\n2]", "1\r", "\x0c1", "1\x0c", " 1", "1 ",
    "[" * 199 + "]" * 199, "[" * 200 + "]" * 200, "[" * 201 + "]" * 201, "(" * 200 + "1" + ")" * 200, "{'a': " * 100 + "1" + "}" * 100, "[[[[1]]]]", "((((1,),),),)",
    "[1, 2", "{1: }", "{: 1}", "{1 2}", "{1: 2 3: 4}", "(1 2)", "[1 2]", "1 2", "(", ")", "]", "}", "[)", "'abc' [0]", "[1][0]", "(1)(2)",
    "{'a': [1, (2, 3.5, -4e-7), {'b': None}], 'c': ('x',)}", "[True, False, None, -0.0, 0.0, -1, 'x\\ty']", "{(): (), '': '', 0: 0}",
]


def literal_case(source: str) -> dict:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            value = ast.literal_eval(source)
        except (SyntaxError, ValueError, TypeError, MemoryError, RecursionError) as error:
            return {"source": source, "error": type(error).__name__ if not isinstance(error, SyntaxError) else "SyntaxError"}
    unsupported = modeled_problem(value)
    if unsupported:
        return {"source": source, "unsupported": unsupported}
    # literal_eval enforces the 4300-digit limit while parsing; repr would
    # refuse a large hexadecimal result, so the expectation is spelled
    # without the limit.
    sys.set_int_max_str_digits(0)
    try:
        return {"source": source, "repr": repr(value)}
    finally:
        sys.set_int_max_str_digits(4300)


def modeled_problem(value) -> str | None:
    if value is None or isinstance(value, (bool, int, float)):
        return None
    if isinstance(value, str):
        return "surrogate" if any(0xD800 <= ord(c) <= 0xDFFF for c in value) else None
    if isinstance(value, (list, tuple)):
        return next((p for p in map(modeled_problem, value) if p), None)
    if isinstance(value, dict):
        return next((p for p in map(modeled_problem, [*value.keys(), *value.values()]) if p), None)
    return type(value).__name__


MUTATION_ALPHABET = ["'", '"', "\\", ",", ":", "(", ")", "[", "]", "{", "}", " ", "\n", "#", "-", "+", ".", "e", "_", "0", "1", "x", "j", "r", "b", "u", "f", "N", "True"]


def mutate(source: str) -> str:
    chars = list(source)
    for _ in range(rng.randint(1, 3)):
        op = rng.randint(0, 2)
        position = rng.randint(0, len(chars))
        if op == 0 and chars:
            del chars[min(position, len(chars) - 1)]
        elif op == 1:
            chars.insert(position, rng.choice(MUTATION_ALPHABET))
        elif chars:
            chars[min(position, len(chars) - 1)] = rng.choice(MUTATION_ALPHABET)
    return "".join(chars)


def literal_cases():
    seen = set()
    sources = list(HANDCRAFTED)
    for _ in range(1500):
        value = py_value()
        sources.append(repr(value))
    for _ in range(3000):
        sources.append(mutate(repr(py_value())))
    for _ in range(1000):
        sources.append(mutate(rng.choice(HANDCRAFTED)))
    for source in sources:
        if source in seen or any(0xD800 <= ord(c) <= 0xDFFF for c in source):
            continue
        seen.add(source)
        yield literal_case(source)



# -- readiness projection -----------------------------------------------------

HAPPY = {
    "ActionsState": {"actions": "green"},
    "ReviewState": {"review": "clear"},
    "HumanState": {"human_approved": True, "mergeable": True},
    "FindingPublicationState": {"findings_published": True},
}


def concern(cls, happy: bool) -> object:
    adapter = TypeAdapter(cls)
    if happy:
        body = minimal(cls) | HAPPY.get(cls.__name__, {})
        if rng.random() < 0.15:
            body |= {rng.choice([f.name for f in dataclasses.fields(cls)]): None}
            body = {k: v for k, v in body.items() if v is not None}
            if cls.__name__ == "Authority":
                body = minimal(cls)
    else:
        body = payload(cls, omit_defaults=rng.random() < 0.5)
    try:
        return adapter.validate_json(json.dumps(body))
    except Exception:
        return adapter.validate_json(json.dumps(minimal(cls)))


def projection_cases():
    from hamsterdan.contracts import readiness as legacy

    classes = [
        legacy.Authority,
        legacy.ActionsState,
        legacy.ReviewState,
        legacy.HumanState,
        legacy.MutationState,
        legacy.FindingPublicationState,
        legacy.ConversationPublicationState,
        legacy.DashboardPublicationState,
        legacy.ReadinessPublicationState,
    ]
    for index in range(400):
        happy = index % 2 == 0
        tokens = [concern(cls, happy) for cls in classes]
        if happy and rng.random() < 0.3:
            # A perturbation that reaches a deeper wait.
            position = rng.randrange(len(classes))
            tokens[position] = concern(classes[position], False)
        if rng.random() < 0.4:
            digest = legacy.dashboard_projection_digest(*tokens)
            tokens[7] = tokens[7].validated_update(dashboard_projection=digest, dashboard_requested=rng.random() < 0.3)
        snapshot = legacy.project_readiness(*tokens)
        yield {
            "tokens": [token.dump() for token in tokens],
            "snapshot": json.dumps(snapshot.dump(), ensure_ascii=False, separators=(",", ":")),
            "digest": legacy.dashboard_projection_digest(*tokens),
            "wait": legacy.workflow_wait(snapshot),
            "gates_ready": legacy.workflow_gates_ready(snapshot),
        }


def write(name: str, rows) -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    count = 0
    with (OUT / name).open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n")
            count += 1
    return count


def main() -> None:
    sys.set_int_max_str_digits(0)
    print("contracts", write("contracts.jsonl", [*contract_cases(), *targeted_cases()]))
    print("projection", write("projection.jsonl", projection_cases()))
    sys.set_int_max_str_digits(4300)
    print("repr", write("repr.jsonl", repr_cases()))
    print("literal_eval", write("literal_eval.jsonl", literal_cases()))


if __name__ == "__main__":
    main()
