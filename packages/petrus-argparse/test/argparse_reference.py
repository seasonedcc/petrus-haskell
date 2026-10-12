"""CPython 3.14's argparse over the parsers and cases the Haskell suite sends.

Usage: ``python -B -P argparse_reference.py < query.json > results.json``.

The query is ``{"parsers": [PARSER, ...], "cases": [CASE, ...]}``. A PARSER
is ``{"prog", "description", "actions": [ACTION, ...]}``, the actions after
the automatic ``-h/--help``, each the keywords of one ``add_argument`` call
(or of ``add_subparsers`` and its ``add_parser`` calls). A CASE is ``{"parser":
index, "argv": [...], "env": {...}, "tty": bool}``. For each case the process
environment is replaced by ``env``, standard output is a terminal when
``tty`` is set (a pseudo-terminal's descriptor), and ``parse_args`` runs
with stdout and stderr captured. The result is ``{"code", "stdout",
"stderr", "namespace"}``, where the namespace is ``[[dest, repr(value)],
...]`` sorted by ``dest`` (a ``Path`` as its ``str``), or null when the
parser exited.

The interpreter runs without ``-I`` or ``-E``, as ``python -m`` does, so
``PYTHON_COLORS`` counts.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import pathlib
import sys

TYPES = {"str": None, "int": int, "float": float, "path": pathlib.Path}


def add_actions(parser: argparse.ArgumentParser, actions: list[dict]) -> None:
    for action in actions:
        if action["action"] == "subparsers":
            group = parser.add_subparsers(dest=action["dest"], required=True)
            for name, sub_actions in action["parsers"]:
                add_actions(group.add_parser(name), sub_actions)
            continue
        keywords: dict[str, object] = {}
        if action["action"] != "store":
            keywords["action"] = action["action"]
        if TYPES.get(action["type"]) is not None:
            keywords["type"] = TYPES[action["type"]]
        for key in ("choices", "help", "metavar"):
            if action[key] is not None:
                keywords[key] = action[key]
        if "default" in action:
            keywords["default"] = action["default"]
        if action["strings"]:
            if action["required"]:
                keywords["required"] = True
            keywords["dest"] = action["dest"]
            parser.add_argument(*action["strings"], **keywords)
        else:
            parser.add_argument(action["dest"], **keywords)


def build(spec: dict) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=spec["prog"], description=spec["description"])
    add_actions(parser, spec["actions"])
    return parser


class Terminal(io.StringIO):
    def __init__(self, descriptor: int) -> None:
        super().__init__()
        self.descriptor = descriptor

    def fileno(self) -> int:
        return self.descriptor


def value_repr(value: object) -> str:
    if isinstance(value, pathlib.PurePath):
        return repr(str(value))
    if isinstance(value, list):
        return "[" + ", ".join(value_repr(item) for item in value) + "]"
    return repr(value)


def run(parsers: list[dict], case: dict, terminal: int) -> dict:
    os.environ.clear()
    os.environ.update(case["env"])
    out = Terminal(terminal) if case["tty"] else io.StringIO()
    err = io.StringIO()
    code = 0
    namespace = None
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            parsed = build(parsers[case["parser"]]).parse_args(case["argv"])
            namespace = sorted([dest, value_repr(value)] for dest, value in vars(parsed).items())
        except SystemExit as exit:
            code = exit.code
    return {"code": code, "stdout": out.getvalue(), "stderr": err.getvalue(), "namespace": namespace}


def main() -> None:
    query = json.load(sys.stdin)
    _, terminal = os.openpty()
    results = [run(query["parsers"], case, terminal) for case in query["cases"]]
    sys.stdout.write(json.dumps(results))


if __name__ == "__main__":
    main()
