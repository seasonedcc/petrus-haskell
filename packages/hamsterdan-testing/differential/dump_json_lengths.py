"""The byte length of pydantic's JSON dump for generated JSON values.

readiness_coverage.py bounds each artifact by
``len(artifact.model_dump_json().encode())``. This prints, one JSON array per
line, a value (as ``json.dumps`` spells it) and that length for it, so that
the Haskell measure can be compared on values that stress the spelling:
non-ASCII and control characters, floats across ryu's layouts, big integers.
"""

import json
import random

from pydantic import JsonValue, TypeAdapter

ADAPTER = TypeAdapter(JsonValue)
TEXT = ["", "a", "é", " ", "😀", "\x00", "\x1f", "\x7f", "\b\f\n\r\t", '"', "\\", "/", "ü-ß-€-𝄞", "ࠀ", "￿"]
FLOATS = [
    0.0, -0.0, 1.0, -1.0, 0.1, 100.0, 1e15, 1e16, 1e17, 1.5e16, 12345678901234567.0, 9007199254740993.0,
    1e-4, 1e-5, 1e-6, 1.25e-5, 123.456, 1e21, 1e22, 1e100, -2.5e-300, 5e-324, 1.7976931348623157e308,
    0.30000000000000004, 2.0 ** 53, 1234567.0, 0.001234, 4.35, 1e-7,
]


def value(rng: random.Random, depth: int) -> object:
    kind = rng.randrange(8 if depth < 3 else 6)
    if kind == 0:
        return rng.choice([None, True, False])
    if kind == 1:
        return rng.choice([0, -1, 7, 2**63, -(2**70), 10**40])
    if kind == 2:
        if rng.random() < 0.5:
            return rng.choice(FLOATS)
        return rng.uniform(-1, 1) * 10.0 ** rng.randrange(-30, 30)
    if kind in (3, 4, 5):
        return "".join(rng.choice(TEXT) for _ in range(rng.randrange(6)))
    if kind == 6:
        return [value(rng, depth + 1) for _ in range(rng.randrange(4))]
    return {"".join(rng.choice(TEXT) for _ in range(rng.randrange(3))) + str(i): value(rng, depth + 1) for i in range(rng.randrange(4))}


def main() -> None:
    rng = random.Random(20261011)
    values: list[object] = [*FLOATS, *TEXT, {"k": FLOATS, "t": TEXT}]
    values += [value(rng, 0) for _ in range(2000)]
    for item in values:
        print(json.dumps([item, len(ADAPTER.dump_json(item))], ensure_ascii=True))


if __name__ == "__main__":
    main()
