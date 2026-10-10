# Parity ledger: activity-seam

Upstream files:

- `tests/integration/test_activity_seam.py` (100 test functions)
- `tests/petrus/impetus/binding/test_typed_bindings.py` (11 test functions)

Haskell specs:

- `test/Petrus/Impetus/ActivitySeamSpec.hs` (`describe "Activity invocation seam"`, 86 examples)
- `test/Petrus/Impetus/TypedBindingsSpec.hs` (`describe "typed bindings"`, 8 examples)

Translation conventions (also in each module header):

- **Engine/Dispatch emulated inline.** `petrus.engine.Engine` and `petrus.motus.dispatch.InlineDispatch`
  live in other packages. Tests that drive the Instance seam through them are ported with
  `advanceUntilRest`, a test-local inline driver over the Instance doors (`begin`, run the activity in
  Haskell, `recordActivityCompletion` / `failFiring`, `complete`). Tests whose subject is Dispatch
  itself are ported in `petrus-motus` (`packages/petrus-motus/PARITY.md`).
- **JSONL emulated by a codec round trip.** `JsonlHistoryStore` lives in `petrus-history-store`. Kill-window and
  resume cases run over `reloaded`: every record encoded to wire bytes, parsed, decoded
  (`Petrus.Impetus.History.Codec`), and loaded into a fresh `mirroredHistoryStore`. That is the same
  durable round trip a restart over a JSONL file performs.
- **Handler call counters.** Python handlers count `prepare`/`project` calls. In Haskell both are pure
  functions, so a re-run cannot be observed by design. The ported tests assert the observable effect
  instead: the projected marking, the records, a poisoned `prepare` wherever "never re-prepares" is
  the point, and an IORef counter on the activity, which is IO in the inline driver.
- **Mutable handlers.** A handler mutated in place ("the fix, redeployed") becomes a fresh `resume`
  over the same History with the fixed handler.
- **Tuples.** `Json` has one sequence type, so a Python tuple-form redelivery is the same `Array`.

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| test_activity_import_is_a_leaf_in_a_fresh_interpreter | — | enforced by types | Enforced by the build graph: package `petrus-activity` has no dependency on `petrus-impetus`, so it cannot import Petri or History modules. |
| test_canonical_activity_and_history_codec_imports_are_public | the public surface / exposes the canonical activity values and the History codec | ported | `simpleFailure`, `invocation`, `inMemoryHistoryStore`, `schemaVersion == 5`, plus an encode/decode round trip in place of `callable(...)`. |
| test_a_typed_activity_derives_its_ordinary_handler_from_the_net_shape | DerivedActivityHandler / derives its ordinary handler from the net shape | ported | (Instance doors; Engine/Dispatch emulated inline). `DataclassPayloadConverter` becomes the `Typed` instances. |
| test_a_derived_handler_passes_unique_consume_and_read_selections_as_typed_arguments | DerivedActivityHandler / passes unique consume and read selections as typed arguments | ported | (Instance doors; Engine/Dispatch emulated inline) |
| test_a_derived_handler_distinguishes_two_typed_arcs_from_the_same_place | DerivedActivityHandler / distinguishes two typed arcs from the same place | ported | (Instance doors; Engine/Dispatch emulated inline) |
| test_a_derived_handler_projects_once_per_matching_output_arc | DerivedActivityHandler / projects once per matching output arc | ported | (Instance doors; Engine/Dispatch emulated inline) |
| test_a_derived_handler_refuses_a_typed_input_arc_no_activity_parameter_receives | DerivedActivityHandler / refuses a typed input arc no activity parameter receives | ported | Exact message. |
| test_activity_declaration_refuses_an_unresolved_annotation_in_its_own_vocabulary | — | enforced by types | A string annotation that names no type cannot exist: parameter colours come from `Typed` instances, which the compiler resolves. |
| test_activity_declaration_refuses_an_untyped_parameter_before_it_can_be_registered | — | enforced by types | Every Haskell parameter has a type, and a derived parameter is a `(name, colour)` pair. |
| test_activity_declaration_does_not_silently_replace_an_explicit_empty_name | DerivedActivityHandler / an Activity declaration does not silently replace an explicit empty name | ported | `activityDeclaration ""`, exact message. |
| test_a_derived_handler_refuses_ambiguous_same_color_input_arcs | DerivedActivityHandler / refuses ambiguous same-color input arcs | ported | Exact message. |
| test_a_derived_handler_refuses_to_supply_one_typed_arc_to_two_parameters | DerivedActivityHandler / refuses to supply one typed arc to two parameters | ported | Exact message. |
| test_a_derived_handler_refuses_a_return_type_with_no_matching_output_arc | DerivedActivityHandler / refuses a return type with no matching output arc | ported | Exact message. |
| test_a_derived_handler_refuses_an_output_arc_the_return_type_cannot_supply | DerivedActivityHandler / refuses an output arc the return type cannot supply | ported | Exact message. |
| test_a_derived_handler_refuses_a_weighted_input_until_collection_parameters_are_supported | DerivedActivityHandler / refuses a weighted input until collection parameters are supported | ported | Exact message. |
| test_a_typed_activity_uses_a_user_payload_converter_without_changing_the_runtime | DerivedActivityHandler / uses a user payload converter without changing the runtime | ported | (Instance doors; Engine/Dispatch emulated inline). The user converter is the `CustomInput`/`CustomOutput` `Typed` instances. |
| TestExecutionPolicy::test_the_default_is_maximally_conservative | the seam's value objects / ExecutionPolicy / the default is maximally conservative | ported | |
| TestExecutionPolicy::test_invalid_attempt_counts_are_rejected_before_a_policy_can_be_serialized | the seam's value objects / ExecutionPolicy / invalid attempt counts are rejected before a policy can be serialized | ported | The `attempts=0` parameter is ported with its exact message. The `attempts=True` parameter is enforced by types (`attempts :: Integer`). |
| TestExecutionPolicy::test_non_finite_retry_and_deadline_values_are_rejected_at_the_value_door | the seam's value objects / ExecutionPolicy / non-finite retry and deadline values are rejected at the value door | ported | NaN, +inf and -inf on all three doors, with exact messages. |
| TestExecutionPolicy::test_backoff_saturates_without_overflow_and_jitter_is_not_claimed | the seam's value objects / ExecutionPolicy / backoff saturates without overflow and jitter is not claimed | ported | Includes `delay(10**1000)`. |
| TestExecutionPolicy::test_backoff_handles_extreme_finite_values_without_ratio_or_power_overflow | the seam's value objects / ExecutionPolicy / backoff handles extreme finite values without ratio or power overflow | ported | |
| TestExecutionPolicy::test_provider_neutral_durations_refuse_values_over_one_billion_seconds | the seam's value objects / ExecutionPolicy / provider-neutral durations refuse values over one billion seconds | ported | All six parameters, with exact messages. |
| TestActivityInvocation::test_defaults_are_the_conservative_resolution | the seam's value objects / ActivityInvocation / defaults are the conservative resolution | ported | |
| TestActivityInvocation::test_an_empty_activity_name_is_rejected | the seam's value objects / ActivityInvocation / an empty activity name is rejected | ported | Exact message. |
| TestActivityInvocation::test_an_empty_supplied_identity_is_rejected | the seam's value objects / ActivityInvocation / an empty supplied identity is rejected | ported | Exact messages. |
| TestPurityClassification::test_a_plain_callable_bound_to_a_symbol_is_a_pure_projection | purity is the binding's classification / a plain callable bound to a symbol is a pure projection | ported | |
| TestPurityClassification::test_a_source_transition_must_not_bind_an_activity_handler | purity is the binding's classification / a source transition must not bind an ActivityHandler | ported | Exact message. |
| TestBeginFreezesTheRequest::test_the_begin_batch_carries_the_activity_request_after_the_reads | begin freezes the request / the begin batch carries the activity request after the reads | ported | |
| TestBeginFreezesTheRequest::test_a_pure_occurrence_carries_no_invocation | begin freezes the request / a pure occurrence carries no invocation | ported | |
| TestBeginFreezesTheRequest::test_supplied_identities_travel_verbatim | begin freezes the request / supplied identities travel verbatim | ported | |
| TestBeginFreezesTheRequest::test_a_failing_prepare_appends_nothing_and_burns_no_id | begin freezes the request / a failing prepare appends nothing and burns no id | ported | A pure `prepare` cannot fail "once", so the head candidate's token makes it raise and the next candidate begins as occurrence 1 on the same instance. The raise is `HandlerRaised`. |
| TestBeginFreezesTheRequest::test_a_prepare_returning_a_non_invocation_is_refused_before_append | — | enforced by types | `prepare :: Binding -> Either Text ActivityInvocation` cannot return any other shape. |
| TestBeginFreezesTheRequest::test_a_supplied_identity_in_the_reserved_namespace_is_refused | begin freezes the request / a supplied identity in the reserved namespace is refused | ported | Exact messages for both correlation and idempotency. |
| TestRecordActivityCompletion::test_the_result_freezes_as_its_own_append_before_projection | record_activity_completion / the result freezes as its own append before projection | ported | |
| TestRecordActivityCompletion::test_a_pure_occurrence_takes_no_activity_completion | record_activity_completion / a pure occurrence takes no activity completion | ported | Exact message. |
| TestRecordActivityCompletion::test_an_identical_re_record_is_acknowledged_without_a_second_append | record_activity_completion / an identical re-record is acknowledged without a second append | ported | Also asserts `TerminalAcknowledged`. |
| TestRecordActivityCompletion::test_a_different_late_result_is_an_operational_conflict | record_activity_completion / a different late result is an operational conflict | ported | Exact message. |
| TestRecordActivityCompletion::test_nested_boolean_and_integer_results_are_distinct | record_activity_completion / nested boolean and integer results are distinct | ported | Exact message. |
| TestRecordActivityCompletion::test_an_ended_pure_occurrence_still_reads_as_already_ended | record_activity_completion / an ended pure occurrence still reads as already ended | ported | Exact message. |
| TestEndedOccurrenceAcknowledgement::test_an_identical_late_re_record_returns_the_prior_acknowledgement_quietly | ended-occurrence acknowledgement / an identical late re-record returns the prior acknowledgement quietly | ported | |
| TestEndedOccurrenceAcknowledgement::test_the_late_acknowledgement_compares_canonical_values | ended-occurrence acknowledgement / the late acknowledgement compares canonical values | ported | The tuple spelling has no `Json` counterpart, so the redelivery is the same `Array`. |
| TestEndedOccurrenceAcknowledgement::test_a_different_late_result_after_the_end_is_an_operational_conflict | ended-occurrence acknowledgement / a different late result after the end is an operational conflict | ported | Exact message. |
| TestEndedOccurrenceAcknowledgement::test_a_late_result_after_a_terminal_failure_is_an_operational_conflict | ended-occurrence acknowledgement / a late result after a terminal failure is an operational conflict | ported | Exact message. |
| TestEndedOccurrenceAcknowledgement::test_the_terminal_result_index_rebuilds_at_resume | ended-occurrence acknowledgement / the terminal result index rebuilds at resume | ported | Codec round-trip store in place of JSONL. |
| TestEndedOccurrenceAcknowledgement::test_replay_terminal_activity_projects_only_ended_occurrences | ended-occurrence acknowledgement / replay_terminal_activity projects only ended occurrences | ported | |
| TestTerminalActivityReplayDivergence::test_a_second_terminal_activity_fact_is_replay_divergence | terminal activity replay divergence / a second terminal activity fact is replay divergence | ported | All four parameter pairs, with the exact message. |
| TestTerminalActivityReplayDivergence::test_a_terminal_activity_fact_after_the_firing_ended_is_replay_divergence | terminal activity replay divergence / a terminal activity fact after the firing ended is replay divergence | ported | Exact message. |
| TestTerminalActivityReplayDivergence::test_an_activity_failure_after_a_frozen_completion_is_replay_divergence | terminal activity replay divergence / an activity failure after a frozen completion is replay divergence | ported | Exact message. |
| TestCompleteProjectsTheFrozenResult::test_complete_projects_the_frozen_result_and_commits_the_boundary | complete projects the frozen result / complete projects the frozen result and commits the boundary | ported | `projected == 1` is replaced by the one projected receipt. |
| TestCompleteProjectsTheFrozenResult::test_complete_without_a_frozen_result_fails_loud | complete projects the frozen result / complete without a frozen result fails loud | ported | Exact message. |
| TestCompleteProjectsTheFrozenResult::test_complete_on_an_impure_occurrence_takes_no_result_argument | complete projects the frozen result / complete on an impure occurrence takes no result argument | ported | Exact message. |
| TestCompleteProjectsTheFrozenResult::test_a_pure_complete_requires_its_handlers_result | complete projects the frozen result / a pure complete requires its handler's result | ported | Exact message. |
| TestCompleteProjectsTheFrozenResult::test_a_projection_bug_is_fixed_in_code_and_retried_from_the_same_frozen_result | complete projects the frozen result / a projection bug is fixed in code and retried from the same frozen result | ported | The raise is `HandlerRaised "KeyError('statuss')"`. The fix is a resume over the same store with the fixed handler. |
| test_activity_success_preserves_the_three_distinct_append_boundaries | append boundaries / activity success preserves the three distinct append boundaries | ported | Batch-recording store built with `mirroredHistoryStore`. |
| TestFail::test_an_impure_failure_commits_activity_failed_and_firing_failed_in_one_batch | fail: exhausted execution / an impure failure commits ActivityFailed and FiringFailed | ported | Asserts the batches as `[1, 1]`, as upstream does. |
| TestFail::test_a_pure_failure_stays_firing_failed_alone | fail: exhausted execution / a pure failure stays FiringFailed alone | ported | |
| TestFail::test_a_pure_firing_rejects_activity_failure_freeze | fail: exhausted execution / a pure firing rejects activity failure freeze | ported | Exact message. |
| TestFail::test_fail_refuses_a_completed_activity | fail: exhausted execution / fail refuses a completed activity | ported | Exact message. |
| TestStepRefusesActivityTransitions::test_step_fails_loud_naming_the_adapter_it_lacks | the inline drivers refuse what they cannot run / step fails loud naming the adapter it lacks | ported | Exact message. |
| TestInlineDispatch::test_registry_is_snapshotted_and_the_adapter_remains_frozen | — | ported in petrus-motus | `packages/petrus-motus/test/Main.hs`, `TestInlineDispatch (activity seam)` / "registry is snapshotted and the adapter remains frozen". |
| TestInlineDispatch::test_classified_retries_are_immediate_and_never_sleep | — | ported in petrus-motus | `packages/petrus-motus/test/Main.hs`, `TestInlineDispatch (activity seam)` / "classified retries are immediate and never sleep". |
| TestInlineDispatch::test_generic_exception_keeps_precise_retryable_metadata_when_budget_exhausts | — | ported in petrus-motus | `packages/petrus-motus/test/Main.hs`, `TestInlineDispatch (activity seam)` / "generic exception keeps precise retryable metadata when budget exhausts". |
| TestInlineDispatch::test_value_shape_preserves_the_prior_dataclass_contract | — | not applicable (petrus-motus) | Dataclass reflection of the adapter; a Haskell `Dispatch` is a record of functions with no fields, `Show`, or `Eq`. See `packages/petrus-motus/PARITY.md`. |
| TestInlineDispatch::test_executes_the_named_activity_with_the_whole_invocation | — | ported in petrus-motus | `packages/petrus-motus/test/Main.hs`, `TestInlineDispatch (activity seam)` / "executes the named activity with the whole invocation". |
| TestInlineDispatch::test_an_unknown_activity_fails_loud | — | ported in petrus-motus | `packages/petrus-motus/test/Main.hs`, `TestInlineDispatch (activity seam)` / "an unknown activity fails loud". |
| TestInlineDispatch::test_the_conservative_policy_makes_an_exception_terminal | — | ported in petrus-motus | `packages/petrus-motus/test/Main.hs`, `TestInlineDispatch (activity seam)` / "the conservative policy makes an exception terminal". |
| TestInlineDispatch::test_a_declared_attempts_policy_is_honored | — | ported in petrus-motus | `packages/petrus-motus/test/Main.hs`, `TestInlineDispatch (activity seam)` / "a declared attempts policy is honored". |
| TestEngineDrivesActivities::test_an_activity_firing_records_the_canonical_lifecycle | an inline driver drives the whole seam (Engine emulated) / an activity firing records the canonical lifecycle | ported | (Instance doors; Engine/Dispatch emulated inline) |
| TestEngineDrivesActivities::test_a_typed_decline_is_a_business_result_never_a_firing_failure | an inline driver drives the whole seam (Engine emulated) / a typed decline is a business result, never a firing failure | ported | (Instance doors; Engine/Dispatch emulated inline) |
| TestEngineDrivesActivities::test_an_exhausted_adapter_is_activity_failed_plus_firing_failed_and_no_business_token | an inline driver drives the whole seam (Engine emulated) / an exhausted adapter is ActivityFailed plus FiringFailed and no business token | ported | (Instance doors; Engine/Dispatch emulated inline). The Engine's `RuntimeError("... failed terminally")` belongs to the Engine. The test-local driver reproduces it as `RuntimeRefused`; the seam assertions (records, `replay_in_flight == ()`) are the kernel's. |
| TestEngineDrivesActivities::test_a_projection_error_leaves_the_occurrence_projection_pending | an inline driver drives the whole seam (Engine emulated) / a projection error leaves the occurrence projection-pending | ported | (Instance doors; Engine/Dispatch emulated inline) |
| TestKillWindowOne::test_resume_rebuilds_the_occurrence_with_its_invocation_and_never_re_prepares | the kill windows, over the durable record / window one: resume rebuilds the occurrence with its invocation and never re-prepares | ported | Codec round-trip store in place of JSONL. Poisoned prepare. |
| TestKillWindowOne::test_the_rebuilt_invocation_is_redispatchable_to_completion | the kill windows, over the durable record / window one: the rebuilt invocation is redispatchable to completion | ported | Codec round trip. `prepared == 0` is pinned by a poisoned prepare. `projected == 1` is pinned by the single receipt. |
| TestKillWindowTwo::test_resume_is_projection_pending_and_the_activity_is_never_re_invoked | the kill windows, over the durable record / window two: resume is projection-pending and the activity is never re-invoked | ported | Codec round trip. The activity's IORef counter stays 0. |
| TestKillWindowTwo::test_a_projection_bug_fixed_and_retried_completes_from_the_same_frozen_result | the kill windows, over the durable record / window two: a projection bug fixed and retried completes from the same frozen result | ported | Codec round trip. Each "redeploy" is a fresh reload. |
| TestTerminalFailureProjection::test_opt_in_failure_projection_routes_one_typed_terminal_token | terminal failure projection / opt-in failure projection routes one typed terminal token | ported | `failures == [failure]` is pinned by the projected token's kind and details. |
| TestTerminalFailureProjection::test_equal_failure_redelivery_acknowledges_and_conflicts_are_refused | terminal failure projection / equal failure redelivery acknowledges and conflicts are refused | ported | Exact messages. |
| TestTerminalFailureProjection::test_nested_boolean_and_integer_failure_details_are_distinct | terminal failure projection / nested boolean and integer failure details are distinct | ported | Exact messages. |
| TestTerminalFailureProjection::test_failure_projection_crash_reloads_the_frozen_failure_without_another_attempt | terminal failure projection / a failure projection crash reloads the frozen failure without another attempt | ported | Codec round trip. Poisoned prepare. Also asserts the reloaded pending outcome. |
| TestTerminalFailureProjection::test_legacy_fail_and_halt_recovers_after_the_failure_freeze | terminal failure projection / legacy fail-and-halt recovers after the failure freeze | ported | Codec round trip. |
| TestTerminalFailureProjection::test_ended_failure_replay_preserves_classification_for_late_acknowledgement | terminal failure projection / ended failure replay preserves classification for late acknowledgement | ported | Codec round trip. |
| TestActivityReplayGuards::test_an_activity_request_with_no_begun_boundary_is_replay_divergence | activity replay guards / an activity request with no begun boundary is replay divergence | ported | Exact message. |
| TestActivityReplayGuards::test_a_second_activity_request_for_one_occurrence_is_replay_divergence | activity replay guards / a second activity request for one occurrence is replay divergence | ported | Exact message. |
| TestActivityReplayGuards::test_an_activity_completion_for_a_pure_occurrence_is_replay_divergence | activity replay guards / an activity completion for a pure occurrence is replay divergence | ported | Exact message. |
| TestActivityReplayGuards::test_an_activity_failure_for_a_pure_occurrence_is_replay_divergence | activity replay guards / an activity failure for a pure occurrence is replay divergence | ported | Exact message. |
| TestActivityReplayGuards::test_a_second_terminal_activity_fact_is_replay_divergence | activity replay guards / a second terminal activity fact is replay divergence | ported | Exact message. |
| TestActivityReplayGuards::test_an_activity_completion_alone_is_not_a_torn_batch | activity replay guards / an activity completion alone is not a torn batch | ported | |
| TestActivityReplayGuards::test_an_activity_failure_without_its_firing_boundary_is_projection_pending | activity replay guards / an activity failure without its firing boundary is projection-pending | ported | |
| TestActivityReplayGuards::test_resume_rejects_an_activity_request_on_a_purely_bound_transition | activity replay guards / resume rejects an activity request on a purely bound transition | ported | Exact message. |
| TestActivityReplayGuards::test_resume_rejects_an_activity_bound_occurrence_with_no_recorded_request | activity replay guards / resume rejects an activity-bound occurrence with no recorded request | ported | Exact message. |
| TestCanonicalPayloadSnapshot::test_mutating_the_input_after_begin_does_not_reach_the_record | — | enforced by types | `Json` values are immutable, so a caller cannot mutate the input after begin. |
| TestCanonicalPayloadSnapshot::test_mutating_the_result_after_recording_does_not_reach_the_projection | — | enforced by types | `Json` values are immutable, so a caller cannot mutate the result after recording. |
| TestCanonicalPayloadSnapshot::test_a_tuple_result_freezes_canonical_and_its_re_record_acknowledges | canonical payload snapshots at the writer / a sequence result freezes canonical and its re-record acknowledges | ported | The tuple spelling has no `Json` counterpart. The frozen list form and the acknowledgement are asserted. |
| TestCanonicalPayloadSnapshot::test_a_net_object_as_input_fails_loud_at_begin_appending_nothing | canonical payload snapshots at the writer / a non-JSON-faithful input fails loud at begin, appending nothing | ported | A Token cannot be a `Json` value, so the door is exercised through its reachable refusal: a NaN input. The exact message is shared with Python (`... JSON-faithful ...: Out of range float values are not JSON compliant: nan`). |
| TestCanonicalPayloadSnapshot::test_a_net_object_as_result_fails_loud_at_the_record_appending_nothing | canonical payload snapshots at the writer / a non-JSON-faithful result fails loud at the record, appending nothing | ported | Same approach with an infinite result. Exact message. |
| TestK6AcrossResume::test_a_resumed_writer_acknowledges_an_identical_re_record_without_appending | K6 across resume / a resumed writer acknowledges an identical re-record without appending | ported | Codec round trip. |
| TestK6AcrossResume::test_a_tuple_form_redelivery_acknowledges_against_the_decoded_frozen_result | K6 across resume / a sequence redelivery acknowledges against the decoded frozen result | ported | Codec round trip. The tuple spelling is the same `Array`. |
| TestK6AcrossResume::test_a_different_late_result_still_conflicts_across_the_resume | K6 across resume / a different late result still conflicts across the resume | ported | Codec round trip. Exact message. |
| TestBeginBatchOrderParity::test_a_read_before_a_consume_is_replay_divergence | begin batch order parity / a read before a consume is replay divergence | ported | Exact message. |
| TestBeginBatchOrderParity::test_an_activity_request_before_a_read_is_replay_divergence | begin batch order parity / an activity request before a read is replay divergence | ported | Exact message. |
| test_typed_transform_decodes_read_and_consumed_inputs_and_routes_dataclass_result | typed bindings / a typed transform decodes read and consumed inputs and routes its result | ported | |
| test_typed_guard_decodes_the_same_effective_input_contract | typed bindings / a typed guard decodes the same effective input contract | ported | |
| test_typed_guard_requires_an_exact_bool_at_runtime | — | enforced by types | `deriveTypedGuard` takes `TypedArgs Bool`, so a predicate cannot return `"yes"`. |
| test_typed_binding_reads_effective_colors_compiled_from_places | typed bindings / a typed binding reads effective colors compiled from places | ported | |
| test_typed_binding_rejects_source_transitions | typed bindings / rejects source transitions | ported | Exact message. |
| test_typed_binding_rejects_weighted_inputs | typed bindings / rejects weighted inputs | ported | Exact message. |
| test_typed_binding_rejects_same_color_input_ambiguity | typed bindings / rejects same-color input ambiguity | ported | Exact message. |
| test_typed_binding_rejects_unmatched_input_arcs | typed bindings / rejects unmatched input arcs | ported | Exact message. |
| test_typed_transform_rejects_output_color_mismatch | typed bindings / rejects an output color mismatch | ported | Exact message. |
| test_typed_binding_rejects_missing_or_variadic_parameter_contracts | — | enforced by types | Parameters are `param name` values of a `Typed` type. An unannotated or variadic parameter cannot be written. |
| test_typed_transform_rejects_non_dataclass_return_annotation | — | enforced by types | `deriveTypedTransform` requires `Typed r` for the result, so a `dict` return has no instance. |

## Counts

| status | test_activity_seam.py | test_typed_bindings.py | total |
| --- | --- | --- | --- |
| ported | 86 (9 with Engine/Dispatch emulated inline) | 8 | 94 |
| ported via CEL stub | 0 | 0 | 0 |
| enforced by types | 6 | 3 | 9 |
| ported in petrus-motus | 7 | 0 | 7 |
| not applicable (petrus-motus) | 1 | 0 | 1 |
| not at parity | 0 | 0 | 0 |
| **total** | 100 | 11 | 111 |

Kernel changes: none. Every ported case passes against the kernel as it stands, with exact message
parity confirmed against the pinned Python package.
