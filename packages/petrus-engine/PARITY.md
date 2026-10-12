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

It also reads the ledgers of petrus-engine-absurd (all of
`test_worker_topology.py`, over Absurd custody) and petrus-motus-absurd (its
`test_package_boundaries.py` rows), and `scripts/check-all` runs it. At the
current pin it reports 460 in-scope upstream tests (439 distinct: some tests
are ported both over Local and over Absurd custody), all accounted for.

`cabal test petrus-engine` runs 226 examples, with 0 failures and 0 pending.
That count includes 3 Engine interop examples against the reference process,
and 3 Worker topology pairings with reference Engines and Workers, and 5
checks of spec obligations no upstream test covers (below).
They provision the reference through `scripts/upstream-python` and fail,
never go pending, when it cannot be provisioned.

## Summary by upstream file

| upstream file | Haskell spec(s) | ported | partial or analog | enforced by types |
| --- | --- | ---: | ---: | ---: |
| engine/test_engine.py (28) | EngineSpec (35 examples) | 23 | 5 | 0 |
| engine/test_coordinator.py, 35 of 42 | CoordinatorSpec (39 examples) | 35 | 0 | 0 |
| engine/test_execution.py (134) | ExecutionSpec, DeliveryPhasesA/B/CSpec (127 examples) | 98 | 10 | 26 |
| motus/dispatch/test_local_dispatch.py, the 3 Engine-level tests | LocalDispatchSpec (4 examples) | 3 | 0 | 0 |
| motus/worker/test_worker_runtime.py, the Engine-level test (byte-identical inline and Local History) | WorkerTopologySpec (1 example, over the order net) | 0 | 1 | 0 |
| motus/worker/test_worker_topology.py, 4 Worker cases of 36 | WorkerTopologySpec (4 examples, over Local Dispatch; the rest are ledgered in `petrus-motus/PARITY.md`) | 0 | 4 | 0 |
| project/test_package_boundaries.py, the 2 Engine rows and the 3 project-wide rows | BoundarySpec (5 examples; see below) | 0 | 5 | 0 |

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

## `test_package_boundaries.py`: the Engine and project-wide rows

`Petrus.Engine.BoundarySpec` checks these over package metadata and module
sources, through `Petrus.TestSupport.Boundary`. A Python import graph
becomes a Cabal dependency graph. An optional extra becomes a package that
must be depended on explicitly. The empty `petrus` project namespace
becomes the absence of a root `Petrus` module. The project-wide rows live
here because the Engine is the package every composition depends on.

| upstream test | Haskell example | how |
| --- | --- | --- |
| `test_lazy_root_surface_remains_discoverable_without_optional_imports` | lazy root surface remains discoverable without optional imports | no package exposes a root `Petrus` module, so nothing (the removed coordination vocabulary, kernel and History names, or an optional driver) is reachable through one |
| `test_implementation_and_maintained_consumers_import_defining_modules_not_project_root` | implementation and maintained consumers import defining modules, not project root | no Haskell source in any package (library, test, bench or app) imports `Petrus` |
| `test_engine_is_canonical_public_and_optional_dependency_safe` | engine is canonical public and optional dependency safe | `petrus-engine` depends on no PostgreSQL, Absurd or ZeroMQ package; `Petrus.Engine` exports `Engine`, `create`, `load` and `wait`, and no `queueFor` |
| `test_removed_flat_deep_modules_are_not_speculative_shims` | removed flat deep modules are not speculative shims | no package exposes an `Impetus` or `Impetus.*` library module |
| `test_dispatch_is_canonical_and_coordination_remains_private` | dispatch is canonical and coordination remains private | `inlineDispatch` and `inMemoryDispatch` build `Dispatch`es. `LocalDispatch` is exported by `Petrus.Motus.Dispatch.Local`, and `ActivityAttempt` is defined in `Petrus.Motus.Dispatch`. The removed adapter names are absent from the facade. `Petrus.Engine` exports the Haskell spelling of `petrus.engine.__all__`, with `Action (..)` and `simulatedClock`, and no `Coordinator` or `Runner`. The coordination lives in `Petrus.Engine.Coordinator`, with no root coordination module. |

The rows count as "partial or analog" because they check the Cabal and
module graph, not a Python import.

## Out of scope

| upstream file | reason |
| --- | --- |
| engine/test_observation.py (19), engine/test_observation_http.py (7) | `petrus-observation`, which builds the Engine's read doors (`Petrus.Observation.Engine`) on this package's seam (`Petrus.Engine.Observation.observeEngine`) and ports the Engine lock, re-entry and commit-poisoning tests against a real Engine (`petrus-observation/PARITY.md`). The re-entry test calls `Petrus.Engine.Internal.guarded`, exported for it. |
| engine/test_simulation.py (19), engine/test_simulation_http.py (24) | `petrus.simulation`, built on the DSL |
| engine/test_sqlite_engine.py (5), engine/test_postgres_engine.py (12) | the durable provider compositions. They plug into `Petrus.Engine.Provider`. |

## Beyond upstream

- **CEL under the default options** (EngineSpec, 1 example). The reference
  imports its CEL compilers unconditionally. An Engine created with
  `defaultEngineOptions` routes payments by inline CEL guards (one reads
  `getHours('America/Sao_Paulo')`) through a CEL arc filter, and completes
  on a CEL completion condition.
- **`wait` is `time.sleep`** (EngineSpec, 1 example). Without a provider
  wake hint, `wait(timeout)` sleeps as `time.sleep(timeout)` does, and
  refuses what it refuses with its classes and texts: NaN and a negative
  timeout (`ValueError`), and a timeout whose nanoseconds, rounded away
  from zero, leave the signed 64-bit range (`OverflowError`, thrown as the
  Engine's `OverflowError` exception).
- **The specification's Engine obligations** ([SPEC.md](SPEC.md)). Every
  normative statement of `spec/firing-semantics.md` §Scheduling, the
  lifecycle-scope and Activity sections of `spec/event-history.md`, and the
  activity/projection split of `spec/handler-contract.md` is mapped to the
  examples that check it. Five statements had no check through an Engine,
  and `SpecObligationsSpec` (5 examples) adds them: the immature wall-clock
  re-choice, a retry that stays in Dispatch, an opted-in failure projection
  that reloads without another Attempt, scope provenance that leaves
  correlation alone, and no quarantine reprocessing operation.

- **The DST worlds' Local Dispatch consumer shape** (LocalDispatchSpec, 1
  example). This is the shape `tests/dst/retry_world.py` and
  `generated_runtime_world.py` drive:
  - a world provider clock;
  - a wrapped dispatch door whose one-shot refusal poisons the Engine;
  - a reloaded generation that reconciles through the same door;
  - a fresh labelled worker per claim, a zero-delay retry, and the next
    `advance` collecting the terminal.

  The outcome matches the reference running the same script. The other 33
  tests of `test_local_dispatch.py` are `petrus-motus`'s (see its
  PARITY.md).
- **Engine and Worker interop** (WorkerTopologySpec, 3 examples,
  `test/interop/worker_topology_interop.py`). The order scenario's charge
  goes through a durable Local Dispatch to a Worker. The Engine and the
  Worker take turns, so the History is deterministic. The pairings
  Haskell/Python, Python/Haskell and Python/Python (Engine/Worker) each
  write the same JSONL bytes as Haskell/Haskell, and the reference loads
  that History to the settled marking.
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
  `openEngine` also refuses a joined-transaction History store whose
  provider supplies no commit point (EngineSpec, 1 example, "a
  joined-transaction store without a commit point is refused"): the
  reference would append without ever committing.
- **Benchmarks** against the reference, in `bench/RESULTS.md`.
