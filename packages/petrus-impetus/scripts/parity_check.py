"""Cross-check PARITY.md's claim that every in-scope upstream test is accounted for.

Run from the repository root:

    python3 packages/petrus-impetus/scripts/parity_check.py

For every ``def test_*`` in the in-scope upstream files it looks for the
function name in the Haskell specs (the ``-- test_name`` comment above each
``it``, or an ``enforced by types`` comment) and in the ``parity-*.md``
ledgers, and prints per-file counts plus every name found nowhere. The exit
status is non-zero when a name is unaccounted for.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
UPSTREAM = ROOT / "upstream" / "petrus" / "tests"
PACKAGE = ROOT / "packages" / "petrus-impetus"

# Files outside the port's scope: the DSL, CEL itself, and durable stores
# other than the in-memory one.
OUT_OF_SCOPE = {
    "petrus/impetus/dsl/test_petrinet_dsl.py": "the DSL is out of scope",
    "petrus/impetus/binding/test_cel.py": "CEL is a separate package (petrus-cel)",
    "petrus/impetus/history_store/test_postgres_history.py": "durable stores other than in-memory are out of scope",
    "petrus/impetus/history_store/test_sqlite_history.py": "durable stores other than in-memory are out of scope",
}
EXTRA = ["integration/test_activity_seam.py"]


def upstream_files() -> list[Path]:
    files = sorted((UPSTREAM / "petrus" / "impetus").rglob("test_*.py"))
    return files + [UPSTREAM / name for name in EXTRA]


def main() -> int:
    haystack = "\n".join(p.read_text() for p in (PACKAGE / "test").rglob("*.hs"))
    haystack += "\n".join(p.read_text() for p in PACKAGE.glob("parity-*.md"))
    missing = 0
    total = 0
    for path in upstream_files():
        relative = str(path.relative_to(UPSTREAM))
        names = re.findall(r"^\s*def (test_\w+)", path.read_text(), re.M)
        if relative in OUT_OF_SCOPE:
            print(f"{len(names):4}  {relative}: out of scope — {OUT_OF_SCOPE[relative]}")
            continue
        total += len(names)
        absent = [name for name in names if not re.search(rf"\b{name}\b", haystack)]
        missing += len(absent)
        print(f"{len(names):4}  {relative}" + (f"  UNACCOUNTED: {', '.join(absent)}" if absent else ""))
    print(f"{total} in-scope upstream tests, {missing} unaccounted")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
