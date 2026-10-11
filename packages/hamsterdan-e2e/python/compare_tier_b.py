"""Compare tier B replays of one tape, and the recording they came from.

    python3 compare_tier_b.py TAPE [--record ROOT] --side NAME=ROOT,LOG,REPORT ...
        [--skip-context publisher] [--allow-unused] [--render DIR]

Standard library only. Each ``--side`` is one replay: its state directory,
the replay server's log and the replay driver's report. ``--record`` adds
the recording host's state directory; its requests are the tape's own.

What must be equal on every side (docs/hamsterdan.md §5.2, tier B step 3):

- ``writes``: every POST and PATCH and every GraphQL mutation, in order.
  Between replays, the bytes each host sent; against the recording, the
  JSON values (the tape keeps values, not bytes);
- ``history``: every ``applications/*/*/*/history.jsonl``, byte for byte;
- ``comments``: the final comment set the writes leave on GitHub, rendered
  (``tape.render_comments``);
- ``state``: every other file of the state directory as tier A compares it
  (SQLite databases as their schema and sorted rows; the Worker claimant
  identity and the Local Dispatch's wall-clock columns normalized).

And what must hold on each replay: every step went as recorded; no request
was unrecorded and none of the tape's (in the replayed contexts) was left
unused; the replay runner and publisher saw no unknown key, no mismatch and
no unused record. ``--allow-unused`` lifts the last two "unused" rules, for
a live tape: its host polled on the wall clock, so a replay converging at
the recorded instants reads less than it did (the replay server answers
the extra reads with ``--sticky-reads``), and its registration requests
are replayed as the ``registry`` step. The replays must still agree with
each other exactly.

Prints a JSON report; exits 1 when anything differs or fails.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

import tape as tapes  # noqa: E402

CLAIMANT = re.compile(r"worker:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
DISPATCH_CLOCK = {
    "impetus_local_dispatch_tasks": {"deadline", "schedule_start", "attempt_start", "attempt_deadline", "available_at"},
}
SKIPPED_DIRECTORIES = {"git-world"}


def cell(value: Any, wall_clock: bool) -> Any:
    if wall_clock and value is not None:
        return "<wall-clock-ms>"
    if isinstance(value, bytes):
        return {"blob": value.hex()}
    if isinstance(value, str):
        return CLAIMANT.sub("worker:<uuid>", value)
    return value


def open_copy(path: Path, scratch: Path) -> sqlite3.Connection:
    """A private copy of a database and its WAL, opened read-write.

    A WAL database cannot be opened read-only by every SQLite without its
    shared-memory file, and opening it in place would touch the state."""
    for suffix in ("", "-wal"):
        source = Path(str(path) + suffix)
        if source.exists():
            shutil.copyfile(source, scratch / (path.name + suffix))
    return sqlite3.connect(str(scratch / path.name))


def dump_state(root: Path) -> Dict[str, Any]:
    """Every file under ROOT as tier A's ``journeys_reference.dump`` reads it."""
    files: Dict[str, Any] = {}
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = [name for name in subdirectories if name not in SKIPPED_DIRECTORIES]
        for name in names:
            path = Path(directory) / name
            relative = str(path.relative_to(root))
            if name.endswith(("-wal", "-shm", "-journal")):
                continue
            if name.endswith(".sqlite3"):
                scratch = Path(tempfile.mkdtemp(prefix="tier-b-"))
                database = open_copy(path, scratch)
                try:
                    tables = {}
                    for table, sql in database.execute(
                        "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') AND sql IS NOT NULL ORDER BY name"
                    ):
                        rows: List[Any] = []
                        if sql.startswith("CREATE TABLE"):
                            cursor = database.execute(f'SELECT * FROM "{table}"')
                            clocked = DISPATCH_CLOCK.get(table, set())
                            columns = [column[0] for column in cursor.description]
                            rows = sorted(
                                ([cell(v, c in clocked) for c, v in zip(columns, row)] for row in cursor),
                                key=lambda row: json.dumps(row, sort_keys=True),
                            )
                        tables[table] = {"sql": sql, "rows": rows}
                    files[relative] = {"user_version": database.execute("PRAGMA user_version").fetchone()[0], "tables": tables}
                finally:
                    database.close()
                    shutil.rmtree(scratch, ignore_errors=True)
            else:
                files[relative] = path.read_bytes().decode("utf-8", "backslashreplace")
    return dict(sorted(files.items()))


def histories(state: Dict[str, Any]) -> Dict[str, Any]:
    return {path: text for path, text in state.items() if re.fullmatch(r"applications/[^/]+/[^/]+/[^/]+/history\.jsonl", path)}


class Side:
    def __init__(self, name: str, root: Path) -> None:
        self.name, self.root = name, root
        self.state = dump_state(root)
        self.writes: List[Any] = []
        self.exchanges: List[Tuple[str, str, Any, Any]] = []
        self.problems: List[Any] = []


def record_side(root: Path, tape: List[Dict[str, Any]]) -> Side:
    side = Side("record", root)
    for record in tape:
        if record.get("context", "host") != "host" or "error" in record:
            continue
        side.exchanges.append((record["method"], record["path"], record["body"], record.get("response")))
        if tapes.is_mutation(record["method"], record["path"], record["body"]):
            side.writes.append([record["method"], record["path"], tapes.canonical(record["body"])])
    return side


def replay_side(
    name: str, root: Path, log: Path, report: Path, tape: List[Dict[str, Any]], skipped: Tuple[str, ...], allow_unused: bool = False
) -> Side:
    side = Side(name, root)
    by_seq = {record["seq"]: record for record in tape}
    served = set()
    for line in log.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        if entry["kind"] == "auth":
            continue
        if entry["kind"] == "unrecorded":
            side.problems.append({"unrecorded": [entry["method"], entry["path"], entry["body"]]})
        try:
            body = json.loads(entry["body"]) if entry["body"] else None
        except ValueError:
            body = entry["body"]
        if entry["tape_seq"] is not None:
            served.add(entry["tape_seq"])
            side.exchanges.append((entry["method"], entry["path"], body, by_seq[entry["tape_seq"]].get("response")))
        if tapes.is_mutation(entry["method"], entry["path"], body):
            side.writes.append([entry["method"], entry["path"], entry["body"]])
    unused = [r["seq"] for r in tape if r.get("context", "host") not in skipped and r["seq"] not in served]
    if unused and not allow_unused:
        side.problems.append({"unused_tape_requests": unused})
    document = json.loads(report.read_text())
    failed = [step for step in document["steps"] if not step["ok"]]
    if failed:
        side.problems.append({"failed_steps": failed})
    for part in ("agents", "publisher"):
        for key in ("unknown", "mismatches", "unused"):
            if key == "unused" and allow_unused:
                continue
            if document[part].get(key):
                side.problems.append({f"{part}_{key}": document[part][key]})
    return side


def first_difference(left: Any, right: Any) -> Optional[str]:
    if left == right:
        return None
    if isinstance(left, dict) and isinstance(right, dict):
        for key in sorted(set(left) | set(right)):
            if key not in left or key not in right:
                return f"{key}: only on one side"
            found = first_difference(left[key], right[key])
            if found is not None:
                return f"{key}: {found}"
    if isinstance(left, list) and isinstance(right, list):
        for index, (a, b) in enumerate(zip(left, right)):
            found = first_difference(a, b)
            if found is not None:
                return f"[{index}]: {found}"
        return f"lengths {len(left)} and {len(right)}"
    if isinstance(left, str) and isinstance(right, str):
        index = next((i for i, (a, b) in enumerate(zip(left, right)) if a != b), min(len(left), len(right)))
        return f"text differs at {index}: {left[index:index + 80]!r} / {right[index:index + 80]!r}"
    return f"{str(left)[:160]!r} / {str(right)[:160]!r}"


def compare(sides: List[Side]) -> Dict[str, Any]:
    differences: List[Dict[str, Any]] = []
    base = sides[0]
    replays = [side for side in sides if side.name != "record"]
    for side in sides[1:]:
        pairs = {
            "history": (histories(base.state), histories(side.state)),
            "state": (base.state, side.state),
            "comments": (
                tapes.render_comments(tapes.comment_set(base.exchanges)),
                tapes.render_comments(tapes.comment_set(side.exchanges)),
            ),
        }
        if base.name == "record":
            pairs["writes"] = (base.writes, [[m, p, tapes.canonical(json.loads(b)) if b else ""] for m, p, b in side.writes])
        for aspect, (left, right) in pairs.items():
            found = first_difference(left, right)
            if found is not None:
                differences.append({"aspect": aspect, "sides": [base.name, side.name], "first": found})
    if len(replays) > 1:
        for side in replays[1:]:
            found = first_difference(replays[0].writes, side.writes)
            if found is not None:
                differences.append({"aspect": "writes (bytes)", "sides": [replays[0].name, side.name], "first": found})
    problems = {side.name: side.problems for side in sides if side.problems}
    return {
        "ok": not differences and not problems,
        "differences": differences,
        "problems": problems,
        "summary": {
            side.name: {
                "writes": len(side.writes),
                "requests": len(side.exchanges),
                "history_files": len(histories(side.state)),
                "history_records": sum(text.count("\n") for text in histories(side.state).values()),
            }
            for side in sides
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("tape", type=Path)
    parser.add_argument("--record", type=Path)
    parser.add_argument("--side", action="append", default=[], help="NAME=ROOT,LOG,REPORT")
    parser.add_argument("--skip-context", action="append", default=[])
    parser.add_argument("--allow-unused", action="store_true")
    parser.add_argument("--render", type=Path)
    args = parser.parse_args()
    tapes.read_meta(args.tape)
    tape = tapes.read(args.tape, "github.jsonl")
    sides: List[Side] = []
    if args.record:
        sides.append(record_side(args.record, tape))
    for item in args.side:
        name, _, paths = item.partition("=")
        root, log, report = paths.split(",")
        sides.append(replay_side(name, Path(root), Path(log), Path(report), tape, tuple(args.skip_context), args.allow_unused))
    if len(sides) < 2:
        parser.error("compare at least two sides")
    result = compare(sides)
    if args.render:
        args.render.mkdir(parents=True, exist_ok=True)
        for side in sides:
            (args.render / f"{side.name}-comments.md").write_text(tapes.render_comments(tapes.comment_set(side.exchanges)))
    print(json.dumps(result, sort_keys=True, indent=1))
    sys.exit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
