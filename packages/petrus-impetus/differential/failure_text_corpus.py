"""Generate the ``FiringFailed.error`` text corpus.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-impetus/differential/failure_text_corpus.py

The script writes ``failure_text_corpus.json`` next to itself. Each case is
an exception (its class name and its ``args``) and the text the reference's
``firing_failure_text`` records for it. ``FailureTextSpec`` rebuilds every
case as a ``PythonException`` and checks the Haskell text; the zero- and
one-string-argument cases are also thrown as Haskell exceptions
(``ErrorCall`` and friends), whose spelling is ``Name()`` or
``Name('message')``.

Argument encoding: ``{"none": null}``, ``{"bool": b}``, ``{"int": "digits"}``,
``{"float": float.hex() or "nan"/"inf"/"-inf"}``, ``{"str": s}``,
``{"bytes": base64}``, ``{"object": [module, qualname]}`` (any other type).
"""

from __future__ import annotations

import base64
import json
import math
import random
from pathlib import Path

from petrus.impetus.instance import firing_failure_text

OUTPUT = Path(__file__).with_name("failure_text_corpus.json")
SEED = 20261010


class Opaque:
    pass


class SubStr(str):
    pass


class SubInt(int):
    pass


def encode(value: object) -> dict[str, object]:
    if value is None:
        return {"none": None}
    if type(value) is bool:
        return {"bool": value}
    if type(value) is int:
        return {"int": str(value) if abs(value) < 10**4000 else hex(value)}
    if type(value) is float:
        if math.isnan(value):
            return {"float": "nan"}
        if math.isinf(value):
            return {"float": "inf" if value > 0 else "-inf"}
        return {"float": value.hex()}
    if type(value) is str:
        return {"str": value}
    if type(value) is bytes:
        return {"bytes": base64.b64encode(value).decode()}
    kind = type(value)
    return {"object": [kind.__module__, kind.__qualname__]}


STRINGS = [
    "",
    "boom",
    "amount",
    "it's",
    'say "hi"',
    "both ' and \"",
    "back\\slash",
    "tab\tnew\nline\rcr",
    "\x00\x07\x1b\x7f",
    "é ñ ü",
    "\xa0nbsp",
    "　ideographic",
    "​zero width",
    " line sep",
    "private",
    "͸unassigned",
    "ࢗnew in 16",
    "\U0001F600 emoji",
    "\U0001CC00 legacy computing",
    "\U000E0001 tag",
    "\U0010FFFF",
    "x" * 5000,
    "é" * 4100,
]

BYTES = [b"", b"raw", b"it's", b'"q"', b"'\"", b"\x00\xff\x80\t\n\r\\", bytes(range(256))]

OTHER = [
    None,
    True,
    False,
    0,
    -1,
    2**53,
    -(2**64),
    10**4299,
    10**4300,
    -(10**4300),
    0.0,
    -0.0,
    0.1,
    1e16,
    1e-5,
    2.5,
    1.7976931348623157e308,
    5e-324,
    float("nan"),
    float("inf"),
    float("-inf"),
    Opaque(),
    SubStr("sub"),
    SubInt(3),
    [1, 2],
    {"a": 1},
    (1,),
    object(),
]

NAMES = ["ValueError", "KeyError", "RuntimeError", "ErrorCall", "IOException", "ArithException", "My Error", "Ünï", ""]


def case(name: str, args: tuple[object, ...]) -> dict[str, object]:
    kind = type(name, (Exception,), {}) if name else type("placeholder", (Exception,), {})
    if not name:
        kind.__name__ = ""
    error = kind(*args)
    return {"name": name, "args": [encode(argument) for argument in args], "text": firing_failure_text(error)}


def main() -> None:
    rng = random.Random(SEED)
    cases = []
    for name in NAMES:
        cases.append(case(name, ()))
        for value in STRINGS:
            cases.append(case(name, (value,)))
    for value in BYTES + OTHER:
        cases.append(case("ValueError", (value,)))
    pool = STRINGS[:-2] + BYTES + OTHER
    for _ in range(200):
        count = rng.randint(2, 4)
        cases.append(case(rng.choice(NAMES[:-1]), tuple(rng.choice(pool) for _ in range(count))))
    cases.append(case("ValueError", tuple("y" * 1000 for _ in range(6))))
    OUTPUT.write_text(
        '{"generator": "packages/petrus-impetus/differential/failure_text_corpus.py", "cases": [\n'
        + ",\n".join(json.dumps(item, ensure_ascii=False) for item in cases)
        + "\n]}\n",
        encoding="utf-8",
    )
    print(f"{len(cases)} cases")


if __name__ == "__main__":
    main()
