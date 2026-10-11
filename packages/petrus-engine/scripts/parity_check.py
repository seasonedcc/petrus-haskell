"""Cross-check that every in-scope upstream test of the runtime packages is accounted for.

Run from the repository root:

    python3 packages/petrus-engine/scripts/parity_check.py

Covers petrus-motus, petrus-motus-zeromq, petrus-history-store, petrus-engine,
petrus-engine-sqlite, petrus-history-postgres, petrus-engine-postgres,
petrus-engine-absurd and petrus-motus-absurd. Every Hspec example
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

# The Engine-level Worker tests live in petrus-engine (WorkerTopologySpec).
WORKER_ENGINE_TESTS = {
    "test_controlled_sequential_local_execution_is_byte_identical_to_inline_history",
}
TOPOLOGY_ENGINE_TESTS = {
    "test_the_activity_executes_on_the_worker_and_completes_through_server_side_projection",
    "test_sigkill_mid_activity_redispatches_on_lease_expiry_with_exactly_one_effect",
    "test_sigterm_drains_gracefully_the_in_flight_activity_completes",
    "test_the_worker_refuses_an_unregistered_activity",
}
# The Worker-registry tests of test_worker_topology.py that petrus-motus also
# ports over Local custody. petrus-engine-absurd ports the whole file over
# Absurd custody, as upstream runs it.
TOPOLOGY_MOTUS_TESTS = {
    "test_worker_and_loader_snapshot_mutable_registries",
    "test_worker_refuses_invalid_activity_registries",
    "test_main_defaults_queue_and_preserves_deduplicated_flag_order",
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
        ("petrus/motus/worker/test_worker_runtime.py", None, Excluding(WORKER_ENGINE_TESTS)),
        ("petrus/motus/worker/test_async_worker.py", None, None),
        ("petrus/motus/worker/test_worker_topology.py", None, TOPOLOGY_MOTUS_TESTS),
        (
            "project/test_package_boundaries.py",
            None,
            {
                "test_worker_package_public_contract_and_module_cli",
                "test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle",
            },
        ),
    ],
    "petrus-motus-zeromq": [
        ("petrus/motus/transport/test_zeromq_dispatch_transport.py", None, None),
        (
            "project/test_package_boundaries.py",
            None,
            {"test_zeromq_transport_base_import_is_optional_and_deep_import_has_guidance"},
        ),
    ],
    "petrus-history-store": [
        ("petrus/impetus/history_store/test_persistence.py", {"TestDurableAppend", "TestJsonlHistoryStore"}, None),
        ("petrus/impetus/history_store/test_history_backends.py", None, None),
        ("petrus/impetus/history_store/test_sqlite_history.py", None, None),
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
        ("petrus/motus/worker/test_worker_runtime.py", None, WORKER_ENGINE_TESTS),
        ("petrus/motus/worker/test_worker_topology.py", None, TOPOLOGY_ENGINE_TESTS),
        (
            "project/test_package_boundaries.py",
            None,
            {
                "test_lazy_root_surface_remains_discoverable_without_optional_imports",
                "test_implementation_and_maintained_consumers_import_defining_modules_not_project_root",
                "test_engine_is_canonical_public_and_optional_dependency_safe",
                "test_removed_flat_deep_modules_are_not_speculative_shims",
                "test_dispatch_is_canonical_and_coordination_remains_private",
            },
        ),
    ],
    "petrus-engine-sqlite": [
        ("petrus/engine/test_sqlite_engine.py", None, None),
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
    "petrus-engine-absurd": [
        ("petrus/motus/worker/test_worker_topology.py", None, None),
    ],
    "petrus-motus-absurd": [
        (
            "project/test_package_boundaries.py",
            None,
            {
                "test_dispatch_import_is_optional_dependency_safe_and_absurd_is_canonical",
                "test_absurd_dispatch_removed_name_has_no_deep_compatibility_alias",
                "test_absurd_deep_import_preserves_missing_extra_guidance",
                "test_worker_import_does_not_require_absurd_extra",
            },
        ),
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
    distinct: set[tuple[str, str, str]] = set()
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
            distinct.update((relative, cls, name) for cls, name in tests)
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
    print(f"{total} in-scope upstream tests ({len(distinct)} distinct), {missing} unaccounted")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
