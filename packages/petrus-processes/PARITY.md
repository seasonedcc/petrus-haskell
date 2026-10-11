# petrus-processes: parity with the Python reference

This package ports `petrus.processes` (process `call` and `spawn`) at the pin
in [UPSTREAM.md](../../UPSTREAM.md). The language-neutral specification is
[spec/processes.md](../../spec/processes.md), with 80 checks in
[spec/processes-conformance.md](../../spec/processes-conformance.md). It
builds on [petrus-fabric](../petrus-fabric/PARITY.md).

| Reference | Haskell |
| --- | --- |
| `petrus/processes/call.py` | `Petrus.Processes.Call` |
| `petrus/processes/model.py` | `Petrus.Processes.Model` |
| `petrus/processes/spawn.py` | `Petrus.Processes.Spawn` (`spawnActivity`, the registry and provisioner ports) |
| `petrus/processes/postgres.py` | the `petrus-processes:postgres` sublibrary (`Petrus.Processes.Postgres`): the `impetus_lifecycle` schema and the lineage registry, plus the §13.2 reference provisioning profile |
| `scripts/cv5-lifecycle-demo.py` | the `petrus-processes:demo` sublibrary (`Petrus.Processes.Demo`) and the `cv5-lifecycle-demo` executable |

API differences are listed in [DIVERGENCES.md](DIVERGENCES.md).

## Running

`cabal test petrus-processes` runs 223 examples. With `PETRUS_TEST_POSTGRES`
set (CI sets it), all 223 pass. Without it, the examples that need a server
are pending and say why. The suite compiles in petrus-fabric's conformance
harness (`../petrus-fabric/test`) and drives the reference through the same
[conformance_driver.py](../petrus-fabric/test/interop/conformance_driver.py).

| Spec module | Examples | What it checks |
| --- | ---: | --- |
| [ConformanceSpec](test/Petrus/Processes/ConformanceSpec.hs) | 134 | The 67 unit and db checks, each run against both implementations. |
| [InteropSpec](test/Petrus/Processes/InteropSpec.hs) | 6 | P-038, P-079 and P-080, each run in both directions on one database. |
| [DemoSpec](test/Petrus/Processes/DemoSpec.hs) | 62 | P-037 against both implementations. The lifecycle demo in six configurations, with one example per check its output evidences (P-032–P-036, P-038, P-075–P-079). |
| [TypedSpec](test/Petrus/Processes/TypedSpec.hs) | 1 | The type-enforced refusal P-055, against the real signature under deferred type errors. |
| [ReferenceSpec](test/Petrus/Processes/ReferenceSpec.hs) | 20 | The upstream tests, one for one (see the ledger). |

The six demo configurations are:

- the Haskell executable alone;
- a Haskell parent with a Python child (P-038);
- a Haskell parent with the `process.spawn` Activity executed by the Python
  worker (P-079);
- a Python parent with a Haskell child (P-038);
- a Python parent with a Haskell `process.spawn` worker (P-079);
- a Python parent with both.

## Conformance

All 80 checks are executable and hold for both implementations:

- the 67 unit and db checks run the same assertions against the Haskell
  port and against the pinned reference;
- P-037 runs on both implementations' Engines;
- the interop and demo checks run with Haskell and Python on either side.

The spec was revised in one place to say what the pinned reference does
([processes.md §1.1](../../spec/processes.md)). A reply refused because its
reply source has no armed registration also poisons the refusing Engine, and
the host continues through a fresh load (§7, P-037).

## Ledger

| Upstream test | Haskell example | Status |
| --- | --- | --- |
| `test_processes.py::test_neutral_process_import_attempts_neither_psycopg_nor_runtime_layers` | same name | Ported over Cabal metadata: the main library depends on no PostgreSQL or Engine package. |
| `test_processes.py::test_spawn_spec_is_exact_detached_strict_and_fully_digested` | same name | Ported |
| `test_processes.py::test_child_identity_is_stable_parent_scoped_and_not_spec_scoped` | same name | Ported |
| `test_processes.py::test_spawn_outcome_and_provisioning_refuse_cross_identity_values` | same name | Ported |
| `test_processes.py::test_call_values_are_exact_detached_and_provider_neutral` | same name | Ported |
| `test_processes.py::test_call_envelopes_are_correlated_addressed_and_share_one_terminal_reply_identity` | same name | Ported |
| `test_processes.py::test_call_helpers_refuse_mismatched_correlation_sender_and_reply_owner` | same name | Ported |
| `test_processes.py::test_spawn_activity_claims_before_ensure_and_reensures_an_exact_retry` | same name | Ported. "No credential attribute" holds because `Provisioning` has no such field. |
| `test_processes.py::test_spawn_activity_refuses_wrong_activity_idempotency_or_registry_identity` | same name | Ported |
| `test_processes.py::test_spawn_activity_refuses_a_live_object_from_the_provisioner` | same name | Type-enforced (P-055). The example runs TypedSpec's ill-typed provisioner and expects the deferred `TypeError`. |
| `test_processes.py::test_lifecycle_schema_is_mapping_only_versioned_and_refuses_unknown_shapes` | same name | Ported |
| `test_processes.py::test_lifecycle_schema_provisioning_does_not_commit_the_callers_transaction` | same name | Ported |
| `test_processes.py::test_postgres_registry_requires_autocommit_and_authentication` | same name | Ported |
| `test_processes.py::test_postgres_claim_is_durable_exact_conflict_detecting_and_queryable` | same name | Ported |
| `test_processes.py::test_lineage_queries_are_parent_bound` | same name | Ported |
| `test_processes.py::test_concurrent_exact_claims_converge_on_one_row` | same name | Ported, with real concurrent connections. |
| `test_processes.py::test_failed_provision_after_claim_retries_the_same_claim` | same name | Ported |
| `test_processes.py::test_call_result_and_error_share_fabric_conflict_identity` | same name | Ported |
| `test_processes.py::test_process_lifecycle_acceptance_demo` | same name | Ported. It runs the `cv5-lifecycle-demo` executable. |
| `test_package_boundaries.py::test_cv5_demos_host_only_through_public_engine_doors` (lifecycle demo) | same name (`cv5-lifecycle-demo`) | Ported over the demo module's imports and qualified uses. |

That is 19 of 19 `test_processes.py` tests, plus the lifecycle half of the
one project-level test that names the lifecycle demo.

## Interop

Python and Haskell share one `impetus_fabric` and one `impetus_lifecycle`
schema, and call and spawn each other.

- **Calls.** A caller in either implementation and a callee in the other
  complete a result round trip and an error round trip. Each side validates
  the other's envelopes under §5 (P-038, InteropSpec, and the demo with
  mixed parent and child).
- **Spawns.** The `process.spawn` Activity's outcome is the same JSON from
  either implementation (P-079). A spawn attempted in one and retried in the
  other converges on one lineage row (P-080). The demo's parent spawns
  children through a `process.spawn` worker of the other implementation, in
  both directions.
- **Replies, failures and lifecycle rows.** These behave the same across the
  pairs: unrelated replies (P-033), correlated errors (P-035), offline
  callees (P-032), lost spawn completions (P-077), replay (P-036), credential
  absence (P-075), and unarmed replies (P-037).
- **Cancellation.** Version 1 has none (processes.md §7), so there is
  nothing to cross over.
- **Golden vectors.** These are checked against both implementations: the
  §8 call digests (P-009, P-011, P-012), the child identity vectors (P-046),
  and the §15 spawn bytes and digest (P-045, P-058).

## Performance

[bench/RESULTS.md](bench/RESULTS.md), in wall-clock time: Haskell is 2.9–15×
faster on values and the Activity. The registry operations are round trips
to the server: 1.21–1.65×, and `postgres.child-of` level at 0.97×. Earlier
figures of 3–5.5× there were tasty-bench CPU time, which leaves out the wait
for the server.
