"""CPython's ``json`` as the Petrus reference uses it: the oracle of
``Petrus.Json.CPythonDifferentialSpec``.

Run by the test suite with the pinned interpreter (``scripts/upstream-python``,
CPython 3.14.6). It reads stdin and writes one stdout line per (case,
configuration), in order.

    dumps
    <JSON array of json.dumps keyword-argument objects>
    <one tagged value per line>

answers ``json.dumps(value, **kwargs).encode()`` for every configuration, and

    loads
    <one document per line: "x" and its bytes in hex>

answers every admission profile below for every document. Each answer is
``=`` followed by the result (hex bytes for ``dumps``, a tagged value for
``loads``) or ``!`` followed by ``[exception class, message]`` as JSON.

Values travel tagged, with nothing the transport itself could get wrong:
``["N"]``, ``["T"]``, ``["F"]``, ``["i", hex]`` (an integer of any size, in
base 16, which ``sys.set_int_max_str_digits`` does not limit), ``["d", hex]``
(a double's big-endian bits), ``["s", hex]`` (UTF-8 with ``surrogatepass``, so
a lone surrogate survives), ``["a", [...]]`` and ``["o", [[hex key, v], ...]]``.
"""

from __future__ import annotations

import json
import struct
import sys

sys.setrecursionlimit(20_000)


def build(tag: list) -> object:
    kind = tag[0]
    if kind == "N":
        return None
    if kind == "T":
        return True
    if kind == "F":
        return False
    if kind == "i":
        return int(tag[1], 16)
    if kind == "d":
        return struct.unpack(">d", bytes.fromhex(tag[1]))[0]
    if kind == "s":
        return bytes.fromhex(tag[1]).decode("utf-8")
    if kind == "a":
        return [build(item) for item in tag[1]]
    if kind == "o":
        return {bytes.fromhex(key).decode("utf-8"): build(item) for key, item in tag[1]}
    raise ValueError(f"unknown tag {kind!r}")


def tagged(value: object) -> list:
    if value is None:
        return ["N"]
    if value is True:
        return ["T"]
    if value is False:
        return ["F"]
    if type(value) is int:
        return ["i", format(value, "x")]
    if type(value) is float:
        return ["d", struct.pack(">d", value).hex()]
    if type(value) is str:
        return ["s", value.encode("utf-8", "surrogatepass").hex()]
    if type(value) is list:
        return ["a", [tagged(item) for item in value]]
    if type(value) is dict:
        return ["o", [[key.encode("utf-8", "surrogatepass").hex(), tagged(item)] for key, item in value.items()]]
    raise TypeError(type(value).__name__)


def refusal(error: BaseException) -> str:
    return "!" + json.dumps([type(error).__name__, str(error)])


# The admission profiles: the json.loads calls of upstream/petrus/src, by the
# hooks they pass.


def unique(pairs: list) -> dict:
    # net_definition._pairs, net_document._pairs, simulation_http, pi, dst
    result: dict = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object member")
        result[key] = value
    return result


def no_constant(spelling: str) -> object:
    raise ValueError(f"non-finite JSON number {spelling}")


def safe_integer(spelling: str) -> int:
    # net_definition._parse_integer
    value = int(spelling)
    if not -(2**53 - 1) <= value <= 2**53 - 1:
        raise ValueError(f"JSON integer {spelling} is outside the inclusive interoperable range")
    return value


def no_float(spelling: str) -> object:
    raise ValueError(f"v3 JSON numbers must use integer token spelling, got {spelling}")


def simulation_http(text: str) -> object:
    # simulation_http._strict_loads: the hooks, then a strict UTF-8 round trip
    value = json.loads(text, object_pairs_hook=unique, parse_constant=no_constant)
    json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8", errors="strict")
    return value


PROFILES = [
    ("plain", lambda text: json.loads(text)),
    ("unique-no-constants", lambda text: json.loads(text, object_pairs_hook=unique, parse_constant=no_constant)),
    ("simulation-http", simulation_http),
    (
        "net-definition-v3",
        lambda text: json.loads(
            text, object_pairs_hook=unique, parse_int=safe_integer, parse_float=no_float, parse_constant=no_constant
        ),
    ),
]


def main() -> None:
    lines = sys.stdin.read().split("\n")
    out = []
    if lines[0] == "dumps":
        configurations = json.loads(lines[1])
        for options in configurations:
            if "separators" in options:
                options["separators"] = tuple(options["separators"])
        for line in lines[2:]:
            if not line:
                continue
            value = build(json.loads(line))
            for options in configurations:
                try:
                    out.append("=" + json.dumps(value, **options).encode("utf-8").hex())
                except (ValueError, TypeError, RecursionError) as error:
                    out.append(refusal(error))
    elif lines[0] == "loads":
        for line in lines[1:]:
            if not line:
                continue
            raw = bytes.fromhex(line[1:])
            for _, profile in PROFILES:
                try:
                    text = raw.decode("utf-8", errors="strict")
                    out.append("=" + json.dumps(tagged(profile(text))))
                except (ValueError, RecursionError) as error:
                    out.append(refusal(error))
    else:
        raise SystemExit(f"unknown mode {lines[0]!r}")
    sys.stdout.write("\n".join(out) + "\n")


main()
