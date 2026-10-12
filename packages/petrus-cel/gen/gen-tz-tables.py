#!/usr/bin/env python3
"""
Generate ``src/Petrus/Cel/Tz/Tables.hs`` for ``petrus-cel``.

cel-python's ``get*`` accessors take a time zone name and hand it to
``pendulum.timezone``, which is ``zoneinfo.ZoneInfo`` under another name.
With an empty ``TZPATH`` ZoneInfo reads every zone from the ``tzdata``
package, and the pinned reference pins that package (2026.3, IANA 2026c).
This script embeds that package exactly as ZoneInfo sees it:

* every directory (each is a Python package, with its ``__init__.py``), so
  the Haskell side can follow ``load_tzdata``'s dotted import of the key's
  directories;
* every resource file, with the ZoneInfo it loads to, or the exception text
  ``ZoneInfo`` raises on it (``zone.tab``, ``__init__.py`` ...);
* every distinct zone, pre-parsed as CPython's C ``_zoneinfo`` holds it: the
  offset before the first transition (``ttinfo_before``: the first
  non-DST ttinfo), the transitions with the offset each one starts, and the
  rule after the last one (the TZ string footer, parsed by
  ``zoneinfo._zoneinfo._parse_tz_str``, or the last ttinfo when there is no
  footer).

Only offsets matter: the ``get*`` accessors read the local wall clock of
``astimezone``, which is ``dt + utcoffset`` in ``fromutc``.

Run it with the pinned upstream interpreter, from the repository root:

    upstream/petrus/.venv/bin/python -I -B packages/petrus-cel/gen/gen-tz-tables.py

``scripts/check-corpora`` reruns it and fails when the output differs.
``__pycache__`` directories are skipped: they are not part of the package as
installed, only of a package that has since been imported (DIVERGENCES.md).
"""

from __future__ import annotations

import hashlib
import io
import sys
import zoneinfo
from importlib import resources
from pathlib import Path
from zoneinfo import _common, _zoneinfo

import tzdata

OUT = Path(__file__).resolve().parent.parent / "src" / "Petrus" / "Cel" / "Tz" / "Tables.hs"


def walk(directory, prefix, dirs, files):
    for entry in sorted(directory.iterdir(), key=lambda e: e.name):
        if entry.name == "__pycache__":
            continue
        key = prefix + entry.name
        if entry.is_dir():
            if not entry.joinpath("__init__.py").is_file():
                sys.exit(f"{key} is not a regular package: dotted imports would differ")
            dirs.append(key)
            walk(entry, key + "/", dirs, files)
        else:
            files[key] = entry.read_bytes()


def seconds(delta) -> int:
    total = delta.days * 86400 + delta.seconds
    if delta.microseconds:
        sys.exit(f"sub-second offset {delta!r}")
    return total


def rule(offset) -> str:
    """A transition rule of a TZ string, as ``J``/``N`` day or ``M`` date
    plus the time of day in seconds (which may be negative or past 24h)."""
    time = offset.hour * 3600 + offset.minute * 60 + offset.second
    if isinstance(offset, _zoneinfo._DayOffset):
        return f"{'J' if offset.julian else 'N'}{offset.d}@{time}"
    if isinstance(offset, _zoneinfo._CalendarOffset):
        return f"M{offset.m}.{offset.w}.{offset.d}@{time}"
    sys.exit(f"unknown rule {offset!r}")


def zone_entry(data: bytes) -> str:
    trans_idx, trans_utc, utcoff, isdst, _abbr, tz_str = _common.load_data(io.BytesIO(data))
    if not utcoff:
        sys.exit("a zone without ttinfos")
    # C _zoneinfo: the first non-DST ttinfo, else the first ttinfo.
    before = next((off for off, dst in zip(utcoff, isdst) if not dst), utcoff[0])
    if tz_str:
        after = _zoneinfo._parse_tz_str(tz_str.decode())
        if isinstance(after, _zoneinfo._ttinfo):
            after_text = f"F{seconds(after.utcoff)}"
        else:
            after_text = (
                f"R{seconds(after.std.utcoff)},{seconds(after.dst.utcoff)},{rule(after.start)},{rule(after.end)}"
            )
    else:
        last = utcoff[trans_idx[-1]] if trans_idx else utcoff[-1]
        after_text = f"F{last}"
    offsets = sorted(set(utcoff[i] for i in trans_idx))
    index = {off: i for i, off in enumerate(offsets)}
    previous = 0
    steps = []
    for when, idx in zip(trans_utc, trans_idx):
        steps.append(f"{when - previous}:{index[utcoff[idx]]}")
        previous = when
    return f"{before}|{after_text}|{','.join(map(str, offsets))}|{' '.join(steps)}"


def chunks(text: str, width: int = 96) -> list[str]:
    return [text[i : i + width] for i in range(0, len(text), width)] or [""]


def literal(name: str, doc: list[str], text: str) -> list[str]:
    lines = [f"-- | {doc[0]}"] + [f"-- {line}" for line in doc[1:]]
    lines += [f"{name} :: String", f"{name} ="]
    parts = chunks(text)
    for i, part in enumerate(parts):
        escaped = part.replace("\\", "\\\\").replace('"', '\\"')
        opening = '  "' if i == 0 else "    \\"
        closing = '"' if i == len(parts) - 1 else "\\"
        lines.append(opening + escaped + closing)
    return lines + [""]


def main() -> None:
    zoneinfo.reset_tzpath(to=[])
    root = resources.files("tzdata").joinpath("zoneinfo")
    dirs: list[str] = []
    files: dict[str, bytes] = {}
    walk(root, "", dirs, files)

    zones: dict[str, int] = {}
    zone_texts: list[str] = []
    errors: list[str] = []
    entries: list[str] = []
    for key in sorted(files):
        if any(c in key for c in " =!;") or not key.isascii():
            sys.exit(f"unexpected resource name {key!r}")
        try:
            zoneinfo.ZoneInfo.no_cache(key)
        except ValueError as error:
            message = str(error)
            if message not in errors:
                errors.append(message)
            entries.append(f"{key}!{errors.index(message)}")
            continue
        digest = hashlib.sha256(files[key]).hexdigest()
        if digest not in zones:
            zones[digest] = len(zone_texts)
            zone_texts.append(zone_entry(files[key]))
        entries.append(f"{key}={zones[digest]}")

    lines = [
        "-- | GENERATED by gen/gen-tz-tables.py -- do not edit.",
        "--",
        f"-- The IANA time zone database {tzdata.IANA_VERSION}, as the pinned reference's",
        f"-- tzdata {tzdata.__version__} package holds it: {len(dirs)} directories, {len(files)} resources,",
        f"-- {len(zone_texts)} distinct zones, {sum(t.count(':') for t in zone_texts)} transitions.",
        "module Petrus.Cel.Tz.Tables",
        "  ( tzdataVersion",
        "  , tzDirectories",
        "  , tzResources",
        "  , tzErrors",
        "  , tzZones",
        "  ) where",
        "",
        "-- | The IANA release and the tzdata package version.",
        "tzdataVersion :: (String, String)",
        f'tzdataVersion = ("{tzdata.IANA_VERSION}", "{tzdata.__version__}")',
        "",
    ]
    lines += literal("tzDirectories", ["The package's directories, space-separated."], " ".join(dirs))
    lines += literal(
        "tzResources",
        [
            "Every resource file, space-separated: @path=N@ loads zone @N@ of",
            "'tzZones'; @path!N@ raises @ValueError@ with message @N@ of 'tzErrors'.",
        ],
        " ".join(entries),
    )
    lines += ["-- | The @ValueError@ messages of resources that are not zones.", "tzErrors :: [String]", f"tzErrors = {errors!r}".replace("'", '"'), ""]
    lines += literal(
        "tzZones",
        [
            "The distinct zones, @;@-separated, each",
            "@before|after|offsets|transitions@: the offset (seconds) before the",
            "first transition; the rule after the last one (@F@offset, or",
            "@R@std,dst,start,end with @J@day, @N@day or @M@m.w.d rules and their",
            "@\\@@time in seconds); the distinct offsets the transitions start;",
            "and the transitions as @delta:offsetIndex@, the delta being seconds",
            "since the previous transition (the first since the Unix epoch).",
        ],
        ";".join(zone_texts),
    )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")
    rules = sorted({t.split("|")[1] for t in zone_texts if t.split("|")[1].startswith("R")})
    print(f"{len(zone_texts)} zones, {len(rules)} distinct DST rules", file=sys.stderr)
    for r in rules:
        if "J" in r or "N" in r:
            print("day rule:", r, file=sys.stderr)


if __name__ == "__main__":
    main()
