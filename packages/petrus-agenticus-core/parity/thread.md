# Parity: Thread lifecycle, Agent Program descriptors, runtime foundation values

Upstream: `upstream/petrus` (`src/petrus/agenticus/{thread,program,runtime}`,
`tests/petrus/agenticus/{thread,program,runtime}`).

## Sources

| Upstream module | Haskell module | Notes |
| --- | --- | --- |
| `thread/identity.py` | `Petrus.Agenticus.Thread.Identity` | Four distinct newtypes (`ThreadId`, `ContinuationId`, `EpisodeId`, `TurnId`) behind the `LifecycleId` class; `mk*` / `literal*` constructors, `lifecycleIdToData` / `lifecycleIdFromData`. |
| `thread/continuation.py` | `Petrus.Agenticus.Thread.Continuation` | `ContinuationState`, `ContinuationDescriptor`, `Continuation` (`Show` hides `stateReference`), `claimContinuation` / `retireContinuation`, `ContinuationCodec` (record), `IncompatibleContinuationError` (carries the `CompatibilityResult`), `checkContinuationCompatibility`, `requireContinuationCompatible`. |
| `thread/lifecycle.py` | `Petrus.Agenticus.Thread.Lifecycle` | Every enum, `EpisodeBudget`, `Turn`, `Episode`, `Thread`, the four result records, every transition and every `__post_init__` invariant, in upstream order. |
| `program/descriptor.py` | `Petrus.Agenticus.Program.Descriptor` | `ProgramOwnership`, `ContinuationRequirement`, `AgentProgramDescriptor` with `to_data` / `from_data`. |
| `program/seam.py` | `Petrus.Agenticus.Program.Seam` | `ProgramSeams directive trace evaluation`; steering and evaluator are `IO` functions. |
| `runtime/installation.py` | `Petrus.Agenticus.Runtime.Installation` | `ProbeDisposition`, `InstalledComponent`, `ProbeIssue`, `RuntimeInstallation`, `RuntimeProbeResult`. |
| `runtime/result.py` | `Petrus.Agenticus.Runtime.Result` | `safeTerminationCode`, `RuntimeTurnSettlement` (`Show` hides both references). |
| `runtime/operation.py` | `Petrus.Agenticus.Runtime.Operation` | `RuntimeCleanupDisposition`, `RuntimeOperationCleanup`, `cleanupVerified`, `runtimeProtocolError` / `runtimeProtocolErrorCode`, `RuntimeOperation` (record of `IO` functions with the Protocol's documented semantics). |

Shared helpers live in `Petrus.Agenticus.Internal.Shape` (`StrEnum`,
`_identity_of_kind`, schema-version and lifecycle-integer checks, the
`[a-z][a-z0-9.-]{0,127}` machine-token match).

## Tests

Every upstream test function is ported under
`describe "<dir>/<file>.py"` with the upstream name.

| Upstream test | Haskell | Status |
| --- | --- | --- |
| `thread/test_continuation.py::test_compatibility_table_never_infers_cross_program_portability` | `ThreadSpec` | ported |
| `thread/test_continuation.py::test_program_that_requires_a_continuation_refuses_a_fresh_start` | `ThreadSpec` | ported |
| `thread/test_continuation.py::test_incompatible_continuation_fails_typed_before_codec_or_execution` | `ThreadSpec` | ported; the result is checked through `threadContinuationCompatibility` and `IncompatibleContinuationError` (see divergences) |
| `thread/test_continuation.py::test_explicit_migration_requirement_can_accept_another_programs_continuation` | `ThreadSpec` | ported |
| `thread/test_continuation.py::test_continuation_revision_can_be_claimed_only_once` | `ThreadSpec` | ported |
| `thread/test_identity_and_lifecycle.py::test_lifecycle_identities_are_serializable_but_not_interchangeable` | `ThreadSpec` | ported; "not interchangeable" is a type error here, so the hash-set check becomes a compile-time guarantee |
| `thread/test_identity_and_lifecycle.py::test_one_thread_spans_runtime_replacement_without_absorbing_neighboring_identities` | `ThreadSpec` | ported |
| `thread/test_identity_and_lifecycle.py::test_active_episode_and_turn_round_trip_with_an_in_use_continuation` | `ThreadSpec` | ported |
| `thread/test_identity_and_lifecycle.py::test_turn_and_append_budgets_fail_before_an_unaccounted_transition` | `ThreadSpec` | ported |
| `thread/test_identity_and_lifecycle.py::test_cancellation_and_settlement_races_are_first_terminal_fact_wins` | `ThreadSpec` | ported |
| `thread/test_identity_and_lifecycle.py::test_settlement_and_deserialization_require_the_declared_continuation` | `ThreadSpec` | ported |
| `thread/test_identity_and_lifecycle.py::test_failed_episode_retires_its_input_revision_and_may_publish_a_new_one` | `ThreadSpec` | ported |
| `thread/test_identity_and_lifecycle.py::test_provider_shaped_fake_traces_never_enter_the_common_lifecycle` | `ThreadSpec` | ported |
| `program/test_program_descriptor.py::test_each_program_ownership_has_one_exact_serializable_descriptor[provider-owned,harness-owned,net-owned]` | `ProgramSpec` | ported (3 cases) |
| `program/test_program_descriptor.py::test_program_owned_seams_preserve_their_native_payload_types` | `ProgramSpec` | ported |
| `program/test_program_descriptor.py::test_program_seam_binding_must_match_descriptor_ownership` | `ProgramSpec` | ported |
| `runtime/test_foundation.py::test_installation_facts_are_canonical_and_have_no_path_or_authority_field` | `RuntimeFoundationSpec` | ported; the field-set and `hasattr` checks become an exhaustive destructuring of the record (compile-time) |
| `runtime/test_foundation.py::test_probe_dispositions_preserve_exact_installation_truth` | `RuntimeFoundationSpec` | ported |
| `runtime/test_foundation.py::test_runtime_turn_result_is_one_batch_and_hides_opaque_references` | `RuntimeFoundationSpec` | ported |
| `runtime/test_foundation.py::test_operation_protocol_is_structural_and_cleanup_fails_closed` | `RuntimeFoundationSpec` | ported; `isinstance(op, RuntimeOperation)` is the record type |
| `runtime/test_foundation.py::test_protocol_errors_expose_only_machine_codes` | `RuntimeFoundationSpec` | ported |
| `runtime/test_foundation.py::test_foundation_imports_with_optional_provider_sdks_blocked` | `RuntimeFoundationSpec` | adapted: asserts the library stanza depends on no provider SDK package (Haskell links statically; there is no import hook to block) |

Each of the 24 upstream cases above has one Haskell example.

## Differential corpus

`differential/thread_corpus.py` (seed `20260710`) writes
`differential/thread_corpus.json`; `ThreadDifferentialSpec` replays it:

* 260 seeded lifecycle sessions, 6 474 steps (`start_episode`, `start_turn`,
  `accept_append`, `settle_turn`, `request_cancellation`, `settle_episode`,
  `close`, and Episode-level `settle` / `request_cancellation` probes), of
  which 4 848 are refusals.  Every step compares `json.dumps(thread.to_data())`
  bytes and dispositions, or the exact refusal class and message; every
  accepted Thread must also round-trip through the fully validating
  `threadFromData`.
* 3 176 `from_data` cases over Thread, Episode, Turn, EpisodeBudget,
  Continuation, ContinuationDescriptor, AgentProgramDescriptor and the four
  identities: every document the sessions produced, structural and semantic
  random mutations of them, and targeted documents for the cross-Episode
  invariants.  Every refusal message in the lifecycle, continuation and
  program modules is hit at least once.
* 80 compatibility verdicts (8 programs × no Continuation and 9 descriptors) (`json.dumps(result.to_data())`).
* Runtime foundation values: 150 components, 150 probe issues, 250
  installations, 300 probe results, 250 turn settlements, 150 cleanups, 12
  protocol errors, 12 termination codes.

Regenerate:

```sh
cd upstream/petrus
.venv/bin/python ../../packages/petrus-agenticus-core/differential/thread_corpus.py
```

## Gaps

* None in the ported surface.  Python-only checks that the Haskell types make
  unrepresentable (`isinstance` / `type(x) is bool` refusals on constructor
  arguments, `runtime_checkable` Protocol checks) have no Haskell
  counterpart by construction; their JSON-decoding equivalents are covered.
* The one reference behavior not reproduced is a Python crash:
  `RuntimeProbeResult` raises a raw `TypeError` from `sorted()` when two issues
  share a code and only one names a component (see `divergences/thread.md`).
  The corpus avoids generating it.
