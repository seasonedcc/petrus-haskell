"""The time-zone differential of ``test/Live.hs``, run by the pinned
reference's interpreter (``python -I -c <this file> SEED``).

For every key a ``get*`` accessor can be given (every tzdata resource and
directory, and keys mutated from zone names) and a set of instants, it
prints one JSON line ``[key, instant, outcome]``: what cel-python answers
for ``[timestamp(s).getFullYear(z), timestamp(s).getDayOfYear(z),
timestamp(s).getHours(z), timestamp(s).getMinutes(z),
timestamp(s).getSeconds(z)]``. The outcome is that list's ``repr``, or the
``repr`` of the exception the expression raises.

The instants are drawn with ``random.Random(SEED)`` between years 1 and
9999, plus, for each zone, the instants on both sides of transitions from
its table (the first, the last and a sample) and of the transitions its TZ
string rule makes in a few years past the table.

ZoneInfo reads the pinned tzdata package only (``TZPATH`` is emptied), the
package petrus-cel embeds. Keys that differ from a file only in letter case
are never generated: a case-insensitive file system finds them.
"""

import io
import json
import random
import sys
import zoneinfo
from datetime import datetime, timedelta, timezone
from importlib import resources
from zoneinfo import _common, _zoneinfo

import celpy
import celpy.evaluation
from celpy import celtypes

zoneinfo.reset_tzpath(to=[])
celpy.evaluation.Activation.__repr__ = lambda self: "<Activation>"

GETTERS = ["getFullYear", "getDayOfYear", "getHours", "getMinutes", "getSeconds"]
EXPRESSION = "[" + ", ".join(f"timestamp(s).{g}(z)" for g in GETTERS) + "]"
ENV = celpy.Environment()
PROGRAM = ENV.program(ENV.compile(EXPRESSION))
LOW = -62135596800  # 0001-01-01T00:00:00Z
HIGH = 253402300799  # 9999-12-31T23:59:59Z
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)

rng = random.Random(int(sys.argv[1]))


def iso(seconds: int, micros: int = 0) -> str:
    moment = EPOCH + timedelta(seconds=seconds, microseconds=micros)
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + (f".{micros:06d}" if micros else "") + "Z"


def random_instant() -> str:
    return iso(rng.randint(LOW, HIGH), rng.choice([0, 0, rng.randint(0, 999999)]))


def outcome(key: str, instant: str) -> str:
    stamp = celtypes.TimestampType(instant)
    name = celtypes.StringType(key)
    try:
        # The accessors the expression calls, without celpy's tree walk.
        values = [getattr(stamp, getter)(name) for getter in GETTERS]
        return "ListType([" + ", ".join(f"IntType({int(v)})" for v in values) + "])"
    except Exception:
        try:
            return repr(PROGRAM.evaluate({"s": celtypes.StringType(instant), "z": name}))
        except Exception as error:
            return repr(error)


def edges(data: bytes) -> list[int]:
    _idx, trans_utc, _off, _dst, _abbr, tz_str = _common.load_data(io.BytesIO(data))
    trans = [t for t in trans_utc if LOW < t <= HIGH]
    points = set()
    picks = trans[:2] + trans[-3:] + (rng.sample(trans, 6) if len(trans) > 6 else trans)
    for t in picks:
        points |= {t - 1, t}
    if tz_str:
        rule = _zoneinfo._parse_tz_str(tz_str.decode())
        if isinstance(rule, _zoneinfo._TZStr):
            last_year = (EPOCH + timedelta(seconds=trans[-1])).year if trans else 1970
            for year in {last_year, last_year + 1, rng.randint(last_year + 1, 9998), 9998}:
                start, end = rule.transitions(year)
                start -= int(rule.std.utcoff.total_seconds())
                end -= int(rule.dst.utcoff.total_seconds())
                points |= {t for t in (start - 1, start, end - 1, end) if LOW < t <= HIGH}
    return sorted(points)


def walk(directory, prefix, dirs, files):
    for entry in directory.iterdir():
        if entry.name == "__pycache__":
            continue
        if entry.is_dir():
            dirs.append(prefix + entry.name)
            walk(entry, prefix + entry.name + "/", dirs, files)
        else:
            files[prefix + entry.name] = entry.read_bytes()


def mutations(key: str) -> list[str]:
    parts = key.split("/")
    out = [
        "/" + key, key + "/", "./" + key, key.replace("/", "//"), key.replace("/", "/./"), "x/../" + key,
        key + "\x00", key[:-1], key + " ", " " + key, key + "\n", "__init__/" + key, key + "\ud800",
        key + "\udcff", key + ".py", key.replace("/", "."), "../" + key,
    ]
    if len(parts) > 1:
        out += [
            "/".join(p.lower() for p in parts[:-1]) + "/" + parts[-1],
            ".".join(parts[:-1]) + "/" + parts[-1],
            "/".join(parts[:-1]) + "/__init__/" + parts[-1],
            "/".join(parts[:-1]) + ".__init__/" + parts[-1],
            "/".join(parts[:-1]) + "\x00/" + parts[-1],
            "/".join(parts[:-1]),
        ]
    return out


def main() -> None:
    dirs: list[str] = []
    files: dict[str, bytes] = {}
    walk(resources.files("tzdata").joinpath("zoneinfo"), "", dirs, files)
    names = set(files) | set(dirs)
    shared = [random_instant() for _ in range(64)]
    jobs: list[tuple[str, str]] = []
    zones = []
    for key in sorted(files):
        try:
            _common.load_data(io.BytesIO(files[key]))
        except ValueError:
            jobs += [(key, rng.choice(shared)) for _ in range(2)]
            continue
        zones.append(key)
        instants = {rng.choice(shared) for _ in range(4)} | {random_instant() for _ in range(2)}
        instants |= {iso(t) for t in edges(files[key])}
        jobs += [(key, instant) for instant in sorted(instants)]
    jobs += [(key, rng.choice(shared)) for key in dirs]
    lowered = {n.lower() for n in names}
    for key in rng.sample(zones, 80):
        for mutated in mutations(key):
            # Never a key a case-insensitive file system would resolve
            # differently from a case-sensitive one.
            if mutated.lower() in lowered and mutated not in names:
                continue
            jobs += [(mutated, rng.choice(shared)) for _ in range(2)]
    for key in ["utc", "UTC", "uTC", "Utc", "+05:30", "-5:00", "05:30", "+24:00", "-24:00", "+99:59", "-30:00", "Etc/GMT+12", "Etc/GMT-14", "Etc/GMT+13"]:
        jobs += [(key, rng.choice(shared)) for _ in range(2)]
    out = sys.stdout
    for key, instant in jobs:
        out.write(json.dumps([key, instant, outcome(key, instant)]) + "\n")


main()
