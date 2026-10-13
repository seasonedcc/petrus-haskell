"""Read the committed benchmark results and check what PARITY.md claims from them.

The results live in ``packages/<pkg>/bench/RESULTS.md`` (and, for packages
that split them, ``packages/<pkg>/bench/results-*.md``). They are written by
hand: each one documents its workloads, its machine, how it was measured and
how to rerun it. This module reads only their Markdown tables.

A **ratio cell** is a table cell that starts with a ratio such as ``2.3×``,
``1.00x``, ``~2 800×`` or ``1.18× / 1.15× / 1.22×``. By convention every ratio
in these files reads "how many times faster Haskell is" (Python ÷ Haskell for
times, Haskell ÷ Python for throughputs), so a ratio below 1.0 is a row where
Haskell is slower.

Ratios that describe code that no longer runs are not results: a column whose
header says ``before``, a table under a heading that says ``before``, and a
table in a section marked ``<!-- bench: superseded -->`` (the marker applies
from its line to the next heading) hold historical numbers and are skipped.

A row's headline ratio is what counts. A column whose header is ``min`` or
starts with ``lowest``, ``slowest`` or ``worst`` holds the spread of a row
measured over several rounds (its worst single round); it is skipped too, as
is a single round's figure quoted in prose. A component whose rows sit near
1.0× should say so in its PARITY.md evidence.

    python3 scripts/bench_results.py summary         # print bench-results/summary.md
    python3 scripts/bench_results.py summary --write # rewrite it
    python3 scripts/bench_results.py summary --check # fail if it is stale
    python3 scripts/bench_results.py check-parity    # the PARITY.md bench rule below

**The PARITY.md bench rule.** A component may say ``at parity`` only if no
bench results file its evidence cites (``packages/<pkg>/bench/*.md``, linked
or quoted) has a current ratio below 1.0. A results file that also covers
other components may name them in a marker comment::

    <!-- parity: rows below 1.0× belong to "Agent WebSocket protocol", "File and URL endpoints" -->

Then its below-1.0 rows count against those components instead, and the check
only requires each named component to exist in PARITY.md, not to be ``at
parity``, and not to be the component being checked.

check-parity also names, as ``STALE evidence``, every component at parity
that cites a results file measured on code that has changed since (see
``stale_results``). That is a warning, not a failure: whether the ratios
still hold is what ``scripts/bench-gate`` measures, on request. A results
file carried forward to the current sources (``scripts/bench --carry``: the
change since does not touch the measured code paths) is current; check-parity
names the components citing one as ``CARRIED evidence``, with the commit the
figures were measured at and the carry's reason.
"""

from __future__ import annotations

import functools
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent

RATIO_START = re.compile(r"^\s*\**\s*[~≈]?\s*\d[\d\s,]*(?:\.\d+)?\s*[×x](?![A-Za-z])")
RATIO_TOKEN = re.compile(r"(\d[\d\s,]*(?:\.\d+)?)\s*[×x](?![A-Za-z])")
HEADING = re.compile(r"^#{1,6}\s+(.*)$")
EXEMPT = re.compile(r"<!--\s*parity:\s*rows below 1\.0× belong to (.*?)-->")
SUPERSEDED = re.compile(r"<!--\s*bench:\s*superseded\b")
SPREAD = re.compile(r"^(min\b|lowest|slowest|worst)", re.IGNORECASE)


class Ratio:
    def __init__(self, value: float, text: str, row: str, line: int) -> None:
        self.value = value
        self.text = text
        self.row = row
        self.line = line


def cells(line: str) -> List[str]:
    stripped = line.strip()
    if stripped.startswith("|"):
        stripped = stripped[1:]
    if stripped.endswith("|"):
        stripped = stripped[:-1]
    return [cell.strip() for cell in stripped.split("|")]


def ratio_values(cell: str) -> List[float]:
    """The ratios a cell holds, or [] when it does not start with one."""
    text = cell.replace("`", "")
    if not RATIO_START.match(text):
        return []
    values = []
    for token in RATIO_TOKEN.findall(text):
        number = token.replace(" ", "").replace(",", "")
        try:
            values.append(float(number))
        except ValueError:
            pass
    return values


def ratios(path: Path) -> List[Ratio]:
    """Every current ratio in the file's tables (historical ones skipped)."""
    lines = path.read_text(encoding="utf-8").splitlines()
    found: List[Ratio] = []
    heading = ""
    superseded = False
    header: Optional[List[str]] = None
    for number, line in enumerate(lines, 1):
        match = HEADING.match(line)
        if match:
            heading = match.group(1)
            superseded = False
            header = None
            continue
        if SUPERSEDED.search(line):
            superseded = True
            continue
        if not line.lstrip().startswith("|"):
            header = None
            continue
        row = cells(line)
        if header is None:
            header = row
            continue
        if all(re.fullmatch(r":?-{2,}:?", cell) for cell in row if cell):
            continue
        if "before" in heading.lower() or superseded:
            continue
        for index, cell in enumerate(row):
            column = header[index] if index < len(header) else ""
            if "before" in column.lower() or SPREAD.match(column):
                continue
            for value in ratio_values(cell):
                found.append(Ratio(value, cell, row[0], number))
    return found


MEASURED = re.compile(r"<!-- scripts/bench: measured sources ([0-9a-f]{16}) at ([0-9a-f]{12}) -->")


def measured(path: Path) -> Optional[Tuple[str, str]]:
    """(sources fingerprint, commit) of the results file's marker: the
    package's sources its current figures measured, and the commit they were
    at."""
    match = MEASURED.search(path.read_text(encoding="utf-8"))
    return (match.group(1), match.group(2)) if match else None


def measured_line(fingerprint: str, commit: str) -> str:
    return f"<!-- scripts/bench: measured sources {fingerprint} at {commit[:12]} -->"


# A carry records that the figures, measured at an older commit, still hold
# for later sources: the change since cannot touch the code paths they
# measure (a bounds check on another path, a doc comment). Each carry keeps
# the measured marker and adds a line after it; a later carry adds another,
# and a real rerun (`scripts/bench --stamp`) removes them all.
CARRIED = re.compile(r"<!-- scripts/bench: carried to ([0-9a-f]{16}) at ([0-9a-f]{12}): (.+?) -->\n?")


def carried(path: Path) -> List[Tuple[str, str, str]]:
    """(sources fingerprint, commit, reason) of each carry marker, oldest first."""
    return CARRIED.findall(path.read_text(encoding="utf-8"))


def carried_line(fingerprint: str, commit: str, reason: str) -> str:
    return f"<!-- scripts/bench: carried to {fingerprint} at {commit[:12]}: {reason} -->"


def current(path: Path) -> Optional[Tuple[str, str]]:
    """(sources fingerprint, commit) the file's figures stand for: the latest
    carry's, or else the measurement's."""
    carries = carried(path)
    return carries[-1][:2] if carries else measured(path)


def provenance(path: Path) -> str:
    """Where the file's figures come from: "measured at C", plus ", carried
    to D" when a carry stands for later sources."""
    marker, carries = measured(path), carried(path)
    text = f"measured at {marker[1][:7]}" if marker else "not measured"
    return text + (f", carried to {carries[-1][1][:7]}" if carries else "")


def prose(relative: str) -> bool:
    """Whether a file (path relative to its package) is prose: *.md, LICENSE,
    NOTICE."""
    return relative.endswith(".md") or relative in ("LICENSE", "NOTICE")


def counted(package: str, relative: str) -> bool:
    """Whether a file of the package (path relative to it) is one of the
    sources its benchmark measures: everything but prose (`prose`) and the
    tests (test/, differential/, upstream-tests/), except where a benchmark
    stanza compiles from those too (`benchmark_source_dirs`, added by
    `sources_fingerprint`)."""
    return not (prose(relative) or relative.startswith(("test/", "differential/", "upstream-tests/")))


# Outside the packages, what every benchmark's figures depend on: the
# dependency versions, the pinned references the twins run, and the twins'
# timing harness.
SHARED_SOURCES = ["cabal.project", "cabal.project.freeze", "upstream/", "scripts/bench_timing.py"]
STANZA = re.compile(r"^(library|benchmark|executable|test-suite|common|foreign-library)\b", re.IGNORECASE)


@functools.lru_cache(maxsize=None)
def tree(treeish: str) -> Dict[str, List[Tuple[str, str]]]:
    """Every package's files at TREEISH: package -> [(path within it, blob id)]."""
    listing = subprocess.run(
        ["git", "ls-tree", "-r", "-z", treeish, "--", "packages/"],
        cwd=ROOT, check=True, stdout=subprocess.PIPE, text=True,
    ).stdout
    files: Dict[str, List[Tuple[str, str]]] = {}
    for record in listing.split("\0"):
        if not record:
            continue
        meta, path = record.split("\t", 1)
        parts = path.split("/", 2)
        if len(parts) == 3:
            files.setdefault(parts[1], []).append((parts[2], meta.split()[2]))
    return files


@functools.lru_cache(maxsize=None)
def show(treeish: str, path: str) -> str:
    return subprocess.run(["git", "show", f"{treeish}:{path}"], cwd=ROOT, check=True,
                          stdout=subprocess.PIPE, text=True).stdout


def local_dependencies(package: str, treeish: str, packages: List[str]) -> List[str]:
    """The local packages the package's measured code builds on, transitively:
    every local package named in a stanza of its .cabal file other than a
    test suite (build-depends, build-tool-depends, and also a relative
    hs-source-dirs into a sibling), and theirs."""
    pattern = re.compile(r"(?<![\w-])(" + "|".join(re.escape(n) for n in sorted(packages, key=len, reverse=True))
                         + r")(?![\w-])")
    cabal_of = {}
    files = tree(treeish)
    for name in packages:
        cabal_of[name] = next((f"packages/{name}/{path}" for path, _ in files.get(name, [])
                               if "/" not in path and path.endswith(".cabal")), None)
    seen = {package}
    queue = [package]
    while queue:
        current = queue.pop()
        if cabal_of.get(current) is None:
            continue
        stanza = ""
        for line in show(treeish, cabal_of[current]).splitlines():
            if line and not line[0].isspace():
                match = STANZA.match(line)
                stanza = match.group(1).lower() if match else ""
                continue
            if stanza and stanza != "test-suite" and not line.strip().startswith("--"):
                for found in pattern.findall(line):
                    if found not in seen:
                        seen.add(found)
                        queue.append(found)
    return sorted(seen - {package})


SOURCE_DIRS = re.compile(r"^(\s+)hs-source-dirs\s*:(.*)$", re.IGNORECASE)


def benchmark_source_dirs(package: str, treeish: str) -> List[str]:
    """The directories the package's benchmark stanzas compile from (their
    hs-source-dirs, a value continued on more indented lines included), as
    repository paths ending in "/": its bench/, and also its test/ or a
    sibling's (`../petrus-engine/test`) where a benchmark builds on test
    modules."""
    cabal = next((path for path, _ in tree(treeish).get(package, [])
                  if "/" not in path and path.endswith(".cabal")), None)
    if cabal is None:
        return []
    found: List[str] = []
    stanza = ""
    field_indent: Optional[int] = None
    for line in show(treeish, f"packages/{package}/{cabal}").splitlines():
        if line and not line[0].isspace():
            match = STANZA.match(line)
            stanza = match.group(1).lower() if match else ""
            field_indent = None
            continue
        indent = len(line) - len(line.lstrip())
        if field_indent is not None and line.strip() and indent > field_indent and ":" not in line:
            values = line
        else:
            field_indent = None
            match = SOURCE_DIRS.match(line)
            if stanza != "benchmark" or not match:
                continue
            field_indent = len(match.group(1))
            values = match.group(2)
        for value in values.replace(",", " ").split():
            directory = os.path.normpath(f"packages/{package}/{value.strip(chr(34))}")
            found.append(directory.rstrip("/") + "/")
    return sorted(set(found))


def sources_fingerprint(package: str, treeish: str = "HEAD") -> str:
    """A hash of what the package's figures measured, as committed at TREEISH
    (paths and git blob ids, so content, not timestamps): the package's
    measured sources (`counted`), every file but prose in the directories its
    benchmark stanzas compile from (`benchmark_source_dirs`: its test/ or a
    sibling's, where a benchmark builds on test modules), the measured
    sources of every local package it builds on (`local_dependencies`, their
    benchmarks aside), and SHARED_SOURCES."""
    files = tree(treeish)
    entries = [f"packages/{package}/{path}\0{blob}\n" for path, blob in files.get(package, [])
               if counted(package, path)]
    compiled = tuple(benchmark_source_dirs(package, treeish))
    for owner, owned in files.items():
        entries += [f"packages/{owner}/{path}\0{blob}\n" for path, blob in owned
                    if f"packages/{owner}/{path}".startswith(compiled) and not prose(path)]
    for dependency in local_dependencies(package, treeish, sorted(files)):
        entries += [f"packages/{dependency}/{path}\0{blob}\n" for path, blob in files.get(dependency, [])
                    if counted(dependency, path) and not path.startswith("bench/")]
    shared = subprocess.run(["git", "ls-tree", "-r", "-z", treeish, "--", *SHARED_SOURCES], cwd=ROOT, check=True,
                            stdout=subprocess.PIPE, text=True).stdout
    for record in shared.split("\0"):
        if record:
            meta, path = record.split("\t", 1)
            entries.append(f"{path}\0{meta.split()[2]}\n")
    return hashlib.sha256("".join(sorted(set(entries))).encode()).hexdigest()[:16]


def stale_results() -> Dict[Path, str]:
    """The results files whose fingerprint (`sources_fingerprint`) differs
    from the one their figures stand for (`current`: the latest carry, or the
    measurement), with their `provenance`."""
    found: Dict[Path, str] = {}
    fingerprints: Dict[str, str] = {}
    for path in results_files():
        marker = current(path)
        package = path.parent.parent.name
        if package not in fingerprints:
            fingerprints[package] = sources_fingerprint(package)
        if marker and marker[0] != fingerprints[package]:
            found[path] = provenance(path)
    return found


def results_files() -> List[Path]:
    files = sorted(ROOT.glob("packages/*/bench/RESULTS.md"))
    files += sorted(ROOT.glob("packages/*/bench/results-*.md"))
    return sorted(files, key=lambda p: (p.parent.parent.name, p.name != "RESULTS.md", p.name))


def fmt(value: float) -> str:
    if value >= 100:
        return f"{value:,.0f}×".replace(",", " ")
    if value >= 10:
        return f"{value:.1f}×"
    return f"{value:.2f}×"


def summary() -> str:
    lines = [
        "# Benchmark summary",
        "",
        "Generated by `scripts/bench --summary` from the committed results files;",
        "`scripts/check-all` fails when this file is stale. Each results file",
        "documents its workloads, machine, method and rerun command",
        "(`scripts/bench <package>` runs that command).",
        "",
        "A ratio is how many times faster Haskell is than the pinned Python (or",
        "Node, for `petrus-viewer-server`) on that row; below 1.0× Haskell is",
        "slower. Historical columns and tables (marked *before*) are left out.",
        "",
        "*Measured at* is the commit whose package sources the file's figures",
        "measured (its `scripts/bench: measured` marker). *carried to* names the",
        "later commit whose sources they were carried to without a rerun (its",
        "`scripts/bench: carried` marker gives the reason: the change since does",
        "not touch the measured code paths). `scripts/bench --stale` lists the",
        "files whose package sources have changed since.",
        "",
        "| Package | Results | Measured at | Rows | Worst | Best | |",
        "| --- | --- | --- | ---: | ---: | ---: | --- |",
    ]
    below = []
    for path in results_files():
        found = ratios(path)
        package = path.parent.parent.name
        link = f"[{path.name}](../{path.relative_to(ROOT).as_posix()})"
        marker, carries = measured(path), carried(path)
        at = f"`{marker[1][:7]}`" if marker else "—"
        if carries:
            at += f", carried to `{carries[-1][1][:7]}`"
        if not found:
            lines.append(f"| `{package}` | {link} | {at} | 0 | — | — | no ratio table |")
            continue
        worst = min(found, key=lambda r: r.value)
        best = max(found, key=lambda r: r.value)
        flag = ""
        if worst.value < 1.0:
            slow = sorted({r.row for r in found if r.value < 1.0})
            flag = "**below 1.0×**: " + "; ".join(slow)
            below.append(package)
        rows = len({r.line for r in found})
        lines.append(f"| `{package}` | {link} | {at} | {rows} | {fmt(worst.value)} | {fmt(best.value)} | {flag} |")
    lines += [
        "",
        f"{len(results_files())} results files; "
        + (f"{len(below)} with a row below 1.0×." if below else "none with a row below 1.0×."),
        "",
    ]
    return "\n".join(lines)


def parity_rows(text: str) -> List[Tuple[str, str, str]]:
    """(component, status, evidence) for every table row of PARITY.md."""
    rows = []
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        parts = cells(line)
        if len(parts) < 5 or parts[0] in ("Component", "---"):
            continue
        rows.append((parts[0], parts[3], parts[4]))
    return rows


def check_parity() -> int:
    text = (ROOT / "PARITY.md").read_text(encoding="utf-8")
    rows = parity_rows(text)
    statuses: Dict[str, str] = {component: status for component, status, _ in rows}
    problems = []
    for component, status, evidence in rows:
        if not status.startswith("at parity"):
            continue
        cited = sorted(set(re.findall(r"packages/[\w.-]+/bench/[\w.-]+\.md", evidence)))
        for relative in cited:
            path = ROOT / relative
            if not path.exists():
                problems.append(f"{component}: cites {relative}, which does not exist")
                continue
            slow = [r for r in ratios(path) if r.value < 1.0]
            if not slow:
                continue
            content = path.read_text(encoding="utf-8")
            exempt = EXEMPT.search(content)
            if exempt:
                owners = re.findall(r'"([^"]+)"', exempt.group(1))
                bad = [o for o in owners if o not in statuses or statuses[o].startswith("at parity") or o == component]
                if owners and not bad:
                    continue
                problems.append(
                    f"{component}: {relative} attributes its rows below 1.0× to {owners}, "
                    f"but {bad} {'is' if len(bad) == 1 else 'are'} missing from PARITY.md, at parity, or this component"
                )
                continue
            detail = "; ".join(f"line {r.line} `{r.row}` {r.text}" for r in slow[:5])
            problems.append(f"{component}: at parity, but {relative} has rows below 1.0× ({detail})")
    if problems:
        print("PARITY.md claims parity against slower benchmark results:", file=sys.stderr)
        for problem in problems:
            print("  " + problem, file=sys.stderr)
        return 1
    stale = stale_results()
    on_stale, on_carried = [], []
    for component, status, evidence in rows:
        if not status.startswith("at parity"):
            continue
        cited = sorted(set(re.findall(r"packages/[\w.-]+/bench/[\w.-]+\.md", evidence)))
        old = [f"{c} ({stale[ROOT / c]})" for c in cited if ROOT / c in stale]
        if old:
            on_stale.append(f"{component}: {', '.join(old)}")
        kept = [f"{c} ({provenance(ROOT / c)}: {carried(ROOT / c)[-1][2]})" for c in cited
                if ROOT / c not in stale and (ROOT / c).exists() and carried(ROOT / c)]
        if kept:
            on_carried.append(f"{component}: {', '.join(kept)}")
    if on_stale:
        print(f"STALE evidence: {len(on_stale)} components at parity cite benchmark results measured on code that has"
              " changed since (`scripts/bench --stale`); their ratios are not current:", file=sys.stderr)
        for line in on_stale:
            print("  " + line, file=sys.stderr)
            if os.environ.get("GITHUB_ACTIONS"):
                print(f"::warning file=PARITY.md::stale benchmark evidence: {line}")
    if on_carried:
        print(f"CARRIED evidence: {len(on_carried)} components at parity cite benchmark results carried forward"
              " from an older measurement, for the reason given:", file=sys.stderr)
        for line in on_carried:
            print("  " + line, file=sys.stderr)
    return 0


def main(argv: List[str]) -> int:
    if argv[:1] == ["summary"]:
        generated = summary()
        target = ROOT / "bench-results" / "summary.md"
        if "--write" in argv:
            target.write_text(generated, encoding="utf-8")
        elif "--check" in argv:
            current = target.read_text(encoding="utf-8") if target.exists() else ""
            if current != generated:
                print("bench-results/summary.md is stale: run scripts/bench --summary", file=sys.stderr)
                return 1
        else:
            sys.stdout.write(generated)
        return 0
    if argv[:1] == ["check-parity"]:
        return check_parity()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
