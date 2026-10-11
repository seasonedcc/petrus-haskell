"""Render the reference test_codex.py fakes as placeholder templates.

The reference builds its fake ``codex`` CLI and fake Gondolin SDK module with
``fake_codex(tmp_path, version)`` and ``fake_gondolin_sdk(tmp_path,
executable)``. This script calls those exact functions and replaces the
per-run values with placeholders the Haskell specs fill in:

* ``fake_codex.py``: ``__PYTHON__`` (shebang interpreter) and
  ``__VERSION__`` (the reported ``codex-cli`` version).
* ``fake_gondolin_codex.mjs``: ``__CODEX__``, ``__UNAME__`` and
  ``__STARTED__`` (each a JSON string literal of a path).

Usage, from the reference checkout (``upstream/petrus``):

    .venv/bin/python -I -B <package>/test/fixtures/codex/extract.py <package>/test/fixtures/codex
"""

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path.cwd()))

from tests.petrus.agenticus.runtime import test_codex  # noqa: E402

out = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as raw:
    tmp = Path(raw)
    executable = test_codex.fake_codex(tmp, "__VERSION__")
    source = executable.read_text()
    first, rest = source.split("\n", 1)
    if first != f"#!{sys.executable}":
        raise SystemExit("unexpected fake codex shebang")
    (out / "fake_codex.py").write_text("#!__PYTHON__\n" + rest)

    codex_path = tmp / "codex"
    module = test_codex.fake_gondolin_sdk(tmp, codex_path).read_text()
    for value, placeholder in (
        (codex_path, "__CODEX__"),
        (tmp / "fake-uname", "__UNAME__"),
        (tmp / "fake-codex-command-started", "__STARTED__"),
    ):
        literal = json.dumps(str(value))
        if module.count(literal) != 1:
            raise SystemExit(f"unexpected placeholder count for {placeholder}")
        module = module.replace(literal, placeholder)
    (out / "fake_gondolin_codex.mjs").write_text(module)
for name in ("fake_codex.py", "fake_gondolin_codex.mjs"):
    print(name, len((out / name).read_text()))
