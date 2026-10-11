# petrus-fabric: parity with the Python reference

This package ports `petrus.fabric` at the pin in
[UPSTREAM.md](../../UPSTREAM.md). The language-neutral specification is
[spec/fabric.md](../../spec/fabric.md), with 108 checks in
[spec/fabric-conformance.md](../../spec/fabric-conformance.md).

| Reference | Haskell |
| --- | --- |
| `petrus/fabric/model.py` | `Petrus.Fabric.Model`: values, limits and the canonical digest. `Petrus.Fabric.Canonical` is the canonical encoder. `Petrus.Fabric.Error` holds the §12 categories. |
| `petrus/fabric/ingress.py` | `Petrus.Fabric.Ingress`: `FabricInbox` against an abstract `DeliveryDoor`. The `petrus-fabric:engine` sublibrary (`Petrus.Fabric.Engine`) makes an Engine the door. |
| `petrus/fabric/postgres.py` | The `petrus-fabric:postgres` sublibrary (`Petrus.Fabric.Postgres`): the `impetus_fabric` schema and `PostgresFabric`. |
| the demos' `SendActivity` (fabric.md §11) | `Petrus.Fabric.Send` |
| `scripts/cv5-fabric-demo.py` | the `petrus-fabric:demo` sublibrary (`Petrus.Fabric.Demo`) and the `cv5-fabric-demo` executable |

API differences are listed in [DIVERGENCES.md](DIVERGENCES.md).

## Running

`cabal test petrus-fabric` runs 241 examples. With `PETRUS_TEST_POSTGRES` set
(CI sets it), all 241 pass. Without it, the examples that need a server are
pending and say why. Each group gets its own scratch database
(`Petrus.TestSupport.postgresSpec`), which is dropped afterwards. The Python
side runs from the pinned upstream virtual environment
(`upstream/petrus/.venv`).

| Spec module | Examples | What it checks |
| --- | ---: | --- |
| [ConformanceSpec](test/Petrus/Fabric/ConformanceSpec.hs) | 196 | The 98 unit and db checks, each run against both implementations: the Haskell port in process, and the reference through [conformance_driver.py](test/interop/conformance_driver.py). |
| [InteropSpec](test/Petrus/Fabric/InteropSpec.hs) | 12 | The 7 interop checks, each run in both directions on one database. |
| [DemoSpec](test/Petrus/Fabric/DemoSpec.hs) | 8 | The Engine checks against both implementations, the demo across implementations, and F-107: split roles in all four combinations. |
| [TypedSpec](test/Petrus/Fabric/TypedSpec.hs) | 6 | The type-enforced refusals F-005, F-007, F-008, F-076, F-080 and F-091, each against the real signature under deferred type errors. |
| [ReferenceSpec](test/Petrus/Fabric/ReferenceSpec.hs) | 13 | The upstream tests, one for one (see the ledger). |
| [CanonicalSpec](test/Petrus/Fabric/CanonicalSpec.hs) | 6 | The canonical encoder against CPython and petrus-json. |

## Conformance

All 108 checks are executable and hold for both implementations:

- the 98 unit and db checks run the same assertions against the Haskell port
  and against the pinned reference;
- the interop checks (F-038, F-046 and the others in InteropSpec) run with
  Haskell on one side and Python on the other, in both directions;
- the Engine and demo checks run against both implementations, and across
  them.

A check whose refusal the port's types enforce is answered by the Haskell
twin with an `InvalidType` refusal saying "type-enforced". TypedSpec holds
the compile-time evidence for each of those.

The spec was revised in two places to say what the pinned reference does
([fabric.md §1.1](../../spec/fabric.md)):

- how `float.__repr__` chooses among several shortest digit strings
  (§3.3). F-014 gains `1e+23` and `2.9802322387695312e-08`;
- a door refusal poisons the refusing Engine (§9.3).

## Ledger

| Upstream test | Haskell example | Status |
| --- | --- | --- |
| `test_fabric.py::test_neutral_fabric_import_does_not_attempt_psycopg` | same name | Ported over Cabal metadata: the main library depends on no PostgreSQL or Engine package. |
| `test_fabric.py::test_envelope_is_exact_versioned_detached_strict_json_and_bounded` | same name | Ported. A host object and a non-string key are type-enforced (F-007, F-008, TypedSpec). |
| `test_fabric.py::test_two_authority_process_fabric_acceptance_demo` | same name | Ported. It runs the `cv5-fabric-demo` executable. |
| `test_fabric.py::test_registration_stores_only_digest_is_idempotent_and_authenticates` | same name | Ported |
| `test_fabric.py::test_schema_provisioning_refuses_unknown_or_mismatched_versions` | same name | Ported |
| `test_fabric.py::test_fabric_operations_join_a_caller_transaction_without_committing` | same name | Ported |
| `test_fabric.py::test_discovery_and_send_are_deny_by_default_and_capability_filtered` | same name | Ported |
| `test_fabric.py::test_exact_retransmission_precedes_current_grant_and_changed_content_conflicts` | same name | Ported |
| `test_fabric.py::test_same_delivery_id_from_distinct_senders_has_distinct_ingress_identity` | same name | Ported |
| `test_fabric.py::test_inbox_delivery_acceptance_and_prior_acknowledgement_crash_recovery` | same name | Ported |
| `test_fabric.py::test_acknowledgement_occurrence_conflicts` | same name | Ported. `True` as an occurrence is type-enforced (F-080). |
| `test_fabric.py::test_pruning_removes_envelope_but_preserves_receipt_dedup_and_conflict` | same name | Ported. A naive cutoff is type-enforced (F-091). |
| `test_package_boundaries.py::test_cv5_demos_host_only_through_public_engine_doors` (fabric demo) | same name (`cv5-fabric-demo`) | Ported over the demo module's imports and qualified uses. |
| `test_conventions.py::test_concept_rules_name_canonical_forbidden_dependencies` (`history-store-postgres-provider-boundary.yml` forbids `fabric`) | — | Belongs to `petrus-history-postgres`, which depends on no Fabric package. |

That is 12 of 12 `test_fabric.py` tests, plus the fabric half of the one
project-level test that names the fabric demo.

## Interop

Python and Haskell share one `impetus_fabric` schema and message each other:

- **Schema.** A schema provisioned by either side is a no-op for the other,
  and the catalogs are identical (F-038).
- **Registration and authentication.** A process registered by either side
  authenticates from the other.
- **Messaging.** Envelopes submitted by either side are read, delivered and
  acknowledged by the other, with identical digests and ingress identities.
  Retransmissions are duplicates across languages, and changed content
  conflicts.
- **Receipts, discovery and pruning.** These cross over as well.
- **The demo.** The demo's parent and child roles can each be either
  implementation, in all four combinations (F-107, DemoSpec). This also
  covers the `fabric.send` Activity profile in both directions.

The evidence is [InteropSpec](test/Petrus/Fabric/InteropSpec.hs) and
[DemoSpec](test/Petrus/Fabric/DemoSpec.hs), driven by
[conformance_driver.py](test/interop/conformance_driver.py) and
[fabric_demo_mixed.py](test/interop/fabric_demo_mixed.py).

The golden vectors are checked against both implementations: the mixed
canonical vector (F-012), key order (F-013), float spellings (F-014), the
digest vectors (F-026), and the §15 worked examples. CanonicalSpec also
compares the canonical encoder with CPython's `json.dumps` byte for byte on
more than 100000 doubles and on escaped strings and keys.

## Performance

[bench/RESULTS.md](bench/RESULTS.md), in wall-clock time: Haskell is 2.2×
faster on the 16 KiB canonical encoding and 6–10× on envelope work. The store
operations are round trips to the server and come out level: 0.86×
(`postgres.discover`) to 1.09×, with `postgres.submit` at 0.97×. Earlier
figures of 3.7–4.1× there were tasty-bench CPU time, which leaves out the
wait for the server.
