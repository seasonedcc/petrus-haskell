"""CPython's string, repr, codec and ``json.loads`` diagnostics: the oracle of
``Petrus.Json.PythonCompatSpec``.

Run by the test suite with the pinned interpreter (``scripts/upstream-python``,
CPython 3.14.6). It reads one JSON request per stdin line and writes one JSON
answer per stdout line, in order. A request is ``[operation, argument]``;
strings travel as lists of code points (so a lone surrogate survives) and
bytes as hexadecimal. An answer is ``["ok", result]`` or ``["error", text]``
(``str()`` of the exception raised).
"""

from __future__ import annotations

import json
import sys
import unicodedata
import uuid

MAX = 0x10FFFF


def text(points: list[int]) -> str:
    return "".join(map(chr, points))


def points(value: str) -> list[int]:
    return [ord(c) for c in value]


def ranges(verdicts) -> list[list[int]]:
    out: list[list[int]] = []
    for code, verdict in enumerate(verdicts):
        if verdict:
            if out and out[-1][1] + 1 == code:
                out[-1][1] = code
            else:
                out.append([code, code])
    return out


def unicode_tables(_argument):
    chars = [chr(code) for code in range(MAX + 1)]
    return {
        "printable": ranges(c.isprintable() for c in chars),
        "space": ranges(c.isspace() for c in chars),
        "linebreak": ranges(len(("a" + c + "b").splitlines()) == 2 for c in chars),
        "decimal": [[code, unicodedata.decimal(c)] for code, c in enumerate(chars) if unicodedata.decimal(c, None) is not None],
    }


def string_methods(argument):
    value = text(argument)
    return {
        "repr": points(repr(value)),
        "strip": points(value.strip()),
        "lstrip": points(value.lstrip()),
        "rstrip": points(value.rstrip()),
        "split": [points(part) for part in value.split()],
        "splitlines": [points(part) for part in value.splitlines()],
        "isprintable": value.isprintable(),
    }


def bytes_repr(argument):
    return points(repr(bytes.fromhex(argument)))


def float_repr(argument):
    import struct

    return repr(struct.unpack(">d", bytes.fromhex(argument))[0])


def json_repr(argument):
    value = json.loads(text(argument))
    return {"repr": points(repr(value)), "str": points(str(value)), "type": type(value).__name__}


def json_loads(argument):
    json.loads(text(argument))
    return None


class StrictRefusal(ValueError):
    pass


def strict_pairs(pairs):
    seen = set()
    for key, _ in pairs:
        if key in seen:
            raise StrictRefusal(f"duplicate JSON field {key!r}")
        seen.add(key)
    return dict(pairs)


def refuse_constant(spelling):
    raise StrictRefusal(f"non-finite JSON number {spelling}")


def json_loads_strict(argument):
    json.loads(text(argument), object_pairs_hook=strict_pairs, parse_constant=refuse_constant)
    return None


def utf8_decode(argument):
    return points(bytes.fromhex(argument).decode("utf-8"))


def utf8_replace(argument):
    return points(bytes.fromhex(argument).decode("utf-8", "replace"))


def utf8_encode(argument):
    text(argument).encode("utf-8")
    return None


EXCEPTIONS = {
    cls.__name__: cls
    for cls in (ValueError, KeyError, RuntimeError, TypeError, UnicodeDecodeError, UnicodeEncodeError)
}


def exception_argument(argument):
    kind, value = argument
    if kind == "none":
        return None
    if kind == "bool":
        return value
    if kind == "int":
        return int(value)
    if kind == "float":
        import struct

        return struct.unpack(">d", bytes.fromhex(value))[0]
    if kind == "str":
        return text(value)
    return bytes.fromhex(value)


def exception_text(argument):
    name, arguments = argument
    error = EXCEPTIONS[name](*map(exception_argument, arguments))
    return {"repr": points(repr(error)), "str": points(str(error))}


def json_bytes(argument):
    data = bytes.fromhex(argument)
    encoding = json.detect_encoding(data)
    try:
        return {"encoding": encoding, "text": points(data.decode(encoding, "surrogatepass"))}
    except UnicodeDecodeError as error:
        return {"encoding": encoding, "error": str(error)}


def uuid4_text(argument):
    value = uuid.UUID(bytes=bytes.fromhex(argument), version=4)
    return {"str": str(value), "hex": value.hex}


OPERATIONS = {
    "unicode": unicode_tables,
    "string": string_methods,
    "bytes-repr": bytes_repr,
    "float-repr": float_repr,
    "json-repr": json_repr,
    "json-loads": json_loads,
    "json-loads-strict": json_loads_strict,
    "utf8-decode": utf8_decode,
    "utf8-replace": utf8_replace,
    "utf8-encode": utf8_encode,
    "exception": exception_text,
    "json-bytes": json_bytes,
    "uuid4": uuid4_text,
}


def main() -> None:
    sys.setrecursionlimit(20_000)
    out = sys.stdout
    for line in sys.stdin:
        if not line.strip():
            continue
        operation, argument = json.loads(line)
        try:
            answer = ["ok", OPERATIONS[operation](argument)]
        except (ValueError, UnicodeDecodeError) as error:
            answer = ["error", str(error)]
        out.write(json.dumps(answer) + "\n")


if __name__ == "__main__":
    main()
