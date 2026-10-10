"""Python side of the hamsterdan-readiness benchmarks (same inputs as Main.hs).

    PYTHONDONTWRITEBYTECODE=1 upstream/hamsterdan/.venv/bin/python -I \
        packages/hamsterdan-readiness/bench/bench.py

Reads the test corpora next to this package (test/corpus/folds.jsonl and
board.jsonl), so it can run from any directory. Results and the Haskell
side are in RESULTS.md.

Prints the time per pass (best of 5 timeit repeats; each repeat runs the
pass enough times to take about half a second).
"""

from __future__ import annotations

import json
import timeit
from pathlib import Path

from petrus.impetus.petrinet import Binding, NetPath, Token

from hamsterdan.readiness.net_v5.board import gate_facts, render_board
from hamsterdan.readiness.net_v5.topology import build_net_v5

CORPUS = Path(__file__).resolve().parents[1] / "test" / "corpus"


def rows(name: str) -> list[dict]:
    with (CORPUS / name).open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


built = build_net_v5()


def call(row: dict) -> tuple:
    transition = NetPath(row["transition"])
    handler = built.handlers[built.net.handler_uri(transition)]

    def selections(key: str) -> tuple:
        return tuple((NetPath(place), tuple(Token(c, d) for c, d in tokens)) for place, tokens in row[key])

    binding = Binding(
        transition=transition,
        consumed=selections("consumed"),
        read=selections("read"),
        delivered=tuple(Token(c, d) for c, d in row["delivered"]),
    )
    return row["transition"].split(".", 1)[0], handler, binding, built.net.outputs(transition)


CALLS = [call(row) for row in rows("folds.jsonl") if row["call"] == "fold"]
LOGS = [row["entries"] for row in rows("board.jsonl")]


def fold_all(calls: list) -> None:
    for _, handler, binding, outputs in calls:
        try:
            handler(binding, outputs)
        except Exception:
            pass


def each(function, logs: list) -> None:
    for entries in logs:
        try:
            function(entries)
        except Exception:
            pass


def cases() -> dict:
    found = {f"folding/every corpus fold ({len(CALLS)} calls)": lambda: fold_all(CALLS)}
    for loop in dict.fromkeys(loop for loop, *_ in CALLS):
        mine = [c for c in CALLS if c[0] == loop]
        found[f"folding/{loop} folds ({len(mine)} calls)"] = lambda mine=mine: fold_all(mine)
    found[f"board/render_board over every corpus log ({len(LOGS)} logs)"] = lambda: each(render_board, LOGS)
    found[f"board/gate_facts over every corpus log ({len(LOGS)} logs)"] = lambda: each(gate_facts, LOGS)
    return found


def main() -> None:
    for name, case in cases().items():
        trial = timeit.timeit(case, number=1)
        number = max(1, int(0.5 / max(trial, 1e-9)))
        best = min(timeit.repeat(case, number=number, repeat=5)) / number
        print(f"{name:60s} {best * 1e3:10.3f} ms")


if __name__ == "__main__":
    main()
