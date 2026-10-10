# petrus-engine: parity with the Python reference

This package holds the provider-neutral Engine (`Petrus.Engine`, the
reference's `petrus.engine.Engine`) and its asynchronous Coordinator
(`Petrus.Engine.Coordinator`, the reference's `_coordination.py`). It also
holds the provider seam (`Petrus.Engine.Provider`) and the observation seam
(`Petrus.Engine.Observation`). The SQLite, Postgres and Absurd compositions
are not here; they plug into the provider seam.

Every Hspec example is named after the upstream test it ports. A
parametrized test becomes a `describe` with one example per case. To
cross-check that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

It reports 239 in-scope upstream tests across the three runtime packages,
with 0 unaccounted.

`cabal test petrus-engine` runs 197 examples, with 0 failures and 0 pending.
That count includes 3 Engine interop examples against the reference process.
Those are pending only when `upstream/petrus/.venv` is not synced.

## Summary by upstream file

| upstream file | Haskell spec(s) | ported | partial or analog | enforced by types |
| --- | --- | ---: | ---: | ---: |
| engine/test_engine.py (28) | EngineSpec (30 examples) | 23 | 5 | 0 |
| engine/test_coordinator.py, 35 of 42 | CoordinatorSpec (37 examples) | 35 | 0 | 0 |
| engine/test_execution.py (134) | ExecutionSpec, DeliveryPhasesA/B/CSpec (127 examples) | 98 | 10 | 26 |

`TestInMemoryDispatch` (5) and `TestInlineDispatch` (2) from
test_coordinator.py are ported in `petrus-motus`.

**Statuses:**

- **ported**: the same scenario with the same assertions. Refusal messages
  are compared in full, or as the regex's ordered literal fragments.
- **partial or analog**: the test's observable half is ported, and the
  half the types rule out is listed below.
- **enforced by types**: the test cannot be written in Haskell. Most of these
  build a `str`, `int`, `NetPath`, `LifecycleScope` or record *subclass*
  that lies about its value. Haskell's types are closed, so nothing can
  pose as a `Text`, `Int` or record.

## Partial or analog (15)

These are in test_engine.py:

- `test_engine_alone_owns_composed_source_delivery`: the evidence is that
  `Engine.deliver` is used at its full type. The kernel's
  `Petrus.Impetus.Instance` has no `deliver`, and a test cannot assert an
  absence.
- `test_engine_is_the_concrete_live_composition_with_only_universal_doors`:
  all 17 doors are referenced at their types. `Engine()` direct construction
  is impossible, because the type is abstract. `snapshot`, `net_document` and
  `history_page` are on the observation seam (DIVERGENCES.md, item 3).
- `test_engine_module_owns_configuration_outcome_and_policy_vocabulary`: the
  vocabulary is referenced at its types. There is no `__all__` reflection.
- `test_activity_policy_resolution_belongs_to_engine_and_snapshots_declarations`:
  `declarations.clear()` cannot be written, because declarations are
  immutable.
- `test_close_is_hosting_only_idempotent_and_hands_out_no_mutable_collaborator`:
  the `hasattr` handle checks don't apply, because the Engine exports no
  fields.

These are in test_execution.py:

- `TestDelivery.test_requires_a_stable_identity_at_parcel_construction`: the
  empty-identity `ValueError` is ported. The missing-argument `TypeError` is
  ruled out by the constructor's arity.
- `TestDelivery.test_rejects_a_string_payload_and_snapshots_a_sequence`: the
  sequence half is ported. A string payload does not type-check.
- `test_completion_detaches_its_outcome_before_the_terminal_batch_commits`:
  the `__deepcopy__` ordering cannot be written. The committed outcome, its
  `TokensProduced` and the final `FiringCompleted` are checked.
- `test_acceptance_refuses_mutable_token_color_before_history_mutation`: a
  color is `Maybe Text`. The check is that prior History is preserved.
- `test_completion_validates_handler_output_before_copy_protocols_can_normalize_it`:
  there is no `str` subclass. The check is that a well-formed color commits.
- `test_completion_refuses_a_mutated_occurrence_alias_before_it_can_redirect`:
  there is no `int` subclass. The check is that both acceptances resume in
  flight as `[1, 2]`.
- `test_acceptance_carrier_refuses_a_non_string_identity_before_completion`,
  `test_acceptance_carrier_refuses_an_instance_identity_subclass_at_construction`,
  and `test_acceptance_carrier_refuses_an_occurrence_subclass_at_construction`:
  the value-level refusals of the same constructor are ported. Those are an
  empty identity, an empty instance identity, and occurrence -1, each with
  the reference's message.
- `test_load_refuses_a_failure_with_a_string_subclass_before_redelivery_acknowledgement`:
  a `str` subclass with a lying `len` cannot be written. The equivalent
  property is ported: a `FiringFailed` error of 4 097 characters is refused
  with the same message, and the file is unchanged.

The test `test_process_interruption_after_acceptance_resumes_only_that_occurrence`
is ported as true cross-process interop. The reference process accepts a
delivery and exits with `os._exit(23)`. The Haskell Engine then loads the
JSONL and completes only that occurrence.

## Enforced by types (26)

In `TestEngineDrivesTheSeam`:

- `test_initial_token_color_subclass_is_refused_before_history_is_written`:
  a color is `Text`, so there is no `str` subclass.
- `test_noncopyable_opaque_initial_token_remains_valid_for_the_in_memory_writer`
  and `test_load_detaches_opaque_initial_token_data_exactly_once`: token data
  is `Json`. It has no object identity and no `__deepcopy__`.
- `test_activity_scalar_subclass_is_refused_before_history_mutation_and_remains_loadable`
  and `test_activity_policy_scalar_subclass_is_refused_before_history_mutation`:
  there are no `str` or `int` subclasses.
- `test_load_refuses_noncanonical_activity_input_before_dispatch`: the check
  is tuple versus list, and `Json` has no tuples.

In `TestIdentifiedDeliveryPhases`:

- `test_composed_delivery_requires_stable_identity_before_history_mutation`:
  `Engine.deliver` takes a `Text` identity, so neither a missing identity nor
  `None` can be passed.
- `test_load_refuses_a_history_record_subclass_before_reading_its_fields`:
  `Record` is a closed sum type.
- `test_load_refuses_a_queue_identity_subclass_before_reconstruction`: queue
  entries are `Int`.
- `test_load_refuses_a_mutated_delivery_identity_before_it_can_split_redelivery_authority`:
  an immutable `Text` has no alternate hash.
- `test_reserved_identity_subclass_is_rejected_before_mutation`,
  `test_changed_scope_subclass_is_rejected_before_redelivery_judgment`,
  `test_changed_lifecycle_scope_subclass_is_rejected_before_redelivery_judgment`,
  `test_changed_lifecycle_generation_subclass_is_rejected_before_redelivery_judgment`,
  `test_net_path_subclass_is_rejected_before_durable_acceptance`, and
  `test_seal_rejects_a_source_subclass_before_mutation`: these need
  `str`, `LifecycleScope`, `int` or `NetPath` subclasses, which don't exist.
- `test_completion_refuses_a_non_acceptance_carrier_before_mutation`:
  `completeDelivery` takes an `AcceptedDelivery`.
- `test_projection_failure_replaces_object_identity_with_a_stable_type_marker`:
  a handler failure carries text, never an `object()`.
- `test_projection_refuses_a_registration_key_subclass_without_corrupting_durable_authority`
  and `test_projection_refuses_a_registration_subclass_before_reading_its_fields`:
  the key is exact `Text`, and the registration is a closed record.
- `test_completion_refuses_an_acceptance_subclass_before_it_can_redirect_the_occurrence`:
  `AcceptedDelivery` is a closed record.
- `test_acceptance_carrier_refuses_a_boolean_occurrence_before_completion`:
  the occurrence is an `Int`.

In `TestDelivery`:

- `test_requires_an_exact_scope_type_at_parcel_construction`: there is no
  `str` or `LifecycleScope` subclass.

In `TestEngineSenses`:

- `test_sensor_refuses_a_delivery_subclass_before_reading_its_fields`:
  `Delivery` is a closed record with no attribute interception.
- `test_sensed_source_subclass_cannot_rewrite_its_address_before_acceptance`:
  `NetPath` is opaque.

In `TestEngineRefusesABrokenSensor`:

- `test_none_is_not_an_empty_answer`: a `Sensor` is `IO [Delivery]`, so it
  cannot answer `None`.

## Out of scope

| upstream file | reason |
| --- | --- |
| engine/test_observation.py (19), engine/test_observation_http.py (7) | `petrus-observation`. The Engine exposes the seam (`Petrus.Engine.Observation.observeEngine`). |
| engine/test_simulation.py (19), engine/test_simulation_http.py (24) | `petrus.simulation`, built on the DSL |
| engine/test_sqlite_engine.py (5), engine/test_postgres_engine.py (12) | the durable provider compositions. They plug into `Petrus.Engine.Provider`. |

## Beyond upstream

- **Engine interop with the reference process** (InteropSpec, 3 examples).
  They use the order scenario (`test/interop/engine_interop.py`):
  identified deliveries, a pure handler, an Activity charge, and a `Delay 5`
  settlement.
  - The same scenario writes byte-identical JSONL in both implementations.
  - An Instance the reference left mid-flight resumes here to the
    reference's own resumed bytes. Reconcile redispatches the outbox, and
    prepare never re-runs.
  - An Instance this side left mid-flight is byte-identical to the
    reference's crash. It resumes in the reference to the bytes this side
    resumes to.
- **Joined-transaction fate.** It is exercised through the provider seam,
  with a test transactional History (`TestSupport.TransactionalHistory`)
  that counts commits and rollbacks and can refuse a numbered commit.
- **Benchmarks** against the reference, in `bench/RESULTS.md`.
