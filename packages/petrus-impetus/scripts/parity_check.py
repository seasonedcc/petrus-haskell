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

# Files this package does not port because another package of this
# repository does, with its own ledger: the DSL, CEL, and the durable stores
# other than the in-memory one.
OUT_OF_SCOPE = {
    "petrus/impetus/dsl/test_petrinet_dsl.py": "ported in petrus-dsl (packages/petrus-dsl/PARITY.md)",
    "petrus/impetus/binding/test_cel.py": "ported in petrus-cel (packages/petrus-cel/PARITY.md)",
    "petrus/impetus/history_store/test_postgres_history.py": "ported in petrus-history-postgres (packages/petrus-history-postgres/PARITY.md)",
    "petrus/impetus/history_store/test_sqlite_history.py": "ported in petrus-history-store (packages/petrus-history-store/PARITY.md)",
}
EXTRA = ["integration/test_activity_seam.py"]
# Files shared with other packages: only these functions are this package's.
# The other rows of test_package_boundaries.py (engine, dispatch, worker,
# transports, the PostgreSQL History store) are ported by the packages that
# own those subjects.
SELECTED = {
    "project/test_package_boundaries.py": {
        "test_lazy_root_surface_remains_discoverable_without_optional_imports",
        "test_implementation_and_maintained_consumers_import_defining_modules_not_project_root",
        "test_canonical_petrinet_and_binding_facades",
        "test_canonical_instance_facade_has_no_root_or_deep_compatibility_alias",
        "test_petrinet_import_does_not_load_forbidden_layers",
        "test_petrinet_owns_binding_and_history_independent_firing",
        "test_removed_flat_deep_modules_are_not_speculative_shims",
    },
}


def upstream_files() -> list[Path]:
    files = sorted((UPSTREAM / "petrus" / "impetus").rglob("test_*.py"))
    return files + [UPSTREAM / name for name in EXTRA + list(SELECTED)]


def main() -> int:
    haystack = "\n".join(p.read_text() for p in (PACKAGE / "test").rglob("*.hs"))
    haystack += "\n".join(p.read_text() for p in PACKAGE.glob("parity-*.md"))
    missing = 0
    total = 0
    for path in upstream_files():
        relative = str(path.relative_to(UPSTREAM))
        names = re.findall(r"^\s*def (test_\w+)", path.read_text(), re.M)
        if relative in SELECTED:
            unknown = SELECTED[relative] - set(names)
            if unknown:
                print(f"{relative}: SELECTED names missing upstream: {', '.join(sorted(unknown))}")
                return 1
            print(f"      ({len(names) - len(SELECTED[relative])} other functions of {relative} belong to other packages)")
            names = [name for name in names if name in SELECTED[relative]]
        if relative in OUT_OF_SCOPE:
            print(f"{len(names):4}  {relative}: {OUT_OF_SCOPE[relative]}")
            continue
        total += len(names)
        absent = [name for name in names if not re.search(rf"\b{name}\b", haystack)]
        missing += len(absent)
        print(f"{len(names):4}  {relative}" + (f"  UNACCOUNTED: {', '.join(absent)}" if absent else ""))
    print(f"{total} in-scope upstream tests, {missing} unaccounted")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
