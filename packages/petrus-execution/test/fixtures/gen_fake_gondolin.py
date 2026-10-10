"""Regenerate ``fake_gondolin.mjs`` from upstream's ``fake_sdk`` pytest fixture.

The fake Gondolin SDK lives inline in
``upstream/petrus/tests/petrus/motus/test_gondolin_environment.py`` as the
``textwrap.dedent`` argument of the ``fake_sdk`` fixture.  This script
extracts that exact string (after Python string-literal processing and
dedent, i.e. byte-for-byte what upstream writes to ``fake-gondolin.mjs``)
so the Haskell suite drives the verbatim sidecar with the verbatim fake.

Run from the repository root:

    upstream/petrus/.venv/bin/python packages/petrus-execution/test/fixtures/gen_fake_gondolin.py
"""

from __future__ import annotations

import ast
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "upstream/petrus/tests/petrus/motus/test_gondolin_environment.py"
TARGET = Path(__file__).with_name("fake_gondolin.mjs")


def main() -> None:
    tree = ast.parse(SOURCE.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "fake_sdk":
            for call in ast.walk(node):
                if (
                    isinstance(call, ast.Call)
                    and isinstance(call.func, ast.Attribute)
                    and call.func.attr == "dedent"
                ):
                    literal = call.args[0]
                    assert isinstance(literal, ast.Constant) and isinstance(literal.value, str)
                    TARGET.write_text(textwrap.dedent(literal.value))
                    return
    raise SystemExit("fake_sdk fixture not found")


if __name__ == "__main__":
    main()
