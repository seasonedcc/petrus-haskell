#!/usr/bin/env python3
"""
Generate the differential CEL corpus for ``petrus-cel`` from the pinned
cel-python (celpy 0.5.0) and the pinned Petrus CEL adapter.

Run from the repository root with the upstream virtualenv::

    upstream/petrus/.venv/bin/python packages/petrus-cel/test/gen-cel-corpus.py

(create the venv with ``cd upstream/petrus && uv sync`` if it is missing).

Writes two JSON files under ``packages/petrus-cel/test/corpus/``:

``cel-corpus.json``
    Curated cases spanning every expression form Petrus can produce or accept
    (literals, arithmetic, comparisons, logic, membership, selection, macros,
    functions, conversions, regexes, parse errors, environment binding), plus
    Petrus-adapter cases (filters, guards, completion conditions).

``cel-operators.json``
    A cross product of binary/unary operators over representative operands of
    every runtime class cel-python can produce (including the plain Python
    ``int``/``float``/``str``/``list``/``bytes`` values that leak out of
    celtypes arithmetic), so the Haskell value model is checked against the
    real Python dispatch rules.

Outcome encoding (shared by both files):

``{"parse_error": {"line": L, "column": C}}``
    ``Environment.compile`` raised ``CELParseError`` (line/column may be null:
    lark loses the position of ``true``/``false`` tokens).
``{"value": repr, "truthy": bool}``
    Evaluation returned a value; ``repr`` is Python's ``repr`` (function
    addresses normalised) and ``truthy`` is ``bool(value)`` -- the reading
    Petrus applies to filters, guards, and completion conditions.
``{"cel_error": rendering}``
    Evaluation raised ``CELEvalError``; ``rendering`` is its whole ``repr()``:
    the message, the wrapped exception's class, and that exception's
    arguments. Petrus puts this text into guard, filter, and completion
    diagnostics.
``{"py_error": class, "message": text, "repr": rendering}``
    Evaluation raised some other Python exception (cel-python leaks these for
    several malformed expressions): its class name, ``str()`` and ``repr()``.

Function addresses are normalised in every recorded text, and
``Activation.__repr__`` is replaced by the fixed text ``<Activation>``.
Otherwise an "undeclared reference" error would dump the whole activation,
addresses included. ``<Activation>`` is what the Haskell evaluator prints
there.

Every parseable case also records ``free``: Petrus' ``free_variables`` of the
compiled tree (sorted).
"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

import celpy
import celpy.evaluation
import lark
from petrus.impetus.binding.cel import compile_completion, compile_filter, compile_guard, free_variables
from petrus.impetus.petrinet import Binding, Cel, Marking, NetPath, Token

ROOT = Path(__file__).resolve().parent
OUT = Path(sys.argv[1]) if __name__ == "__main__" and len(sys.argv) > 1 else ROOT / "corpus"

ENV = celpy.Environment()

celpy.evaluation.Activation.__repr__ = lambda self: "<Activation>"

FUNCTION_ADDRESS = re.compile(r"<function (\w+) at 0x[0-9a-f]+>")
OBJECT_ADDRESS = re.compile(r"<([\w.]+) object at 0x[0-9a-f]+>")


def normalise(text: str) -> str:
    return OBJECT_ADDRESS.sub(r"<\1 object>", FUNCTION_ADDRESS.sub(r"<function \1>", text))


def error_outcome(error: BaseException) -> dict:
    """The whole rendering of a raised exception (see the module docstring)."""
    if isinstance(error, celpy.CELEvalError):
        try:
            return {"cel_error": normalise(repr(error))}
        except Exception as failure:
            return {"cel_error_args": normalise(repr(error.args)), "repr_raises": f"{type(failure).__name__}: {failure}"}
    return {"py_error": type(error).__name__, "message": normalise(str(error)), "repr": normalise(repr(error))}


def jsonable(value):
    """Python JSON data (NaN/Infinity allowed) as a corpus-safe structure."""
    if isinstance(value, float) and not math.isfinite(value):
        return {"$float": repr(value)}
    if isinstance(value, list):
        return [jsonable(item) for item in value]
    if isinstance(value, dict):
        return {"$object": [[key, jsonable(item)] for key, item in value.items()]}
    return value


def tree_text(tree) -> str:
    """A compact s-expression of a lark tree: ``(rule child ...)``, tokens as ``TYPE"value"``."""
    if isinstance(tree, lark.Tree):
        return "(" + " ".join([str(tree.data)] + [tree_text(child) for child in tree.children]) + ")"
    return f"{tree.type}{json.dumps(str(tree), ensure_ascii=False)}"


def outcome(expression: str, bindings: dict | None, with_tree: bool = False) -> dict:
    try:
        tree = ENV.compile(expression)
    except celpy.CELParseError as error:
        return {"parse_error": {"line": error.line, "column": error.column}}
    free = sorted(free_variables(tree))
    record: dict = {"free": free}
    if with_tree:
        record["tree"] = tree_text(tree)
    program = ENV.program(tree)
    try:
        activation = {name: celpy.json_to_cel(value) for name, value in (bindings or {}).items()}
        value = program.evaluate(activation)
    except Exception as error:
        record.update(error_outcome(error))
        return record
    record.update({"value": normalise(repr(value)), "truthy": bool(value)})
    return record


# ---------------------------------------------------------------------------
# Curated cases
# ---------------------------------------------------------------------------

DATA = {
    "amount": 150,
    "limit": 200,
    "name": "Alice",
    "ratio": 0.5,
    "flag": True,
    "nothing": None,
    "tags": ["urgent", "vip"],
    "items": [1, 2, 3],
    "empty": [],
    "nested": {"k": 1, "list": [1, 2, 3], "deep": {"x": "y"}},
    "big": 9223372036854775807,
    "small": -9223372036854775808,
    "nan": float("nan"),
    "inf": float("inf"),
    "mixed": [1, "a", 2.5, None, True],
    "words": ["apple", "banana", "cherry"],
}

QUEUES = {
    "pending": [
        {"color": "Payment", "data": {"amount": 150, "kind": "consumed"}},
        {"color": "Payment", "data": {"amount": 40, "kind": "read"}},
    ],
    "config": [{"color": "Config", "data": {"limit": 100}}],
    "done": [],
    "black": [{"color": None, "data": None}],
}

CASES: list[tuple[str, str, str]] = []

# Named variable environments; every case refers to one by name so the corpus
# stores each binding set once.
ENVIRONMENTS: dict[str, dict] = {"none": {}, "data": DATA}


def add(group: str, expressions, env: str | dict = "data") -> None:
    # ``<U>`` spells a backslash-u escape: the sequence is written indirectly so
    # editors and tooling never decode it while the corpus source is edited.
    if isinstance(env, dict):
        name = f"env{len(ENVIRONMENTS)}"
        ENVIRONMENTS[name] = env
        env = name
    for expression in expressions:
        CASES.append((group, expression.replace("<U>", "\\" + "u"), env))


add("literal.int", [
    "0", "1", "42", "-1", "-0", "007", "0x0", "0x1F", "0X1f", "-0x1F", "0xdeadBEEF",
    "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809",
    "0x7fffffffffffffff", "0x8000000000000000", "-0x8000000000000000",
    "99999999999999999999999",
])
add("literal.uint", [
    "0u", "1u", "1U", "42u", "0x1Fu", "0x1FU", "18446744073709551615u", "18446744073709551616u",
    "-1u", "-0u", "0xffffffffffffffffu", "0x10000000000000000u",
])
add("literal.double", [
    "0.0", "1.5", "-1.5", "1.", "-1.", ".5", "-.5", "1e3", "1E3", "1e+3", "1e-3", "-1e-3", "1.5e2",
    ".5e1", "1.e2", "1e400", "-1e400", "1e-400", "0.1", "123456789.123456789", "1e16", "1e15",
    "1.7976931348623157e308", "5e-324", "2.5e-5", "0.30000000000000004",
])
add("literal.bool_null", ["true", "false", "null", "True", "FALSE", "nullx", "true_", "_true"])
add("literal.string", [
    r"''", r'""', r"'abc'", r'"abc"', r"'a\'b'", r'"a\"b"', r"'a\"b'", r'"a\'b"',
    r"'\a\b\f\n\r\t\v'", r"'\\'", r"'\\\\'", r"'\z'", r"'\0'", r"'\00'", r"'\000'", r"'\101'",
    r"'\377'", r"'\400'", r"'\777'", r"'\999'", r"'\x41'", r"'\x4'", r"'\xZZ'", r"'\X41'",
    r"'<U>00e9'", r'"<U>00e9"', r"'<U>00E9'", r"'<U>0041<U>0042'", r"'<U>D800'", r"'\U0001F600'", r'"\U0001F600"',
    r"'\U00110000'", r"'\u12'", r"'é'", r"'日本語'", "'\U0001F600'", r"'a\'", r'"a\"',
    r"'a\\'", r"'tab\there'", "'\t'", "'a\rb'",
    r"r'a\nb'", r"R'a\nb'", r'r"a\"b"', r"r'\''", r"r'\\'", r"r''",
    "'''abc'''", '"""abc"""', "'''a'b'''", "'''a''b'''", "'''a\nb'''", '"""a\nb"""', "'''a\r\nb'''",
    r"'''a\nb'''", r"'''\''''", r"r'''a\nb'''", "r'''a\nb'''", "''''''", '""""""', "'''''''",
    "'a' 'b'", "'abc", '"abc', "'''abc", "'a\nb'",
    r"'<U>0041' == 'A'", r"'\101' == 'A'", r"size('\U0001F600')", r"size('é')", r"size('''a\nb''')",
])
add("literal.bytes", [
    r"b''", r"b'abc'", r'b"abc"', r"B'abc'", r"b'\x00\xff'", r"b'\377'", r"b'\101'", r"b'<U>00ff'",
    r"b'<U>0100'", r"b'\U00000041'", r"b'é'", r"b'\n'", r"br'\x41'", r"bR'\n'", r"Br'é'", r"BR'ā'",
    r"b'''abc'''", r"br'''a\nb'''", r"b'\''", r"b'\z'", r"size(b'abc')", r"size(b'é')", r"rb'abc'",
    r"b'\999'",
])
add("lex.signs", [
    "1-1", "1 -1", "1 - 1", "1--1", "1 - -1", "--1", "- 1", "-x", "- -x", "-(1)", "-(-1)", "x-1",
    "x -1", "2*-1", "2 * - 1", "-9223372036854775808", "-(9223372036854775808)", "-(-9223372036854775808)",
    "-1.5", "- 1.5", "1.5-1.5", "1-.5", "-0x10", "--0x10", "!true", "!!true", "!!!true", "!-1", "-!true",
    "- -1", "-  -  1", "1+-1", "[-1, - 1]", "{-1: -1}",
], {"x": 5})
add("lex.keywords", [
    "in", "in in [in]", "in + 1", "a in b", "a inx", "x.null", "x.in", "x.true", "x.false",
    "as", "if", "for", "while", "return", "let", "var", "void", "package", "namespace",
    "x{null: 1}", "1 true", "1 null", "[true", "f(true", "true(1)", "null(1)", "in(1)",
    "trueish", "nullish", "inside", "x.inx", "1 inx", "[1] in[[1]]", "1 in[1]",
], {"in": 5, "as": 7, "if": 8, "for": 9, "while": 10, "return": 11, "let": 12, "var": 13, "void": 14,
    "package": 15, "namespace": 16, "a": 1, "b": [1], "x": {"null": 1, "in": 2, "inx": 3}, "inx": [1]})
add("lex.comments_whitespace", [
    "1 // comment", "// only", "1 +// c\n 2", "1\n+\n2", "\t1\t", " 1 ", "1\r\n+2", "1 /\n/ 2",
    "1 / / 2", "1//2", "1 \f + 2", "1 \v + 2", "\n\n  1 +\n  )",
])
add("parse.precedence", [
    "1 + 2 * 3", "(1 + 2) * 3", "1 - 2 - 3", "1 - (2 - 3)", "8 / 4 / 2", "7 % 4 % 2", "2 * 3 % 4",
    "1 + 2 == 3", "1 < 2 == true", "true == 1 < 2", "1 < 2 < 3", "true && false || true",
    "true || false && false", "!true || true", "-2 * 3", "1 + 2 in [3]", "true ? 1 : 2 + 3",
    "false ? 1 : true ? 2 : 3", "true ? false ? 1 : 2 : 3", "(true ? 1 : 2) + 1", "1 == 1 == true",
    "1 in [1] == true", "true == (1 in [1])", "(1)", "((1))", "-(1 + 2)", "!(1 < 2)",
    "1 < 2 && 2 < 3 || false", "[1, 2][0] + 1", "{'a': 1}.a + 1", "[[1]][0][0]", "'abc'.size()",
])
add("parse.errors", [
    "", " ", "1 +", "(1", "[1,", "f(", "1 2", "1 @ 2", "x.", "x..y", "1 = 2", "1 === 2", "1 ! 2",
    "!= 1", "a ? b", "a ? b :", "? a : b", "[1, 2", "{1: 2", "{1}", "{1: }", "{: 1}", "f(,)", "f(1,)",
    "[1,]", "{1: 2,}", "x.f(", "x.f(1", "x[", "x[1", "x[]", "()", "(,)", "1 && ", "|| 1", "a | b",
    "a & b", "a.1", "a.'b'", "1.e", "1e", "1ee2", "0x", "0xg", "1uu", "1u2", "1.5u", "a{", "a{b}",
    "a{b:}", "a{b: 1,}", "a{1: 2}", "\"abc", "'abc\n'", "#", "$", "1 ;", "x.true", "x.false",
    "[true", "f(true", "true true", "1 true", "x == true &&", "a\n+\n", "a\n  b", "\n\n  1 +\n  )",
    ".", ".1.", "..1", "a.b.", "-", "!", "--", "1 + * 2", "a ? : b", "x{}.", "{'a' 1}",
    "a(b)(c)", "a.b(c)(d)", "(a)(b)", "1()", "[1](0)", "'a'()", "a[0](1)",
])
add("parse.member_forms", [
    "x", ".x", "x.y", ".x.y", "x.y.z", "x['y']", "x.y['z']", "f()", "size(x.items)",
    ".size", ".size(1)", "x.size()", "x.items.size()", "int", "int{}", "x{}", "x.y{}", "int{value: 5}",
    "int{value: 1, value: 2}", "string{value: 'a'}", "x{a: 1}", "size{}", "google", "google.protobuf",
    "google.protobuf.Int32Value", "google.protobuf.Int32Value{value: 3}", "google.protobuf.Nope",
    "google.x", ".google.protobuf.BoolValue", "google.protobuf.Int32Value(1)", "dyn(x)", "dyn(1, 2)",
    "dyn()", "has(x.y)", "has(x.q)", "has(x)", "has(1)", "has()", "has(x.y, x.q)", "has(x.q, x.y)",
    "has(1/0)", "has(nope)", "has(x.y.z)", "has(x.items[5])", ".nope", ".nope(1)", "nope", "nope(1)",
    "x.nope(1)", "1.nope()", "int{value: true ? 1 : 2}", "int{value: false ? 1 : 2}",
    "int{value: 1/0}", "int{value: [1].map(i, i/0)}", "type{}", "null_type{}", "list{}", "map{}",
], {"x": {"y": {"z": 1}, "items": [1, 2]}})
add("arith.int", [
    "1 + 2", "5 - 7", "6 * 7", "7 / 2", "-7 / 2", "7 / -2", "-7 / -2", "7 % 3", "-7 % 3", "7 % -3",
    "-7 % -3", "1 / 0", "1 % 0", "0 / 0", "9223372036854775807 + 1", "-9223372036854775808 - 1",
    "9223372036854775807 * 2", "-9223372036854775808 / -1", "-9223372036854775808 % -1",
    "-(-9223372036854775808)", "-9223372036854775807 - 1", "big + 0", "big + 1", "small - 1",
    "amount * limit", "amount / 7", "amount % 7", "amount - limit", "-amount",
    "4611686018427387904 * 2", "4611686018427387904 * -2", "3037000500 * 3037000500",
])
add("arith.uint", [
    "1u + 2u", "5u - 7u", "7u - 5u", "6u * 7u", "7u / 2u", "7u % 2u", "1u / 0u", "1u % 0u",
    "18446744073709551615u + 1u", "18446744073709551615u * 2u", "-1u", "-(1u)", "1u + 1", "1 + 1u",
    "1u - 2", "7u / 2", "7 / 2u", "7u % 2", "7 % 2u", "2u * 3", "2 * 3u",
])
add("arith.double", [
    "1.5 + 2.5", "1.5 - 2.5", "1.5 * 2.0", "3.0 / 2.0", "1.0 / 0.0", "-1.0 / 0.0", "0.0 / 0.0",
    "1.5 % 1.0", "-1.5", "-(0.0)", "0.1 + 0.2", "1e308 * 10.0", "1.5 + 1", "1 + 1.5", "1.5 * 2",
    "2 * 1.5", "3.0 / 2", "3 / 2.0", "7 / 2.5", "7 % 2.5", "7 % 2.0", "1 / 0.0", "-7 / 2.0",
    "1.5 / true", "1.5 / false", "ratio * 2.0", "ratio + ratio", "(ratio + ratio) == 1.0",
    "(ratio + ratio) == 1", "(1.5 + 1.5) == 3", "1.5 + 1.5 == 3.0", "3.0 == 3", "nan == nan",
    "nan != nan", "nan < 1.0", "inf > 1e308", "-inf < 0.0", "inf - inf", "inf * 0.0", "1 / nan",
    "1 / inf", "-1 / inf", "nan / 2.0", "2.0 / nan", "1.0 / 3.0", "2.0 / 3.0 * 3.0", "1 // 2",
    "10 / 0.1", "1 / 0.1", "1.0 / 0.1", "1 % 0.1", "5 / 0.5",
])
add("arith.string_list", [
    "'a' + 'b'", "'a' + 1", "1 + 'a'", "'ab' * 3", "3 * 'ab'", "'ab' * -1", "'ab' * 0", "'a' - 'a'",
    "'%s' % 'x'", "'%d' % 5", "'a' % 1", "[1] + [2]", "[1] + 2", "[1] * 2", "2 * [1]", "[1] - [1]",
    "b'a' + b'b'", "b'a' * 2", "{} + {}", "{'a': 1} + {'b': 2}", "null + 1", "1 + null", "true + 1",
    "1 + true", "true + true", "true * 3", "true - false", "-true", "-null", "-'a'", "-[1]", "-b'a'",
    "('a' + 'b').size()", "size('a' + 'b')", "('a' + 'b').contains('a')", "('a' + 'b').startsWith('a')",
    "([1] + [2]).size()", "size([1] + [2])", "([1] + [2]) == [1, 2]", "[1, 2] == ([1] + [2])",
    "([1] + [2])[1]", "(true + 1) == 2", "2 == (true + 1)", "(true + 1) == 2.0", "(true + 1) < 2.5",
    "'abc' + 'def' + 'ghi'", "name + ' Smith'", "tags + ['x']", "(name + '!').endsWith('!')",
])
add("compare", [
    "1 < 2", "2 <= 2", "3 > 2", "2 >= 3", "1 == 1", "1 != 1", "1 == 2", "'a' < 'b'", "'b' < 'a'",
    "'a' == 'a'", "'a' != 'b'", "'abc' < 'abd'", "'Z' < 'a'", "'é' > 'z'", "b'a' < b'b'",
    "true < false", "false < true", "true == true", "true != false", "1u < 2u", "1u == 1u", "null == null",
    "null != null", "null == 1", "1 == null", "null == 'a'", "'a' == null", "null == []", "[] == null",
    "null != []", "[] != null", "null == {}", "{} == null", "null == true", "true == null", "null == 1.0",
    "1.0 == null", "null < 1", "1 < null", "1 == 1.0", "1.0 == 1", "1 < 1.5", "1.5 < 2", "1.5 > 1",
    "2 > 1.5", "1 == 1u", "1u == 1", "1u < 2", "1 < 2u", "true == 1", "1 == true", "true < 2", "2 > true",
    "[1] == [1]", "[1] == [2]", "[1] == [1, 2]", "[1] != [1]", "[1] != [2]", "[1, 'a'] == [1, 'a']",
    "[1, 'a'] == [1.0, 'a']", "[1, 'a'] == [1.0, 'b']", "[1] == [1.0]", "[1] < [2]", "{} == {}",
    "{'a': 1} == {'a': 1}", "{'a': 1} == {'a': 2}", "{'a': 1} == {'b': 1}", "{'a': 1} != {'a': 1}",
    "{'a': 1} != {'a': 1.0}", "{'a': 1, 'b': 2} != {'a': 1.0, 'b': 3}", "{'a': 1} == {'a': 1.0}",
    "{'a': 1} < {'a': 2}", "[] == []", "[] == {}", "{} == []", "'a' == 1", "1 == 'a'", "'a' < 1",
    "1 < 'a'", "nan == 1.0", "nan < nan", "int == int", "int == type(1)", "type(1) == int",
    "type('a') == string", "int == 1", "1 == int", "size == size", "type(null) == null_type",
    "amount >= 100", "amount < limit", "name == 'Alice'", "flag == true", "nothing == null",
    "ratio < 1.0", "ratio == 0.5", "amount == 150.0", "tags == ['urgent', 'vip']",
    "nested == {'k': 1, 'list': [1, 2, 3], 'deep': {'x': 'y'}}", "9223372036854775807 == 9223372036854775807.0",
    "1.0 < 1", "1 > 1.0", "2.0 <= 2", "2.0 >= 2", "b'a' == 'a'", "'a' == b'a'", "b'a' == b'a'",
    "1 != 1.0", "1.0 != 1", "1 != 'a'", "'a' != 1", "1u != 1", "[1] != [1.0]", "[1, 'a'] != [1.0, 'b']",
])
add("logic", [
    "true && true", "true && false", "false && true", "false || false", "true || false",
    "1/0 > 1 || true", "true || 1/0 > 1", "1/0 > 1 || false", "false || 1/0 > 1", "1/0 > 1 && false",
    "false && 1/0 > 1", "1/0 > 1 && true", "true && 1/0 > 1", "1/0 > 1 || 2/0 > 1",
    "1/0 > 1 && 2/0 > 1", "1 || true", "1 || false", "true || 1", "false || 1", "1 || 2", "1 && true",
    "1 && false", "true && 1", "false && 1", "1 && 2", "'a' || true", "null || false", "null && true",
    "!1", "!null", "!'a'", "!(1/0 > 1)", "!!(1/0 > 1)", "true ? 1 : 2", "false ? 1 : 2", "1 ? 1 : 2",
    "0 ? 1 : 2", "null ? 1 : 2", "'' ? 1 : 2", "1/0 > 1 ? 1 : 2", "true ? 1 : 1/0", "false ? 1/0 : 2",
    "true ? 1/0 : 2", "true ? [1].map(x, x/0) : 2", "false ? [1].map(x, x/0) : 2",
    "true || [1].map(x, x/0) == []", "[1].map(x, x/0) == [] || true", "false && [1].exists(x, x/0 > 1)",
    "nope || true", "true || nope", "nope && false", "nope || nope2", "nope ? 1 : 2",
    "bool('2') && true", "true && bool('2')", "bool('2') || false", "!bool('2')", "bool('2') == true",
    "bool('2') ? 'y' : 'n'", "amount > 100 && name == 'Alice'", "amount > 1000 || flag",
    "(amount > 100) == flag", "!flag", "flag && !false",
])
add("membership_index", [
    "1 in [1, 2]", "3 in [1, 2]", "'a' in ['a']", "'a' in [1, 'a']", "'b' in [1, 'a']", "1 in [1, 'a']",
    "'a' in {'a': 1}", "'b' in {'a': 1}", "1 in {'a': 1}", "'a' in 'abc'", "'z' in 'abc'", "1 in 'abc'",
    "'ab' in 'abc'", "1 in null", "1 in 1", "1 in [1.0]", "1.0 in [1]", "null in [null]", "null in [1]",
    "[1] in [[1]]", "{} in [{}]", "1 in {1: 'a'}", "true in {1: 'a'}", "1 in {true: 'a'}", "b'a' in b'abc'",
    "97 in b'abc'", "1/0 in [1]", "1 in [1/0 > 1]", "[1, 2][0]", "[1, 2][1]", "[1, 2][2]", "[1, 2][-1]",
    "[1, 2][-3]", "[1, 2][true]", "[1, 2][1u]", "[1, 2][1.0]", "[1, 2]['a']", "[1, 2][null]",
    "{'a': 1}['a']", "{'a': 1}['b']", "{'a': 1}[1]", "{1: 'a'}[1]", "{1: 'a'}[1u]", "{1: 'a'}[true]",
    "{true: 'a'}[1]", "{1: 'a'}[1.0]", "{1.5: 'a'}[1.5]", "{'a': 1}[null]", "{'a': 1}[[1]]", "'abc'[0]",
    "b'abc'[0]", "null[0]", "1[0]", "(1/0)[0]", "[1][1/0]", "{'a': 1/0}['a']", "{'a': 1/0}['b']",
    "{'a': 1}.a", "{'a': 1}.b", "{1: 2}.a", "[1].a", "'abc'.a", "null.a", "(1/0).a", "1.a",
    "nested.k", "nested.deep.x", "nested.deep.z", "nested['deep']['x']", "nested.list[2]",
    "nested.list[3]", "tags[0]", "tags[5]", "tags[-1]", "items[amount - 149]", "mixed[3]", "mixed[3].a",
    "nothing.a", "name.a", "'urgent' in tags", "'x' in tags", "1 in items", "'k' in nested", "'z' in nested",
    "amount in items", "x in [1]",
])
add("maps_lists", [
    "[]", "[1, 2, 3]", "[1, 'a', 2.5, null, true, [1], {'a': 1}]", "[1/0]", "[1, 1/0]", "[1/0, nope]",
    "{}", "{'a': 1}", "{'a': 1, 'b': 2}", "{'a': 1, 'a': 2}", "{1: 'a', 1: 'b'}", "{1: 'a', true: 'b'}",
    "{true: 'a', 1: 'b'}", "{1: 'a', 1.0: 'b'}", "{1: 'a', 1u: 'b'}", "{-1: 'a', -2.0: 'b'}",
    "{-1: 'a', -2: 'b'}", "{[1]: 'a'}", "{{}: 'a'}", "{null: 1}", "{1.5: 'a'}", "{b'a': 1}",
    "{'a': 1/0}", "{1/0: 'a'}", "{'a': 1/0}.size()", "size({'a': 1/0})", "{'a': [1, {'b': 2}]}.a[1].b",
    "{'a': 1, 'b': 2}.size()", "[[1, 2], [3]]", "[1, 2, 3].size()", "size([[]])", "{'a': nope}",
    "{nope: 1}", "{'a': 1}.a.b", "{1: {2: 3}}[1][2]", "{'x': {'y': {'z': 1}}}.x.y.z", "{'a': 1, 'b': 1}",
    "{1: 1, 2: 2, 3: 3}", "{'b': 1, 'a': 2}", "[null]", "[[], {}]",
])
add("size", [
    "size('')", "size('abc')", "size('日本語')", "size(b'abc')", "size([])", "size([1, 2])", "size({})",
    "size({'a': 1})", "size(null)", "size(1)", "size(1.5)", "size(true)", "size()", "size(1, 2)",
    "'abc'.size()", "[1].size()", "{'a': 1}.size()", "null.size()", "1.size()", "size(tags)",
    "size(nested)", "size(name)", "tags.size()", "size(nothing)", "size(amount)", "size(1/0)",
    "size(int)", "size(size)", "size('a' + 'b')", "size([1] + [2])",
])
add("strings", [
    "'abc'.contains('b')", "'abc'.contains('d')", "'abc'.contains('')", "'abc'.contains(1)",
    "'abc'.startsWith('ab')", "'abc'.startsWith('b')", "'abc'.endsWith('bc')", "'abc'.endsWith('b')",
    "'abc'.startsWith('')", "'abc'.startsWith(1)", "'abc'.endsWith(null)", "[1].contains(1)",
    "[1].contains(2)", "[1, 'a'].contains('a')", "[1].contains('a')", "{'a': 1}.contains('a')",
    "{'a': 1}.contains('b')", "{'a': 1}.contains([1])", "b'abc'.contains(b'b')", "b'abc'.contains(98)",
    "b'abc'.startsWith(b'a')", "b'abc'.endsWith(b'c')", "1.contains(1)", "null.contains(1)",
    "contains('abc', 'b')", "startsWith('abc', 'a')", "endsWith('abc', 'c')", "'abc'.contains()",
    "'abc'.contains('a', 'b')", "name.startsWith('Al')", "name.endsWith('ce')", "name.contains('lic')",
    "tags.contains('vip')", "tags.exists(t, t.startsWith('u'))", "'abc'.upper()", "'abc'.size(1)",
    "[1].startsWith(1)", "'abc'.startsWith('abcd')", "''.endsWith('')", "'aaa'.contains('aa')",
    "'日本語'.startsWith('日')", "'abc'.matches('b')", "'abc'.charAt(1)",
])
add("regex", [
    "'abc'.matches('abc')", "'abc'.matches('b')", "'abc'.matches('^b')", "'abc'.matches('c$')",
    "'abc'.matches('^abc$')", "'abc'.matches('')", "''.matches('')", "''.matches('a')",
    "'abc'.matches('a.c')", "'a\\nc'.matches('a.c')", "'a\\nc'.matches('(?s)a.c')", "'ABC'.matches('abc')",
    "'ABC'.matches('(?i)abc')", "'abc'.matches('[a-c]+')", "'abc'.matches('^[a-c]+$')",
    "'abd'.matches('^[a-c]+$')", "'abc'.matches('[^a]')", "'aaa'.matches('^[^a]+$')", "'123'.matches('\\\\d+')",
    "'abc'.matches('\\\\d')", "'a b'.matches('\\\\s')", "'ab'.matches('\\\\s')", "'a_1'.matches('^\\\\w+$')",
    "'a-1'.matches('^\\\\w+$')", "'foo bar'.matches('\\\\bbar\\\\b')", "'foobar'.matches('\\\\bbar\\\\b')",
    "'foobar'.matches('\\\\Bbar')", "'abc'.matches('a|z')", "'xyz'.matches('a|z')", "'abc'.matches('(ab)+c')",
    "'ababc'.matches('^(ab)+c$')", "'abc'.matches('(?:ab)c')", "'abc'.matches('(?P<x>ab)c')",
    "'abc'.matches('(?<x>ab)c')", "'aaa'.matches('^a{3}$')", "'aa'.matches('^a{3}$')", "'aaaa'.matches('^a{2,3}$')",
    "'aaa'.matches('^a{2,}$')", "'a'.matches('^a{,2}$')", "'a{,2}'.matches('^a{,2}$')", "'abc'.matches('a*?')",
    "'abc'.matches('a+?b')", "'abc'.matches('x?abc')", "'abc'.matches('[[:alpha:]]+')",
    "'123'.matches('^[[:digit:]]+$')", "'abc'.matches('[[:^alpha:]]')", "'é'.matches('\\\\pL')",
    "'é'.matches('\\\\p{L}')", "'1'.matches('\\\\pL')", "'é'.matches('\\\\PL')", "'α'.matches('\\\\p{Greek}')",
    "'a'.matches('\\\\p{Greek}')", "'a'.matches('\\\\p{Latin}')", "'日'.matches('\\\\p{Han}')",
    "'Ж'.matches('\\\\p{Cyrillic}')", "'é'.matches('^.$')", "'😀'.matches('^.$')", "'é'.matches('^\\\\w$')",
    "'٣'.matches('^\\\\d$')", "'abc'.matches('[')", "'abc'.matches('(')", "'abc'.matches('a(?=b)')",
    "'aa'.matches('(a)\\\\1')", "'abc'.matches('a{1001}')", "'abc'.matches('*')", "'abc'.matches('a**')",
    "'abc'.matches('\\\\')", "'a.c'.matches('a\\\\.c')", "'abc'.matches('a\\\\.c')", "'a+c'.matches('a\\\\+c')",
    "'abc'.matches('\\\\Qa.c\\\\E')", "'a.c'.matches('\\\\Qa.c\\\\E')", "'abc'.matches('\\\\x61')",
    "'abc'.matches('\\\\x{62}')", "'a\\tb'.matches('\\\\t')", "'ABC'.matches('(?i:a)BC')",
    "'aBC'.matches('(?i:A)BC')", "'abc'.matches('\\\\Aabc\\\\z')", "'abc\\n'.matches('abc$')",
    "'abc\\ndef'.matches('^def')", "'abc\\ndef'.matches('(?m)^def')", "'abc\\ndef'.matches('(?m)abc$')",
    "'abc'.matches('[a-')", "'abc'.matches('[z-a]')", "'abc'.matches('a{2,1}')", "'-'.matches('[a-]')",
    "']'.matches('[]a]')", "'abc'.matches('(?U)a+')", "'ß'.matches('(?i)SS')", "'K'.matches('(?i)k')",
    "'k'.matches('(?i)K')", "'Σ'.matches('(?i)σ')", "'ς'.matches('(?i)Σ')", "'abc'.matches('(?i)[A-C]+$')",
    "'x'.matches('[\\\\d\\\\s]')", "'5'.matches('[\\\\d\\\\s]')", "'abc'.matches('[^\\\\d]')",
    "'abc'.matches('\\\\C')", "'abc'.matches('\\\\pN')", "'abc'.matches('\\\\p{Nope}')",
    "'abc'.matches('a{0}')", "'abc'.matches('(a)(b)(c)')", "'abc'.matches('a|')", "'abc'.matches('|')",
    "'abc'.matches('()')", "'abc'.matches('(?i)')", "'abc'.matches('(?z)a')", "'abc'.matches('\\\\z')",
    "'ab'.matches('a\\\\b')", "name.matches('^A')", "name.matches('^[A-Z][a-z]+$')", "1.matches('1')",
    "'1'.matches(1)", "matches('abc', 'b')", "'abc'.matches('b', 'c')", "'abc'.matches('[\\\\]]')",
    "'a'.matches('\\\\a')", "'\\x07'.matches('\\\\a')", "'abc'.matches('\\\\e')", "'aaa'.matches('^a{1,1000}$')",
    "'abc'.matches('\\\\0')", "'abc'.matches('\\\\8')", "'é'.matches('\\\\xe9')", "'abc'.matches('[[:word:]]')",
    "'abc'.matches('[[:foo:]]')", "' '.matches('[[:space:]]')", "'abc'.matches('\\\\pZ')",
    "'a\\u00a0b'.matches('\\\\s')", "'a\\u00a0b'.matches('\\\\pZ')", "'\\u2028'.matches('.')",
    "'\\r'.matches('.')", "'abc'.matches('a(?#comment)b')", "'abc'.matches('a b')", "'abc'.matches('(?x)a b')",
    "'AbC'.matches('(?i)a(?-i)b')", "'ABC'.matches('(?i)a(?-i)b')", "'abc'.matches('[\\\\pL]+')",
    "'a1'.matches('^[\\\\p{L}\\\\p{N}]+$')", "'abc'.matches('[^\\\\p{L}]')",
])
add("conversions", [
    "int(1)", "int(1u)", "int(1.9)", "int(-1.9)", "int(1e19)", "int(-1e19)", "int(9.2233720368547758e18)",
    "int(double('nan'))", "int(double('inf'))", "int('12')", "int(' 12 ')", "int('-12')", "int('+12')",
    "int('1_000')", "int('1__0')", "int('_1')", "int('0x1f')", "int('0X1F')", "int('-0x1f')", "int('0x-1f')",
    "int('0x0x1f')", "int('0x_1f')", "int(' 0x1f')", "int('1.5')", "int('')", "int('abc')", "int('٣')",
    "int('9223372036854775808')", "int('0b1')", "int('007')", "int(true)", "int(false)", "int(null)",
    "int([1])", "int({})", "int(b'12')", "int(int)", "int()", "int(1, 2)", "int('0x')", "int(bool('2'))",
    "uint(1)", "uint(-1)", "uint(1.5)", "uint(-0.5)", "uint(-1.5)", "uint('12')", "uint('0x1f')",
    "uint('-0x1')", "uint('18446744073709551616')", "uint(null)", "uint(true)", "uint(1e20)", "uint([])",
    "double(1)", "double(1u)", "double('1.5')", "double(' 1.5 ')", "double('1e3')", "double('nan')",
    "double('-inf')", "double('Infinity')", "double('1_000.5')", "double('abc')", "double('')",
    "double(true)", "double(null)", "double([])", "double(b'1.5')", "double(1, 2)", "double()",
    "double('0x1p3')", "double(9007199254740993)", "double('1e400')",
    "string(1)", "string(-1)", "string(1u)", "string(1.5)", "string(1e20)", "string(1e16)", "string(1e-5)",
    "string(0.1)", "string(double('nan'))", "string(true)", "string(false)", "string(null)", "string('a')",
    "string(b'abc')", "string(b'\\xff')", "string([1, 'a'])", "string({'a': 1})", "string(int)",
    "string(size)", "string(1, 2)", "string()", "string(bool('2'))", "string([1.5, null, true, b'x'])",
    "string(\"it's\")", "string(['it\\'s', \"q\\\"\"])", "string(['\\n\\t\\x01\\u00e9\\U0001F600'])",
    "bool(true)", "bool('true')", "bool('false')", "bool('True')", "bool('t')", "bool('f')", "bool('FALSE')",
    "bool('1')", "bool('0')", "bool('2')", "bool('yes')", "bool(1)", "bool(0)", "bool(2)", "bool(1.5)",
    "bool(null)", "bool([])", "bool(1u)", "bool()", "bytes('abc')", "bytes('é')", "bytes(b'a')",
    "bytes([97, 98])", "bytes([256])", "bytes(null)", "bytes(1)", "bytes({'a': 1})", "bytes('a', 1)",
    "list([1])", "list('ab')", "list({'a': 1})", "list(null)", "list(1)", "list()", "list(b'ab')",
    "map({'a': 1})", "map([[1, 2]])", "map([[1, 2], [1, 3]])", "map([[1]])", "map(1)", "map()", "map(null)",
    "type(1)", "type(1u)", "type(1.5)", "type('a')", "type(b'a')", "type(true)", "type(null)", "type([])",
    "type({})", "type(int)", "type(type(1))", "type(size)", "type(1 + 1)", "type(1.5 + 1.5)",
    "type('a' + 'b')", "type(1/0)", "type()", "type(1, 2)", "type(google)",
    "null_type", "null_type(1)", "null_type()", "dyn(1.5) == 1.5", "int(amount) == amount",
    "string(amount)", "double(amount) / 4.0", "int(ratio * 10.0)", "string(ratio)", "string(nested)",
    "int(name)", "string(tags)", "uint(amount)", "int('  -42  ')", "int('4_2')", "double('  2.5e-3 ')",
    "double('-0')", "string(-0.0)", "string(1e22)", "string(123456789012345680.0)", "int(-0.5)",
])
add("macros", [
    "[1, 2, 3].all(x, x > 0)", "[1, 2, 3].all(x, x > 1)", "[].all(x, x > 0)", "[1, 2, 3].exists(x, x > 2)",
    "[1, 2, 3].exists(x, x > 5)", "[].exists(x, true)", "[1, 2, 3].exists_one(x, x > 2)",
    "[1, 2, 3].exists_one(x, x > 1)", "[].exists_one(x, true)", "[1, 2, 3].map(x, x * 2)",
    "[1, 2, 3].filter(x, x > 1)", "[1, 2, 3].map(x, x > 1)", "[].map(x, x)", "[].filter(x, x)",
    "[1, 0, 2].all(x, 4 / x > 1)", "[0, 1].all(x, 4 / x > 1)", "[0, 1].all(x, 4 / x > 10)",
    "[1, 0].exists(x, 4 / x > 1)", "[0].exists(x, 4 / x > 1)", "[0, 1].exists(x, 4 / x > 10)",
    "[1, 0].exists_one(x, 4 / x > 1)", "[1, 0].map(x, 4 / x)", "[1, 0].filter(x, 4 / x > 1)",
    "[1, 2].all(x, x)", "[1].all(x, x)", "[1, 2].exists(x, x)", "[0, 0].exists(x, x)",
    "[1, 2].exists_one(x, x)", "[0, 1].exists_one(x, x)", "[1, 2].filter(x, x)", "[0, 1, '', 'a', [], [1]].filter(x, x)",
    "[1, 'a'].all(x, x > 0)", "['a', 1].exists(x, x > 0)", "[1, 'a'].exists(x, x == 'a')",
    "{'a': 1, 'b': 2}.all(k, k != 'c')", "{'a': 1, 'b': 2}.map(k, k)", "{'a': 1}.exists(k, k == 'a')",
    "'abc'.exists(c, c == 'b')", "'abc'.map(c, c)", "'abc'.all(c, c < 'd')", "b'ab'.map(c, c)",
    "1.all(x, true)", "null.exists(x, true)", "null.map(x, x)", "(1/0).all(x, true)", "nope.all(x, true)",
    "[1, 2].map(x, x).map(y, y + 1)", "[[1, 2], [3]].map(l, l.map(x, x * 10))",
    "[[1, 2], [3]].exists(l, l.exists(x, x == 3))", "[1, 2].exists(x, [3].exists(y, y == x + 1))",
    "[1, 2].map(x, [10].map(y, x + y))", "[1, 2].all(x, x > 0) && [3].exists(y, y == 3)",
    "[1, 2].map(x + 1, x * 2)", "[1, 2].map(1, 2)", "[1, 2].map(x.y, x)", "[1, 2].map(f(x), x)",
    "[1, 2].map(x, y, x)", "[1, 2].map(x)", "[1, 2].map()", "[1, 2].all()", "[1, 2].exists(x)",
    "[1, 2].exists(x, x > 0, 1)", "[1, 2].filter(x)", "[1, 2].exists_one()", "[1, 2].map(x, nope)",
    "[1, 2].exists(x, nope)", "[1, 2].all(x, nope)", "[1, 2].exists_one(x, nope)", "[1, 2].filter(x, nope)",
    "[1, 2].reduce(r, x, 0, r + x)", "[3, 1, 2].min()", "[].min()", "[1, 'a'].min()",
    "[1, 2].map(x, x).size()", "size([1, 2].filter(x, x > 1))", "[1, 2, 3].filter(x, x % 2 == 1).map(x, x * x)",
    "tags.exists(t, t == 'vip')", "tags.all(t, size(t) > 2)", "items.map(i, i * amount)",
    "items.filter(i, i > 1).size() == 2", "nested.list.exists(n, n == nested.k)",
    "mixed.exists(m, m == null)", "mixed.filter(m, m == 1)", "mixed.all(m, m != 'z')", "words.exists_one(w, w.startsWith('b'))",
    "words.map(w, size(w))", "[1, 2].exists(amount, amount == 2)", "[1, 2].map(amount, amount) == [1, 2]",
    "items.exists(items, items == 2)", "[1].exists(x, x == 1) || nope", "[1, 2].map(x, x)[1]",
    "[[1]].exists(l, l.map(x, 1 / 0)[0] == 1)", "[[1]].all(l, l.map(x, 1 / 0)[0] == 1)",
    "[[1]].exists_one(l, l.map(x, 1 / 0)[0] == 1)", "[1].map(x, [1].map(y, 1/0))",
    "[1, 2].exists(x, x == 2) == true", "[1, 2].all(x, x == 2) == false", "[0].exists(x, 1/x > 0) || true",
    "[0].all(x, 1/x > 0) && false", "[1, 2].exists(x, 'a')", "[true, 'a'].exists(x, x)", "['a', true].exists(x, x)",
    "[false, 'a'].all(x, x)", "['a', false].all(x, x)", "['a', 'b'].all(x, x)", "['a', 'b'].exists(x, x)",
    "[x].map(x, x)", "x.map(x, x)", "[1].map(google, google)", "[1].map(int, int)", "[1].map(size, size(size))",
])
add("timestamps_durations", [
    "duration('1s')", "duration('1.5s')", "duration('-1s')", "duration('1h30m')", "duration('100ms')",
    "duration('1us')", "duration('1ns')", "duration('1d')", "duration('1m')", "duration('0s')", "duration('s')",
    "duration('1')", "duration('1x')", "duration('1µs')", "duration('+2h')", "duration('1.5h') == duration('90m')",
    "duration('1s') + duration('2s')", "duration('3s') - duration('1s')", "duration('1s') < duration('2s')",
    "duration('1s') == duration('1s')", "duration('1s') * 2", "duration(5)", "duration(1.5)",
    "duration('315576000001s')", "duration('1h').getHours()", "duration('90m').getMinutes()",
    "duration('1.5s').getMilliseconds()", "duration('61s').getSeconds()", "duration('0s') ? 1 : 2",
    "string(duration('1.5s'))", "type(duration('1s'))", "duration('1s') == 1", "-duration('1s')",
    "timestamp('2020-01-01T00:00:00Z')", "timestamp('2020-01-01T10:20:30.5+02:00')",
    "timestamp('2020-01-01')", "timestamp('2020-01-01T00:00:00Z') < timestamp('2021-01-01T00:00:00Z')",
    "timestamp('2020-01-01T00:00:00Z') == timestamp('2020-01-01T02:00:00+02:00')",
    "timestamp('2020-01-01T00:00:00Z') + duration('1h')", "timestamp('2020-01-01T00:00:00Z') - duration('1h')",
    "timestamp('2020-01-02T00:00:00Z') - timestamp('2020-01-01T00:00:00Z')",
    "timestamp('2020-03-04T05:06:07Z').getFullYear()", "timestamp('2020-03-04T05:06:07Z').getMonth()",
    "timestamp('2020-03-04T05:06:07Z').getDate()", "timestamp('2020-03-04T05:06:07Z').getDayOfMonth()",
    "timestamp('2020-03-04T05:06:07Z').getDayOfWeek()", "timestamp('2020-03-04T05:06:07Z').getDayOfYear()",
    "timestamp('2020-03-04T05:06:07Z').getHours()", "timestamp('2020-03-04T05:06:07Z').getMinutes()",
    "timestamp('2020-03-04T05:06:07Z').getSeconds()", "timestamp('2020-03-04T05:06:07.123Z').getMilliseconds()",
    "timestamp('2020-03-04T05:06:07Z').getHours('+05:30')", "timestamp('2020-03-04T05:06:07Z').getHours('-08:00')",
    "timestamp('2020-03-04T05:06:07Z').getHours('UTC')", "timestamp('2020-03-04T05:06:07Z').getHours('bogus')",
    "timestamp('nope')", "timestamp(1)", "string(timestamp('2020-01-01T00:00:00Z'))",
    "type(timestamp('2020-01-01T00:00:00Z'))", "int(timestamp('2020-01-01T00:00:00Z'))",
    "timestamp('2020-01-01T00:00:00Z') ? 1 : 2", "timestamp('2020-01-01T00:00:00Z') == 1",
])
add("environment", [
    "a.b", "a.b.c", "a", "a.x", "a.b == 1", "size(a)", "has(a.b)", "has(a.z)", "x", "x.y",
], {"a.b": 1, "x": {"y": 2}})
add("environment", ["size", "size(size)", "int", "int(int)", "type", "x"], {"size": [1, 2], "int": 5, "type": "t", "x": 1})
add("environment", ["google", "google.protobuf", "google == 1"], {"google": 1})
add("environment", ["huge"], {"huge": 9223372036854775808})
add("environment", ["x"], {"bad-name": 1, "x": 1})
add("environment", ["x"], {"": 1, "x": 1})
add("environment", ["x"], {"1x": 1, "x": 1})
add("environment", ["x"], {"x\n": 1})
add("environment", ["x"], {".x": 1})
add("environment", ["a.b", "a"], {"a": 1, "a.b": 2})
add("environment", ["a.b", "a"], {"a.b": 2, "a": 1})
add("environment", ["a.b.c", "a.b", "a"], {"a.b.c": 3})
add("environment", ["nested.big"], {"nested": {"big": 18446744073709551616}})
add("environment", ["x == 1.0", "x"], {"x": 1.0})
add("environment", ["[n, i, s]"], {"n": float("-inf"), "i": float("inf"), "s": float("nan")})
add("environment", ["x.size()", "x[0].color", "x[0].data.k"], {"x": [{"color": "C", "data": {"k": 1}}]})


add("quirks.strings", [
    r"'a\' + 'b'", r'"a\" + "b"', r"'\\'", "'''a''''", "'a''b'", r"r'\'", r"'\1'", r"'\٣٣٣'",
    r"'\x00\x1f\x7f\x80\xa0\xad'", r"'<U>2028<U>feff<U>0085'", r"'\U0010ffff'", "\"it's\"", "'\"'",
    r"'\'\"'", r"b'\x00\x7f\x80\xff\t\n\r\''", "b'\"'", r"b'\'\"'", r"'\a\b\f\v'",
    r"'é' + 'ß'", r"'\x41\101<U>0041\U00000041'", r"string(['\x7f', '\x80'])", r"'<U>0378'",
])
add("quirks.numbers", [
    "int('١٢')", "int(' \\t12\\n')", "int('<U>3000 12')", "int('12_')", "int('-_1')", "int('+-1')",
    "int('0x1F_F')", "int('0xg')", "int('0x 1')", "int('-0x-1')", "int('0x_')", "int('  0x1f')",
    "double('1_0')", "double('_1')", "double('1e5_0')", "double('inF')", "double('-NaN')",
    "double('+infinity')", "double('infinit')", "double('.5')", "double('5.')", "double('.')",
    "double('1e')", "double('0x10')", "double('١.٥')", "double(' 1 ')", "double('1__0')",
    "uint('-0')", "uint('0x8000000000000000')", "uint(' 7 ')", "int{value: 'abc'}", "int{value: '12'}",
    "double{value: 'abc'}", "uint{value: -1}", "bool{value: 'yes'}", "string{value: 1}",
    "bytes{value: 'a'}", "bool(0.5)", "bool(double('nan'))", "bool(double('inf'))", "bool(-1)",
    "bool('-1')", "bool(' true')", "bool(b'1')", "string(1.0)", "string(1e-7)", "string(123456789.0)",
    "string(9999999999999998.0)", "string(0.1 + 0.2)", "1e308 * 10.0 - 1e308 * 10.0",
    "9223372036854775807 + 0", "-9223372036854775807 - 2", "18446744073709551615u - 1u", "0u - 1u",
    "2u - 3", "(true + 2) * 4611686018427387904", "(true + 2) * 3", "(true + true) * 9223372036854775807",
    "true * 9223372036854775807", "(true + 1) * 9223372036854775807", "true + 9223372036854775807",
    "(true + 9223372036854775807) + 1", "(true + 2) / 2", "(true + 2) % 2", "(true + 2) / 0",
    "(1.5 + 0.0) / 2.0", "(1.5 + 0.0) / 0.0", "(1.5 + 0.0) % 2.0", "(1.5 + 0.0) / 2",
    "2 / (1.5 + 0.0)", "2.0 / (1.5 + 0.0)", "(2 + true) / (1.5 + 0.0)", "-(1.5 + 0.0)", "-(true + 1)",
    "-9223372036854775808 / 1", "-7 % 0.0", "7 % -2.5", "-7 % 2.5", "-7.5 / 2.0", "1 / -0.0",
    "-1 / 0.5", "9223372036854775807 / 0.5", "5 / 2u", "5u / 2u", "5u % 0", "5 % 2u", "-5 % 2u",
])
add("quirks.compare", [
    "(1.5 + 0.0) == 1.5", "1.5 == (1.5 + 0.0)", "(1.5 + 0.0) == 1", "1 == (1.5 + 0.0)",
    "(1.5 + 0.0) < 2", "2 < (1.5 + 0.0)", "('a' + 'b') == 'ab'", "'ab' == ('a' + 'b')",
    "('a' + 'b') < 'b'", "([1] + []) < [1]", "[1] < ([1] + [])", "([1] + []) == [1]",
    "[[1, 2]] == [[1, 2]]", "[[1, 2]] == [[1, 'a']]", "[{'a': 1}] == [{'a': 1}]", "[1, 2] != [1]",
    "{'a': [1]} == {'a': [1]}", "{'a': 1, 'b': 2} == {'b': 2, 'a': 1}", "{1.5: 'a'} == {1.5: 'a'}",
    "{true: 1} == {1: 1}", "{1: 1} == {true: 1}", "{'a': 1} == {'a': 1, 'b': 2}", "{'a': 1} != {'b': 1}",
    "{'a': 1, 'b': 2} != {'a': 1, 'b': 2}", "{'a': 1, 'b': 2} != {'a': 1.0, 'b': 2.0}",
    "null in {'a': 1}", "'a' in {1: 1, 'a': 2}", "1 in {'a': 1, 1: 2}",
    "duration('1s') == duration('1000ms')", "duration('1s') < 1", "duration('1s') == 1",
    "duration('2s') / 2", "duration('2s') / duration('1s')", "duration('3s') % duration('2s')",
    "duration('1.5s') * 1.5", "duration('1s') + timestamp('2020-01-01T00:00:00Z')",
    "timestamp('2020-01-01T00:00:00Z') + timestamp('2020-01-01T00:00:00Z')",
    "duration('100000000000s') * 10", "duration('-1.5s')", "duration('1s') - duration('2s')",
    "duration('1s') * true", "duration('7s') // 2", "duration('1s') / 0", "duration('1s') * 1.5 == duration('1.5s')",
    "duration('1s') in [duration('1s')]", "{duration('1s'): 1}", "{duration('1s'): 1}[duration('1s')]",
    "duration('1.000001s') > duration('1s')", "duration('0.0000005s')", "duration('0.0000015s')",
    "duration('1h1m1.5s').getMinutes()", "duration('-90m').getHours()", "duration('1s').getHours('UTC')",
    "int(duration('1s'))", "string(duration('-0.5s'))", "duration('5s') * 0.1",
    "1 < 2 < 3", "3 > 2 > 1", "1 == 1 == true", "true == 1 == 1",
])
add("quirks.timestamps", [
    "timestamp('20200101T000000Z')", "timestamp('20200101')", "timestamp('2020-W01')",
    "timestamp('2020-W01-3')", "timestamp('2020-001')", "timestamp('2020-01')", "timestamp('2020')",
    "timestamp('2020-01-01T00:00:00+0530')", "timestamp('2020-01-01T00:00:00+05')",
    "timestamp('2020-01-01T24:00:00Z')", "timestamp('2020-02-30')", "timestamp('2020-01-01T00:00Z')",
    "timestamp('2020-01-01T00Z')", "timestamp('2020-01-01T00:00:60Z')", "timestamp('  2020-01-01')",
    "timestamp('2020-1-1')", "timestamp('1/2/2020')", "timestamp('2020-01-01T00:00:00.5')",
    "timestamp('2020-01-01t00:00:00z')", "timestamp('0001-01-01T00:00:00Z')",
    "timestamp('9999-12-31T23:59:59Z')", "timestamp('2020-01-01T00:00:00-00:00')",
    "timestamp('2020-01-01T00:00:00,5Z')", "timestamp('P1D')", "timestamp('2020-01-01T00:00:00 Z')",
    "timestamp('+2020-01-01')", "timestamp('2020-13-01')", "timestamp('2020-01-01T25:00:00')",
    "timestamp('2020-01-01T23:59:59.9999999Z')", "timestamp('2020-01-01 10:20:30')",
    "timestamp('2021-02-29')", "timestamp('2020-02-29')", "timestamp('2020-366')", "timestamp('2021-366')",
    "timestamp('2020-12-31T23:00:00-05:00')", "timestamp('2020-12-31T23:00:00-05:00').getFullYear()",
    "timestamp('2020-12-31T23:00:00-05:00').getFullYear('-05:00')", "timestamp('2020-01-01T00:00:00Z') - duration('1000000d')",
    "timestamp('2020-03-04T05:06:07Z').getHours('5:30')", "timestamp('2020-03-04T05:06:07Z').getHours('05:30')",
    "timestamp('2020-03-04T05:06:07Z').getDayOfYear('UTC')", "timestamp('2020-12-31T05:06:07Z').getDayOfYear()",
    "timestamp('2020-03-04T05:06:07Z').getDate('-12:00')", "timestamp('2020-03-01T05:06:07Z').getDayOfMonth('-08:00')",
    "timestamp('2020-03-04T05:06:07Z') == timestamp('2020-03-04T05:06:07Z')",
    "timestamp('2020-03-04T05:06:07Z') < 1", "timestamp('2020-03-04T05:06:07Z') - 1",
    "timestamp('2020-03-04T05:06:07Z') == timestamp('2020-03-04T05:06:07.000001Z')",
    "timestamp('2020-03-04T05:06:07.5Z') - timestamp('2020-03-04T05:06:07Z')",
    "timestamp('2020-01-01T00:00:00+05:30') + duration('1h')", "uint(timestamp('2020-01-01T00:00:00Z'))",
    "int(timestamp('1969-12-31T23:59:59.5Z'))", "string(timestamp('2020-01-01T00:00:00.123Z'))",
    "timestamp('2020-01-01T00:00:00Z').getMilliseconds()", "timestamp(timestamp('2020-01-01T00:00:00Z'))",
    "timestamp('2020-01-01', 1)", "type(timestamp('2020-01-01T00:00:00Z') - timestamp('2020-01-01T00:00:00Z'))",
])
add("quirks.members", [
    "google.protobuf.Struct{a: 1}", "google.protobuf.Struct{a: 1}.a", "google.protobuf.Struct{a: 1}.b",
    "google.protobuf.Struct{}", "google.protobuf.BoolValue{value: 'false'}", "google['protobuf']",
    "size(google)", "'protobuf' in google", "google.protobuf.Int32Value", "google.protobuf == google.protobuf",
    "google == google", "google.protobuf.ListValue{}", "google.protobuf.StringValue{value: 5}",
    "google.protobuf.DoubleValue{}", "google.protobuf.Struct{a: 1} == {'a': 1}", "has(google.protobuf.x)",
    ".size(1)", ".int", ".contains", ".size(1/0)", ".x", ".x.y", "x.y.z", "has(x.y.z)", "has(x.y.w)",
    "has(x.q.w)", "x['y']['z']", "x.y['z']", "x.y.z.w", "type(x)", "type(x.y)", "x.size()",
    "type(1){}", "size{}", "type{}", "x.items{}", "x{a: 1}", "int{}", "dyn{}", "has{}", "list{value: [1]}",
    "map{value: 1}", "string{}", "bytes{}", "double{}", "uint{}", "bool{}", "null_type{}", "timestamp{}",
    "duration{}", "duration{value: 1}", "int{value: 1, other: 2}", "x.y{}",
], {"x": {"y": {"z": 1}, "items": [1, 2]}})
add("quirks.macros", [
    "[1, 2, 3].exists(x, x == 2 || 1/0 > 0)", "[1, 2].map(x, x).filter(y, y > 1)",
    "[1, 2].exists_one(x, x/0 > 0)", "{'a': 1}.map(k, {'a': 1}[k])", "[1, 2].filter(x, 'a')",
    "[1].map(x, [x].map(x, x + 1))", "[1].exists(x, [2].exists(x, x == 2))", "[[1]].map(x, x.map(x, x))",
    "[1, 2].reduce(r, x, 1/0, r)", "[].reduce(r, x, 1/0, r)", "[1].map(x, y)", "[1, 2].all(x, x > 0) == true",
    "size([1, 2].map(x, 1/0))", "[1, 2, 3].map(x, x).exists(y, y == 3)", "[1, 2].reduce(r, x, 0)",
    "[1, 2].reduce(r + 1, x, 0, r + x)", "[1, 2].reduce(r, x, [], r + [x])", "['b', 'a'].min()",
    "[2.5, 1.5].min()", "[true, false].min()", "null.min()", "[1].min(2)", "[1, 2].filter(x, x > 1)[0]",
    "[1, 2].map(x, x * 2) == [2, 4]", "[1, 2].exists(x, x == 3) || [3].exists(y, y == 3)",
    "x.exists(e, e.k == 1)", "x.map(e, e.k)", "x.filter(e, has(e.k))", "x.all(e, e.k > 0)",
    "[1, 2, 3].filter(x, x > 1).map(y, y * 10).exists(z, z == 30)", "['a', 'b'].map(s, s + '!')",
    "[1, 2].map(x, {'v': x})", "[1, 2].map(x, {'v': x})[1].v", "{'a': 1, 'b': 2}.filter(k, k == 'b')",
    "{'a': 1, 'b': 2}.exists_one(k, k == 'b')", "'abc'.filter(c, c != 'b')", "b'ab'.filter(c, c > 97)",
    "[null, 1].filter(x, x == null)", "[1].map(x, x).size()", "[[1, 2]].exists(l, 2 in l)",
], {"x": [{"k": 1}, {"k": 2}, {"j": 3}]})
add("quirks.logic", [
    "true && (1/0 > 1 || true)", "(1/0 > 1 || true) && (2/0 > 1 || false)", "!(true || 1/0 > 1)",
    "true ? null.map(x, x) : 2", "false ? 1 : null.map(x, x)", "null.map(x, x) || true",
    "{'a': null.map(x, x)}", "[null.map(x, x)]", "has(null.map(x, x))", "[1].map(x, null.map(y, y))",
    "{'a': [1].map(x)}", "{'a': [1].map()}", "(true ? null.map(x, x) : 2) || true", "1 + null.map(x, x)",
    "true ? 1 : 2 ? 3 : 4", "false || false || true", "true && true && false", "!true || !false",
    "(1 || 2) || true", "true || (1 || 2)", "(1 && 2) && false", "null.map(x, x) ? 1 : 2",
    "int{value: null.map(x, x)}", "dyn(null.map(x, x))", "size(null.map(x, x))", "[1].exists(x, null.map(y, y))",
    "[1].all(x, null.map(y, y))", "[1].exists_one(x, null.map(y, y))", "[1].filter(x, null.map(y, y))",
    "duration('1s') ? 1 : 2", "[] ? 1 : 2", "true ? 1/0 : 1/0", "(1/0 > 0) == (1/0 > 0)",
    "[1/0 > 0] == [1]", "1/0 in [1/0]", "[1, 1/0][0]", "{'a': 1/0}.size() == 1",
])
add("quirks.calls", [
    "b'abc'.matches('b')", "'abc'.matches(b'b')", "null.matches('a')", "'a'.matches(null)",
    "['a'].matches('a')", "'a'.matches(['a'])", "b'abc'.startsWith('a')", "'abc'.startsWith(b'a')",
    "['abc'].startsWith('a')", "null.endsWith('a')", "'abc'.contains(null)", "b'abc'.contains(256)",
    "b'abc'.contains('a')", "[].contains(null)", "{}.contains(null)", "{1: 2}.contains(1.0)",
    "{1: 2}.contains(true)", "{true: 2}.contains(1)", "{'a': 1}.contains(['a'])", "[[1]].contains([1])",
    "int(1, 2, 3)", "uint(1, 2)", "double(1, 2)", "bool(1, 2)", "bytes('a', 1, 2)", "list([1], [2])",
    "map({}, {})", "duration('1s', 5)", "duration(1, 5000)", "null_type(null)", "string(1, 2, 3)",
    "contains('abc')", "matches('a')", "getHours(timestamp('2020-01-01T00:00:00Z'))", "getHours(1)",
    "type(1).x", "'1'.int()", "1.5.int()", "'abc'.size()", "'abc'.string()", "[1].type()", "size.size()",
    "int.size()", "'a'.bytes()", "b'a'.string()", "'2020-01-01T00:00:00Z'.timestamp()", "'1s'.duration()",
    "null.null_type()", "x.size()", "x.contains(1)", "'abc'.contains('b', 'c')", "endsWith('a')",
    "startsWith()", "size('a', 'b')", "type(type)", "type(null_type)", "type(google)", "string(type)",
    "string(google.protobuf.Int32Value)", "string(null_type)", "string(contains)", "type(contains)",
], {"x": [1, 2]})
add("quirks.idents", [
    "true_ == 1", "null_ == 2", "in_ == 3", "_ == 4", "__ == 5", "a1b2 == 6", "A == 7",
    "as == 8", "x in in", "in.in", "null.x", "true.x", "x.null", "x.true", "x.in",
], {"true_": 1, "null_": 2, "in_": 3, "_": 4, "__": 5, "a1b2": 6, "A": 7, "as": 8, "x": {"null": 1, "in": 2}, "in": [{"null": 1}]})
add("quirks.lex", [
    "1 + 2 // trailing", "1 + // inside\n 2", "'a' // 'b'", "1 /* no block comments */ + 2", "1\t+\f2",
    "1 \r+ 2", "\n1", "1\n", "1\n\n+", "x\n.y", "x.\ny", "x .y", "x. y", "f (1)", "[1,2] [0]", "{1:2} [1]",
    "1u + 2U", "0x1u", "0x1fu", "-0x1u", "1e1u", "1.0u", ".5u", "5.u", "1e-1", "1e+1", "1E1", "1.e1",
    "0.0e0", "-.0", "00.5", "0x", "0xx", "0x1.5", "1_000", "1__", "$x", "x$", "@", "`", "~1", "1 ^ 2",
    "a?b:c", "a ?b :c", "a?:b", "a??b:c", "a ? b : c ? d : e", "(a ? b : c) ? d : e",
], {"x": {"y": 1}, "f": 1, "a": True, "b": 1, "c": 2, "d": 3, "e": 4})

# ``_in_`` is the one operator in the function table spelled as an identifier:
# it resolves to ``operator_in`` and is callable by name. After an operand the
# contextual lexer only accepts ``in``, so ``x int`` reads as ``x in t``.
add("quirks.operator_in", [
    "_in_(1, [1])", "_in_(2, [1])", "_in_(1, {1: 2})", "_in_('b', 'abc')", "_in_(1, 2)", "_in_(1)",
    "_in_(1, 2, 3)", "_in_", "size(_in_)", "_in_ == _in_", "type(_in_)", "x int", "true int", "1 inx",
    "x.exists(_in_, _in_ > 1)",
], {"x": [1, 2], "t": [1], "x2": 1})
# Lone surrogates: a string literal may spell one, and the result is a Python
# str holding it (the Haskell side keeps it as WTF-8, as petrus-json does).
add("literal.string.surrogates", [
    r"size('<U>D800')", r"'<U>D800' + 'a'", r"'<U>D83D' + '<U>DE00'", r"'<U>D83D' + '<U>DE00' == '\U0001F600'",
    r"'<U>D800' < '<U>E000'", r"'<U>DFFF' > '<U>D7FF'", r"'<U>DBFF<U>DC00'", r"size('<U>DBFF<U>DC00')",
    r"'a<U>D800b'.contains('<U>D800')", r"'<U>DC00x'.startsWith('<U>DC00')", r"'x<U>DC00'.endsWith('<U>DC00')",
    r"'<U>D800' == '<U>D800'", r"'<U>D800' in ['<U>D800']", r"{'<U>D800': 1}['<U>D800']", r"string('<U>D800')",
    r"'<U>D800'.matches('.')", r"bytes('<U>D800')", r"type('<U>D800')",
])

# Error renderings: the class and arguments of the wrapped exception, which
# Petrus diagnostics show in full.
add("errors.rendering", [
    "duration('abc')", "duration('1x')", "duration('-1x')", "duration('+abc')", "duration('.s')", "duration('1.s')",
    "duration('1s2x')", "duration('-1s2x')", "duration(('a' + 'b'))", "duration(('1' + 'x'))",
    "duration(('-' + '1x'))", "timestamp('2024-02-30')", "timestamp('2024-07-01T25:00:00Z')", "timestamp('')",
    "timestamp('2024-07-01T15:00:00Z').getHours('Not/AZone')", "timestamp('2024-07-01T15:00:00Z').getHours(('a' + 'b'))",
    "'a'.matches({})", "'a'.matches(1.5)", "'a'.matches(duration('1s'))", "'a'.matches(timestamp('2020-01-01T00:00:00Z'))",
    "{'a': 1}.matches('a')", "1.5.matches('a')", "duration('1s').matches('a')", "('a' + 'b').matches(['a'])",
    "['a', 'b'].matches('a')", "(['a'] + []).matches('a')",
    "duration('2s') * 4611686018427387904", "duration('-1s') * 2u", "duration('1s') * 9223372036854775807u",
    "duration('2s') * (true + 4611686018427387903)", "duration('1000s') * (true + 99999999)",
    "duration('1s') * (true + 999999999)", "double(b'ab')", "double(b'')", "int(b'ab')",
    "duration('1s').getHours('UTC')", "duration('1s').getMinutes(null)",
    "timestamp('2020/13/01')", "timestamp('2020/02/30')", "timestamp('2021/02/29')", "timestamp('2020/01/01 24:00')",
    "timestamp('2020/01/01 23:60')", "timestamp('2020/01/01 23:59:60')", "timestamp('0000')", "timestamp('0000/01/01')",
])

# ---------------------------------------------------------------------------
# Petrus adapter cases
# ---------------------------------------------------------------------------


def token_from(spec):
    color, data = spec
    return Token(color, data)


def petrus_outcome(kind: str, expression: str, places, inputs):
    try:
        if kind == "filter":
            implementation = compile_filter(Cel(expression))
        elif kind == "guard":
            implementation = compile_guard(Cel(expression), NetPath("approve"), [NetPath(p) for p in places])
        else:
            implementation = compile_completion(Cel(expression), [NetPath(p) for p in places])
    except ValueError as error:
        text = str(error)
        marker = text.find("': (")
        if text.startswith("invalid CEL") and marker >= 0:
            text = text[: marker + 2]
        return {"compile_error": text}
    results = []
    for item in inputs:
        try:
            if kind == "filter":
                value = implementation(token_from(item))
            elif kind == "guard":
                consumed, read = item
                binding = Binding(
                    NetPath("approve"),
                    consumed=tuple((NetPath(p), tuple(token_from(t) for t in ts)) for p, ts in consumed),
                    read=tuple((NetPath(p), tuple(token_from(t) for t in ts)) for p, ts in read),
                )
                value = implementation(binding)
            else:
                marking = Marking({NetPath(p): tuple(token_from(t) for t in ts) for p, ts in item})
                value = implementation(marking)
            results.append({"value": value})
        except Exception as error:
            results.append(error_outcome(error))
    return {"results": results}


PETRUS: list[tuple[str, str, list, list]] = []
PAYMENTS = [("Payment", {"amount": 150}), ("Payment", {"amount": 40}), (None, None), ("Payment", [1, 2]),
            ("Payment", "text"), ("Payment", 7), ("Payment", 1.5), ("Payment", True), ("Payment", {}),
            ("Payment", {"amount": "150"}), ("Payment", {"amount": 150.0}), ("Payment", {"a.b": 1}),
            ("Payment", {"bad key": 1}), ("Payment", {"amount": 9223372036854775808}),
            ("Payment", {"amount": 100, "size": 3}), ("Payment", {"x\n": 1}), ("Payment", {"google": 1}),
            ("Payment", {"amount": float("nan")}), ("Payment", {"amount": -0.0}), ("Payment", {".amount": 5})]
for expression in ["amount >= 100", "amount", "amount > 100 && amount < 200", "size", "has(amount)",
                   "a.b == 1", "true", "1", "0", "'x'", "[]", "[1]", "null", "{}", "amount >=",
                   "amount / 0 > 1", "nope", "amount in [150, 40]", "1.0", "double('nan')", "size(size) > 0",
                   "x", "google", "amount == amount", "[1].map(x, x/0)", "null.map(x, x)", "x.y.z"]:
    PETRUS.append(("filter", expression, [], PAYMENTS))

GUARD_PLACES = ["pending", "config"]
GUARD_INPUTS = [
    ([("pending", [("Payment", {"amount": 150})])], [("config", [("Config", {"limit": 200})])]),
    ([("pending", [("Payment", {"amount": 150})])], [("config", [("Config", {"limit": 100})])]),
    ([("pending", [(None, None)])], []),
    ([("pending", [("Payment", {"amount": 150}), ("Payment", {"amount": 40})])], []),
    ([("pending", [("X", {"kind": "consumed"})])], [("pending", [("X", {"kind": "read"})])]),
    ([], []),
]
for expression in ["pending[0].data.amount <= config[0].data.limit", "pending[0].color == null && pending[0].data == null",
                   "pending.all(t, t.data.amount < 500)", 'pending[0].data.kind == "consumed" && pending[1].data.kind == "read"',
                   "pending[0].data.amount >=", "elsewhere[0].data.amount >= 100", "pending[0].data.amount >= 100",
                   "size(pending) == 2", "size(config) == 0", "pending.exists(done, done.color == null) && size(done) == 0",
                   "pending.exists(t, t.color == 'Payment')", "has(pending[0].data.amount)", "config"]:
    PETRUS.append(("guard", expression, GUARD_PLACES, GUARD_INPUTS))
PETRUS.append(("guard", "a.b == 1", ["a.b"], [([("a.b", [("C", 1)])], [])]))
PETRUS.append(("guard", "x", ["x", "bad-place"], [([("x", [("C", 1)])], [])]))

COMPLETION_PLACES = ["done", "pending"]
COMPLETION_INPUTS = [
    [("done", [("Result", {"state": "ok"})])],
    [("done", [("Result", {"state": "failed"})])],
    [],
    [("pending", [(None, None)])],
    [("done", [(None, None)]), ("pending", [("X", 1)])],
]
for expression in ['done.exists(t, t.data.state == "ok") && size(pending) == 0', "size(done) == 0 && size(pending) == 0",
                   "size(done) ==", "size(doen) > 0", "done.exists(t, t.color == null) && size(done) >= 1",
                   "done[0].data.state == 'ok'", "pending", "size(done) + size(pending)", "done.map(t, t.color)",
                   "a.exists(t, b.exists(u, u.x == t.y)) && size(c) > 0", "pending.exists(done, done.color == null)"]:
    PETRUS.append(("completion", expression, COMPLETION_PLACES, COMPLETION_INPUTS))
PETRUS.append(("completion", "size(review.start) > 0", ["review.start"], [[("review.start", [("C", 1)])]]))
PETRUS.append(("completion", "size(x) > 0", ["x", "a.b"], [[("x", [("C", 1)])]]))


# ---------------------------------------------------------------------------
# Free-variable cases (compile only)
# ---------------------------------------------------------------------------

FREE = [
    "size(done) > 0 && pending[0].color == null",
    "a.exists(t, b.exists(u, u.x == t.y)) && size(c) > 0",
    "pending.exists(done, done.color == null) && size(done) == 0",
    "x", ".x", "x.y.z", "f(x, y)", "x.f(y)", "[x, {y: z}]", "x ? y : z", "has(x.y)", "dyn(x)",
    "[1].map(x + y, x)", "[1].map(y + x, x)", "[1].map(a.b, c)", "[1].map(f(x, y), x)", "[1].map(1, x)",
    "[1].map(x)", "[1].map()", "l.reduce(r, i, 0, r + i)", "l.min()", "l.sort(x, x)", "l.exists_one(e, e)",
    "l.filter(f, f).map(m, m)", "x{a: y}", "int{value: v}", "true", "null", "'x'", "-x", "!x",
    "[1].map((x), x)", "[1].map(-x, x)", "[1].map(x[y], y)", "[1].map([x, y], x)", "[1].map({x: y}, x)",
    "[1].map(x ? y : z, x)", "[1].map(.x, x)", "[1].exists(x.y.z, w)", "[1].map(x.f(y), z)",
    "[1].map(f(), x)", "[1].map(y.exists(q, q), x)", "[1].map(x || y && z, x)", "[1].map(x in y, x)",
    "[1].map(x + y * z, x)", "[1].map(x * y + z, x)", "[1].map((x + y) + z, x)", "[1].map(x + (y + z), x)",
    "[1].map(a[b][c], x)", "[1].map(a.b.c(d), x)", "[1].map([[a], b], x)", "[1].map({a: [b]}, x)",
]


def write_lines(path: Path, header: dict, key: str, records: list) -> None:
    """Write ``header`` plus ``records`` under ``key``, one record per line (diff-friendly)."""
    head = json.dumps(header, ensure_ascii=False)[:-1]
    body = ",\n".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) for record in records)
    path.write_text(f'{head}, "{key}": [\n{body}\n]}}\n')


TREE_GROUPS = ("lex.", "parse.")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    cases = []
    for index, (group, expression, env) in enumerate(CASES):
        record = {"id": index, "group": group, "env": env, "expr": expression}
        record.update(outcome(expression, ENVIRONMENTS[env], group.startswith(TREE_GROUPS)))
        cases.append(record)
    free = []
    for expression in FREE:
        try:
            free.append({"expr": expression, "free": sorted(free_variables(ENV.compile(expression)))})
        except celpy.CELParseError:  # pragma: no cover
            raise SystemExit(f"free-variable case does not parse: {expression!r}")
    petrus = []
    for kind, expression, places, inputs in PETRUS:
        record = {"kind": kind, "expr": expression, "places": places}
        if kind == "filter":
            record["inputs"] = [[color, jsonable(data)] for color, data in inputs]
        elif kind == "guard":
            record["inputs"] = [
                [[[p, [[c, jsonable(d)] for c, d in ts]] for p, ts in consumed],
                 [[p, [[c, jsonable(d)] for c, d in ts]] for p, ts in read]]
                for consumed, read in inputs
            ]
        else:
            record["inputs"] = [[[p, [[c, jsonable(d)] for c, d in ts]] for p, ts in marking] for marking in inputs]
        record.update(petrus_outcome(kind, expression, places, inputs))
        petrus.append(record)
    header = {
        "generator": "packages/petrus-cel/test/gen-cel-corpus.py",
        "celpy": "0.5.0",
        "python": sys.version.split()[0],
        "environments": {name: [[key, jsonable(value)] for key, value in env.items()]
                         for name, env in ENVIRONMENTS.items()},
        "free_variables": free,
        "petrus": petrus,
    }
    write_lines(OUT / "cel-corpus.json", header, "cases", cases)
    operators = operator_cases()
    write_lines(OUT / "cel-operators.json",
                {"generator": "packages/petrus-cel/test/gen-cel-corpus.py", "celpy": "0.5.0"},
                "cases", operators)
    print(f"cel-corpus.json: {len(cases)} expression cases, {len(free)} free-variable cases, "
          f"{len(petrus)} Petrus adapter cases; cel-operators.json: {len(operators)} cases")


# ---------------------------------------------------------------------------
# Operator cross product
# ---------------------------------------------------------------------------

OPERANDS = [
    "null", "true", "false", "bool('2')", "0", "1", "-7", "9223372036854775807", "0u", "3u",
    "18446744073709551615u", "0.0", "-0.0", "2.5", "double('nan')", "double('inf')", "''", "'ab'",
    "b'ab'", "[]", "[1]", "[1, 'a']", "{}", "{'a': 1}", "int", "size", "(true + 2)", "(2.5 + 0.0)",
    "('a' + 'b')", "([1] + [])", "(b'a' + b'')", "(1/0)", "google", "duration('2s')",
    "timestamp('2020-01-01T00:00:00Z')",
]
BINARY = ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "in", "&&", "||"]
UNARY = ["-", "!"]
POSTFIX = ["[0]", "['a']", "[true]", ".a", ".size()", " ? 'y' : 'n'"]
FUNCTIONS = ["size", "int", "uint", "double", "string", "bool", "bytes", "type", "list", "map", "dyn", "has"]


def operator_cases() -> dict:
    cases = []
    for left in OPERANDS:
        for op in BINARY:
            for right in OPERANDS:
                expression = f"{left} {op} {right}"
                record = {"expr": expression}
                record.update(outcome(expression, None))
                cases.append(record)
    for operand in OPERANDS:
        for op in UNARY:
            expression = f"{op}{operand}"
            record = {"expr": expression}
            record.update(outcome(expression, None))
            cases.append(record)
        for postfix in POSTFIX:
            expression = f"{operand}{postfix}"
            record = {"expr": expression}
            record.update(outcome(expression, None))
            cases.append(record)
        for function in FUNCTIONS:
            expression = f"{function}({operand})"
            record = {"expr": expression}
            record.update(outcome(expression, None))
            cases.append(record)
    for record in cases:
        record.pop("free", None)
    return cases


if __name__ == "__main__":
    main()
