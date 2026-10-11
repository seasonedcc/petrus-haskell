"""Generate the HTTP-date differential corpus.

Run with the pinned reference environment from the repository root:

    upstream/hamsterdan/.venv/bin/python packages/hamsterdan-github/scripts/gen_date_corpus.py

Every row is one ``Date``, ``Expires`` or ``Last-Modified`` header value and
the outcome of hishel's ``parse_date`` on it (``email.utils.parsedate_tz``
then ``calendar.timegm``): the timestamp, ``None``, or the exception's class
and message. The values mix well-formed dates with the characters the
parser's ``str.isdigit()``, ``str.lower()`` and ``int()`` treat specially:
non-ASCII decimal digits, the superscript, circled and Ethiopic digits
``isdigit`` accepts and ``int`` refuses, case-mapped month names, and
Unicode whitespace. ``HttpCorpusSpec`` replays them through
``Hamsterdan.GitHub.Cache.parseDate``.
"""

from __future__ import annotations

import json
import random
from pathlib import Path

from hishel._utils import parse_date

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "packages" / "hamsterdan-github" / "test" / "corpus" / "dates.jsonl"
SEED = 20261011
rng = random.Random(SEED)

FIXED = [
    "Mon, 01 Jan 2024 00:00:00 GMT",
    "Sat, 01 Jan 10000 00:00:00 GMT",
    "Mon, 01 Jan 0001 00:00:00 GMT",
    "01 Jan \u1369\u1371 00:00:00 GMT",
    "01 Jan \u00b9\u00b2 00:00:00 GMT",
    "01 Jan \u2776\u2777 00:00:00 GMT",
    "01 Jan \u0661\u0669\u0669\u0669 00:00:00 GMT",
    "01 Jan x2024 00:00:00 GMT",
    "01 Jan \u1369 00:00:00 2024",
    "01 Jan \u2776 00:00:00 2024",
    "01 Jan \u00b2 00:00:00 2024",
    "01 Jan \u0662 00:00:00 2024",
    "01 JAN 2024 00:00:00",
    "01 \u1c89an 2024 00:00:00",
    "Mon 01 Jan 2024 00:00:00",
    "\u1369 Jan 2024 00:00:00",
    "01-Jan-2024 00:00:00 +0000",
    "01 Jan 2024 00.00.00",
    "garbage",
    "",
]

DAYS = ["Mon,", "mon", "MON,", "Sun,", "", "Xyz,"]
DATES = ["01", "1", "31", "\u0661", "\u00b9", "\u2460", "\u1369", "x1", "0"]
MONTHS = ["Jan", "jan", "JAN", "Dec", "December", "DECEMBER", "Ma\u0130", "Jun", "\u212aan", "j\u0430n"]
YEARS = ["2024", "24", "69", "68", "99", "100", "9999", "10000", "\u0662\u0660\u0662\u0664", "\u00b2024", "\u2461024", "\u136a\u1370", "2024,", ",", "x"]
TIMES = ["00:00:00", "23:59:59", "12:30", "1.2.3", "\u0661:\u0662:\u0663", "\u00b9:00:00", "24:00:00", "x"]
ZONES = ["GMT", "1999", "+0000", "-0800", "", "EST", "\u2460"]
SPACES = [" ", " ", " ", "  ", "\t", "\u3000", "\u00a0", "\x1c"]


def generated() -> str:
    parts = [rng.choice(DAYS), rng.choice(DATES), rng.choice(MONTHS), rng.choice(YEARS), rng.choice(TIMES), rng.choice(ZONES)]
    if rng.random() < 0.2:
        parts[1], parts[2] = parts[2], parts[1]
    if rng.random() < 0.2:
        parts[3], parts[4] = parts[4], parts[3]
    out = ""
    for part in parts:
        if part:
            out += (rng.choice(SPACES) if out else "") + part
    return out


def outcome(value: str) -> dict[str, object]:
    try:
        return {"value": value, "result": parse_date(value)}
    except Exception as error:  # noqa: BLE001 - the class is the observation
        return {"value": value, "error": [type(error).__name__, str(error)]}


def main() -> None:
    values = FIXED + [generated() for _ in range(1500)]
    with OUT.open("w", encoding="utf-8") as handle:
        for value in values:
            handle.write(json.dumps(outcome(value), separators=(",", ":")) + "\n")
    print(f"wrote {len(values)} rows to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
