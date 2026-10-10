"""Cross-check that every in-scope upstream test of the runtime packages is accounted for.

Run from the repository root:

    python3 packages/petrus-engine/scripts/parity_check.py

Covers petrus-motus, petrus-history-store, petrus-engine, petrus-history-postgres, and\npetrus-engine-postgres. Every Hspec example
is named after the upstream test it ports (``test_a_b_c`` becomes ``it "a b c"``,
under ``describe "TestClass"``; a parametrized test becomes ``describe "a b c"``
with one example per case), so a test is accounted for when:

- an example in the package's test tree spells the same words (punctuation and
  case are ignored, and a trailing parameter suffix like ``[jsonl]`` is allowed); or
- the package's PARITY.md names it as ``Class.test_name`` or ``test_name``
  (renamed examples, tests enforced by types, and tests not at parity).

It prints per-scope counts plus every name found nowhere, and the exit status is
non-zero when a name is unaccounted for.
"""

from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
UPSTREAM = ROOT / "upstream" / "petrus" / "tests"


class Excluding(frozenset):
    """A scope's tests named by exclusion: every test but these."""


# The Engine-level tests of test_local_dispatch.py live in petrus-engine.
LOCAL_ENGINE_TESTS = {
    "test_engine_reconciles_canonical_request_missing_from_local_custody",
    "test_engine_close_fences_claimed_local_attempt_and_canonically_quarantines_its_late_result",
    "test_engine_recollects_terminal_result_after_canonical_acceptance_refusal",
}

# package -> [(upstream file, classes in scope or None for all,
#              tests in scope or None for all, or Excluding(tests out of scope))]
SCOPES: dict[str, list[tuple[str, set[str] | None, set[str] | Excluding | None]]] = {
    "petrus-motus": [
        ("petrus/engine/test_coordinator.py", {"TestInMemoryDispatch", "TestInlineDispatch"}, None),
        ("integration/test_activity_seam.py", {"TestInlineDispatch"}, None),
        (
            "petrus/motus/dispatch/test_attempt_heartbeats.py",
            None,
            {"test_inline_context_has_synthetic_identity_and_detached_omitted_null_details"},
        ),
        ("petrus/motus/dispatch/test_local_dispatch.py", None, Excluding(LOCAL_ENGINE_TESTS)),
    ],
    "petrus-history-store": [
        ("petrus/impetus/history_store/test_persistence.py", {"TestDurableAppend", "TestJsonlHistoryStore"}, None),
        ("petrus/impetus/history_store/test_history_backends.py", None, None),
    ],
    "petrus-engine": [
        ("petrus/engine/test_engine.py", None, None),
        (
            "petrus/engine/test_coordinator.py",
            {
                "TestConservativePolicy",
                "TestThroughputPolicy",
                "TestOneActionDrive",
                "TestConcurrentInFlight",
                "TestSelectionDurability",
                "TestLateCompletionsThroughCollect",
                "TestConservativePolicyParity",
                "TestSensedIngress",
                "TestReconcileThenDrive",
            },
            None,
        ),
        ("petrus/engine/test_execution.py", None, None),
        ("petrus/motus/dispatch/test_local_dispatch.py", None, LOCAL_ENGINE_TESTS),
    ],
    "petrus-history-postgres": [
        ("petrus/impetus/history_store/test_postgres_history.py", None, None),
        ("petrus/impetus/history_store/test_history_backends.py", None, None),
        (
            "project/test_package_boundaries.py",
            None,
            {
                "test_canonical_history_store_facade_does_not_import_optional_postgres_driver",
                "test_postgres_history_store_is_explicit_and_preserves_missing_extra_guidance",
            },
        ),
    ],
    "petrus-engine-postgres": [
        ("petrus/engine/test_postgres_engine.py", None, None),
        ("project/test_package_boundaries.py", None, {"test_postgres_history_provider_returns_only_the_neutral_engine"}),
    ],
}


def words(text: str) -> tuple[str, ...]:
    return tuple(re.sub(r"[^a-z0-9]+", " ", text.lower()).split())


def upstream_tests(
    relative: str, classes: set[str] | None, names: set[str] | Excluding | None
) -> list[tuple[str, str]]:
    tree = ast.parse((UPSTREAM / relative).read_text())
    found: list[tuple[str, str]] = []
    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            for member in node.body:
                if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)) and member.name.startswith("test_"):
                    found.append((node.name, member.name))
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_"):
            found.append(("", node.name))
    return [
        (cls, name)
        for cls, name in found
        if (classes is None or cls in classes)
        and (names is None or (name not in names if isinstance(names, Excluding) else name in names))
    ]


def examples(package: Path) -> list[tuple[str, ...]]:
    texts: list[tuple[str, ...]] = []
    for source in (package / "test").rglob("*.hs"):
        for match in re.finditer(r'\b(?:it|describe) \(?"([^"]+)"', source.read_text()):
            texts.append(words(match.group(1)))
    return texts


def ported(name: str, texts: list[tuple[str, ...]]) -> bool:
    wanted = words(name.removeprefix("test_"))
    return any(text[: len(wanted)] == wanted for text in texts)


def main() -> int:
    missing = 0
    total = 0
    for package_name, scopes in SCOPES.items():
        package = ROOT / "packages" / package_name
        texts = examples(package)
        parity_file = package / "PARITY.md"
        parity = parity_file.read_text() if parity_file.exists() else ""
        print(package_name)
        for relative, classes, names in scopes:
            tests = upstream_tests(relative, classes, names)
            by_name = sum(1 for _, name in tests if ported(name, texts))
            absent = [
                f"{cls}.{name}" if cls else name
                for cls, name in tests
                if not ported(name, texts) and not re.search(rf"\b{name}\b", parity)
            ]
            total += len(tests)
            missing += len(absent)
            label = relative + (f" [{', '.join(sorted(classes))}]" if classes else "")
            if isinstance(names, Excluding):
                label += f" [all but {len(names)}]"
            elif names is not None and classes is None:
                label += f" [{len(names)} named]"
            in_ledger = len(tests) - by_name - len(absent)
            print(f"  {len(tests):4}  {label}: {by_name} by example name, {in_ledger} in PARITY.md")
            for name in absent:
                print(f"        UNACCOUNTED: {name}")
    print(f"{total} in-scope upstream tests, {missing} unaccounted")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
