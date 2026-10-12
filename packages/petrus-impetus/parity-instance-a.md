# Parity ledger: instance-a

Upstream: `tests/petrus/impetus/instance/` — `test_firing.py`, `test_firing_occurrences.py`,
`test_handlers.py`, `test_runtime.py`, `test_awaiting_termination.py`, `test_completion.py`,
`test_environment_signal.py`, `test_instance_identity.py`, `test_guard_branch.py`,
`test_cel_guards.py`.

Haskell specs: `test/Petrus/Impetus/{InstanceFiringSpec, FiringOccurrencesSpec, HandlersSpec,
RuntimeSpec, AwaitingTerminationSpec, CompletionSpec, EnvironmentSignalSpec, InstanceIdentitySpec,
GuardBranchSpec, CelGuardsSpec}.hs`, with helpers in `InstanceSupport.hs` and the test-local CEL
compiler in `CelStub.hs`.

Totals over the 135 upstream tests above: 106 ported, 20 ported via CEL stub, 4 enforced by types, 5 ported
in `petrus-cel`, 0 not at parity. One Hspec example per ported case, plus 2 door-level
companions of the two Instance record-authoring contracts.

Kernel fix made for parity: `src/Petrus/Impetus/Internal/Uuid.hs` minted UUIDv7 ids with random
bits inside a millisecond, so two instances built in the same millisecond were creation-ordered
only half the time (`test_an_unsupplied_id_is_minted_unique_and_creation_ordered` failed 20/40
runs). It now follows the reference's `uuid.uuid7` (RFC 9562 §6.2 Method 1): a 42-bit counter
that advances within a millisecond, process-wide.

## test_firing.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestRoute.test_each_token_goes_to_every_admitting_arc_order_preserved | Instance firing / route / sends each token to every admitting arc, order preserved | ported | |
| TestRoute.test_two_arcs_to_one_target_concatenate_in_arc_order | Instance firing / route / concatenates two arcs to one target in arc order | ported | |
| TestRoute.test_unrouted_tokens_drop_silently | Instance firing / route / drops unrouted tokens silently | ported | |
| TestPassthrough.test_forwards_each_token_through_every_admitting_output_arc | Instance firing / passthrough / forwards each token through every admitting output arc | ported | |
| TestPassthrough.test_forwards_only_consumed_selections | Instance firing / passthrough / forwards only consumed selections | ported | |
| TestPassthrough.test_a_transition_with_no_output_arcs_is_a_sink | Instance firing / passthrough / treats a transition with no output arcs as a sink | ported | |
| TestPassthrough.test_forwards_delivered_tokens_of_a_source_firing | Instance firing / passthrough / forwards the delivered tokens of a source firing | ported | |
| TestSelectConservative.test_picks_the_first_binding | Instance firing / selectConservative / picks the first binding | ported | `is` identity compared as equality |
| TestSelectConservative.test_returns_none_when_empty | Instance firing / selectConservative / returns Nothing when empty | ported | |
| TestBeginEndFiring.test_petrinet_source_binding_begins_with_no_movement_effects | Instance firing / begin/end firing / begins a source binding with no movement effects | ported | |
| TestBeginEndFiring.test_petrinet_consume_precedes_read_and_same_token_fails_loud | Instance firing / begin/end firing / consumes before reading, so reading the consumed token fails loud | ported | exact message asserted |
| TestBeginEndFiring.test_instance_begin_firing_retains_its_record_authoring_contract | Instance firing / begin/end firing / retains the Instance begin record-authoring contract | ported | against `instanceBeginFiring` (the reference's `instance.firing.begin_firing`); the begin-door companion "authors the begin records through the begin door" is kept beyond the reference |
| TestBeginEndFiring.test_instance_complete_firing_retains_its_outcome_and_registration_contract | Instance firing / begin/end firing / retains the Instance complete outcome and registration contract | ported | against `instanceCompleteFiring` (the reference's `instance.firing.complete_firing`); the complete-door companion "authors the completion records through the complete door" is kept beyond the reference |
| TestBeginEndFiring.test_begin_consumes_and_end_produces | Instance firing / begin/end firing / consumes at begin and produces at end | ported | |
| TestBeginEndFiring.test_returns_movements_in_lifecycle_order | Instance firing / begin/end firing / returns movements in lifecycle order | ported | |
| TestBeginEndFiring.test_begin_fails_loud_on_a_stale_selection_before_any_record_matters | Instance firing / begin/end firing / fails loud on a stale selection before any record matters | ported | exact message asserted |
| TestBeginEndFiring.test_begin_records_read_selections_after_the_consumes_in_input_arc_order | Instance firing / begin/end firing / records read selections after the consumes, in input-arc order | ported | |
| TestBeginEndFiring.test_a_stale_read_selection_cannot_begin | Instance firing / begin/end firing / refuses a stale read selection | ported | exact message asserted |
| TestBeginEndFiring.test_a_user_handlers_projection_records_movements_only | Instance firing / begin/end firing / records only movements for a user handler's projection | ported | |
| TestBeginEndFiring.test_fans_one_token_out_to_every_output_place | Instance firing / begin/end firing / fans one token out to every output place | ported | |
| TestBeginEndFiring.test_registration_effects_are_not_part_of_the_petrinet_transform | Instance firing / begin/end firing / keeps registration effects out of the Petrinet transform | ported | |
| TestBeginEndFiring.test_deposits_the_supplied_handler_tokens | Instance firing / begin/end firing / deposits the supplied handler tokens | ported | |
| TestBeginEndFiring.test_handler_destination_keys_may_be_plain_strings | — | enforced by types | a handler destination is a `NetPath`; there is no `str` spelling to normalize |
| TestBeginEndFiring.test_destination_keys_resolving_to_one_place_coalesce_into_one_record | Instance firing / begin/end firing / coalesces destination entries naming one place into one record | ported | the two spellings become two entries for the same `NetPath` |

## test_firing_occurrences.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestBegin.test_begin_accounts_tokens_and_records_the_occurrence | Instance firing occurrences / begin / accounts tokens and records the occurrence | ported | |
| TestBegin.test_occurrence_ids_are_minted_monotonically | Instance firing occurrences / begin / mints occurrence ids monotonically | ported | |
| TestBegin.test_an_in_flight_occurrence_keeps_the_instance_running | Instance firing occurrences / begin / keeps the instance running while an occurrence is in flight | ported | |
| TestBegin.test_begin_rejects_a_delivered_binding | Instance firing occurrences / begin / rejects a delivered binding | ported | exact message (the reference matched `deliver`) |
| TestBegin.test_begin_rejects_a_source_transition | Instance firing occurrences / begin / rejects a source transition | ported | exact message |
| TestBegin.test_begin_rejects_a_foreign_transition | Instance firing occurrences / begin / rejects a foreign transition | ported | exact message |
| TestBegin.test_begin_rejects_a_hand_built_binding_missing_its_consume_selection | Instance firing occurrences / begin / rejects a hand-built binding missing its consume selection | ported | exact message |
| TestBegin.test_begin_rejects_a_hand_built_binding_missing_its_read_selection | Instance firing occurrences / begin / rejects a hand-built binding missing its read selection | ported | exact message |
| TestBegin.test_begin_with_a_stale_selection_appends_nothing | Instance firing occurrences / begin / appends nothing for a stale selection | ported | exact message |
| TestComplete.test_complete_deposits_per_arc_contract_and_ends_the_occurrence | Instance firing occurrences / complete / deposits per the arc contract and ends the occurrence | ported | |
| TestComplete.test_a_user_handled_firing_is_a_pure_projection_recording_movements_only | Instance firing occurrences / complete / records a user-handled firing as a pure projection, movements only | ported | |
| TestComplete.test_a_passthrough_firing_records_no_activity_records | Instance firing occurrences / complete / records no activity records for a passthrough firing | ported | |
| TestComplete.test_complete_rejects_an_occurrence_this_instance_never_began | Instance firing occurrences / complete / rejects an occurrence this instance never began | ported | exact message |
| TestComplete.test_complete_rejects_an_already_ended_occurrence | Instance firing occurrences / complete / rejects an already ended occurrence | ported | exact message |
| TestFail.test_fail_records_the_terminal_failure_and_nothing_else | Instance firing occurrences / fail / records the terminal failure and nothing else | ported | |
| TestFail.test_a_failed_occurrence_no_longer_blocks_quiescence | Instance firing occurrences / fail / no longer blocks quiescence once failed | ported | |
| TestFail.test_fail_discriminates_misuse_like_complete | Instance firing occurrences / fail / discriminates misuse like complete | ported | exact message |
| TestStepThroughTheSeam.test_step_is_one_occurrence_begun_and_completed | Instance firing occurrences / step through the seam / is one occurrence begun and completed | ported | |
| TestStepThroughTheSeam.test_step_with_a_user_handler_records_the_pure_projection_lifecycle | Instance firing occurrences / step through the seam / records the pure projection lifecycle for a user handler | ported | record kinds via `recordName` |
| TestStepThroughTheSeam.test_a_raising_handler_records_the_failure_and_propagates | Instance firing occurrences / step through the seam / records a raising handler's failure and propagates | ported | the raising handler is a `Left "RuntimeError('quote service down')"`; `HandlerRaised` and the FiringFailed error carry it verbatim |
| TestStepThroughTheSeam.test_a_result_the_commit_rejects_records_the_failure_and_propagates | Instance firing occurrences / step through the seam / records the failure of a result the commit rejects and propagates | ported | exact `Refused` message and `ValueError('...')` FiringFailed error |
| TestDeliverThroughTheSeam.test_delivery_records_carry_one_occurrence | Instance firing occurrences / deliver through the seam / carries one occurrence on every delivery record | ported | |
| TestDeliverThroughTheSeam.test_a_handled_delivery_is_a_local_atomic_projection | Instance firing occurrences / deliver through the seam / projects a handled delivery locally and atomically | ported | |
| TestValueAliasingPinnedInvariant.test_value_aliasing_is_a_pinned_invariant_selections_are_by_value_not_position | Instance firing occurrences / value aliasing / pins value aliasing: selections are by value, not position | ported | exact stale-selection message |
| TestReplayWithOccurrences.test_replay_of_an_in_flight_tail_leaves_tokens_consumed | Instance firing occurrences / replay with occurrences / replays an in-flight tail with its tokens consumed | ported | |

## test_handlers.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestHandlerDeclarationBindings.test_exact_declaration_uris_bind_same_named_handlers_independently | Instance handlers / handler declaration bindings / binds same-named handlers independently by exact declaration URI | ported | `is` identity checked by distinguishable handler answers |
| TestHandlerDeclarationBindings.test_local_symbol_deliberately_shares_one_handler | Instance handlers / handler declaration bindings / shares one handler through the local symbol | ported | same |
| TestHandlerDeclarationBindings.test_exact_and_local_binding_for_one_handler_is_ambiguous | Instance handlers / handler declaration bindings / refuses an exact and a local binding for one handler as ambiguous | ported | exact message |
| TestHandlerDeclarationBindings.test_anonymous_handler_requires_its_exact_declaration_uri | Instance handlers / handler declaration bindings / requires the exact declaration URI for an anonymous handler | ported | exact message |
| TestHandlerTokens.test_handler_supplied_token_is_deposited_not_the_consumed_one | Instance handlers / handler tokens / deposits the handler-supplied token, not the consumed one | ported | |
| TestHandlerTokens.test_firing_reports_consumed_input_and_handler_output | Instance handlers / handler tokens / reports the consumed input and the handler output | ported | |
| TestHandlerTokens.test_handler_firing_records_movements_in_lifecycle_order | Instance handlers / handler tokens / records the handler firing's movements in lifecycle order | ported | |
| TestHandlerTokens.test_history_replays_handler_supplied_tokens | Instance handlers / handler tokens / replays the handler-supplied tokens from History | ported | |
| TestHandlerTokens.test_missing_handler_implementation_fails_at_construction | Instance handlers / handler tokens / fails at construction on a missing handler implementation | ported | exact message |
| TestHandlerSeesTheFullBinding.test_handler_correlates_consumed_and_read_tokens | Instance handlers / a handler sees the full binding / correlates consumed and read tokens | ported | |
| TestPerArcOutputContracts.test_heterogeneous_fanout_deposits_different_payloads_per_branch | Instance handlers / per-arc output contracts / deposits different payloads per branch of a heterogeneous fan-out | ported | |
| TestPerArcOutputContracts.test_token_whose_color_matches_no_arc_at_its_destination_is_dropped | Instance handlers / per-arc output contracts / drops a token whose color matches no arc at its destination | ported | |
| TestPerArcOutputContracts.test_token_keyed_to_a_place_with_no_output_arc_is_dropped | Instance handlers / per-arc output contracts / drops a token keyed to a place with no output arc | ported | |
| TestPerArcOutputContracts.test_a_handler_may_consult_the_output_arcs_to_route | Instance handlers / per-arc output contracts / lets a handler consult the output arcs to route | ported | |
| TestTypedPassthroughRouting.test_forwards_through_admitting_arcs_only | Instance handlers / typed passthrough routing / forwards through admitting arcs only | ported | |
| TestTypedPassthroughRouting.test_consumed_token_admitted_by_no_arc_is_simply_consumed | Instance handlers / typed passthrough routing / simply consumes a token no arc admits | ported | |
| TestZeroConsumeHandledEmitter.test_self_inhibiting_emitter_fires_once_then_quiesces | Instance handlers / zero-consume handled emitter / fires a self-inhibiting emitter once, then quiesces | ported | |

## test_runtime.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestInstance.test_step_fans_out_and_reports_what_landed_where | Instance runtime / the integration path / fans out on step and reports what landed where | ported | |
| TestInstance.test_runs_to_quiescence_and_reports_terminated | Instance runtime / the integration path / runs to quiescence and reports terminated | ported | |
| TestInstance.test_step_records_the_selection_before_the_firing_lifecycle | Instance runtime / the integration path / records the selection before the firing lifecycle | ported | |
| TestInstance.test_history_replays_to_the_live_marking | Instance runtime / the integration path / replays History to the live marking | ported | |
| TestLiveStateIsNotRefolded.test_candidates_answer_from_live_state_without_refolding_history | Instance runtime / live state is not refolded / answers candidates from live state without refolding History | ported | the counting store counts `snapshot` reads (a Haskell fold reads the snapshot; the reference counted `__iter__`) |

## test_awaiting_termination.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestAwaitingTermination.test_quiescent_with_parked_work_is_awaiting_not_terminated | Instance awaiting termination / is awaiting, not terminated, when quiescent with parked work | ported | |
| TestAwaitingTermination.test_external_resolution_reenables_the_join | Instance awaiting termination / re-enables the join on external resolution | ported | |
| TestAwaitingTermination.test_resolution_drains_the_wait_and_the_seal_terminates | Instance awaiting termination / drains the wait on resolution, and the seal terminates | ported | |

## test_environment_signal.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestEnvironmentSignal.test_the_net_quiesces_awaiting_the_webhook | Instance environment signal / quiesces awaiting the webhook | ported | |
| TestEnvironmentSignal.test_delivery_injects_the_event_and_reenables_the_net | Instance environment signal / injects the event on delivery and re-enables the net | ported | |
| TestEnvironmentSignal.test_settlement_consumes_the_delivered_event_and_forwards_it | Instance environment signal / consumes the delivered event at settlement and forwards it | ported | |
| TestEnvironmentSignal.test_sealing_the_webhook_lets_the_instance_terminate | Instance environment signal / terminates once the webhook is sealed | ported | |

## test_instance_identity.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestNetName.test_the_definition_name_is_optional_and_descriptive | Instance identity / net name / is optional and descriptive | ported | |
| TestNetName.test_an_empty_or_non_string_name_is_refused | Instance identity / net name / refuses an empty name | ported | exact message for `''`; the non-string half (`7`) is enforced by types (a name is `Text`) |
| TestIdentityIsRecordedFirst.test_construction_records_the_identity_fact_before_anything | Instance identity / identity is recorded first / records the identity fact before anything | ported | |
| TestIdentityIsRecordedFirst.test_an_unsupplied_id_is_minted_unique_and_creation_ordered | Instance identity / identity is recorded first / mints an unsupplied id unique and creation-ordered | ported | required the `Internal/Uuid.hs` monotonic-counter fix (failed 20/40 runs before) |
| TestIdentityIsRecordedFirst.test_an_unnamed_net_records_no_name | Instance identity / identity is recorded first / records no name for an unnamed net | ported | |
| TestResumeDerivesIdentity.test_resume_reads_the_recorded_identity_back | Instance identity / resume derives identity / reads the recorded identity back | ported | |
| TestResumeDerivesIdentity.test_identity_survives_a_crash_that_a_resupplied_argument_would_not | Instance identity / resume derives identity / keeps a minted identity across resume with no argument | ported | |
| TestResumeDerivesIdentity.test_a_trace_without_identity_is_replay_divergence | Instance identity / resume derives identity / refuses a trace without identity as replay divergence | ported | exact message |
| TestResumeDerivesIdentity.test_a_recorded_name_disagreeing_with_the_supplied_net_is_a_foreign_trace | Instance identity / resume derives identity / refuses a recorded name disagreeing with the supplied net as a foreign trace | ported | exact message |
| TestResumeDerivesIdentity.test_an_unnamed_resupplied_net_accepts_a_named_trace | Instance identity / resume derives identity / accepts a named trace for an unnamed re-supplied net | ported | |
| TestIdentityFolds.test_a_mid_trace_identity_fact_is_replay_divergence | Instance identity / identity folds / refuses a mid-trace identity fact as replay divergence | ported | exact message (position 7) |
| TestIdentityFolds.test_the_identity_fact_is_occurrence_less_by_classification | Instance identity / identity folds / classifies the identity fact as occurrence-less | ported | |

## test_completion.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestStatusResolution.test_completed_when_quiescent_and_the_condition_holds | Instance completion / status resolution / is completed when quiescent and the condition holds | ported via CEL stub | `size(b) == 1`. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestStatusResolution.test_stuck_when_quiescent_and_the_condition_does_not_hold | Instance completion / status resolution / is stuck when quiescent and the condition does not hold | ported via CEL stub | `size(b) >= 2`. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestStatusResolution.test_terminated_stays_the_neutral_collapse_without_a_declaration | Instance completion / status resolution / stays the neutral terminated without a declaration | ported | |
| TestStatusResolution.test_running_while_enabled_even_when_the_condition_already_holds | Instance completion / status resolution / is running while enabled even when the condition already holds | ported via CEL stub | `size(a) == 1`. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestStatusResolution.test_the_condition_never_affects_enabledness_or_firing | Instance completion / status resolution / never affects enabledness or firing | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestStatusResolution.test_status_is_a_pure_projection_of_the_marking | Instance completion / status resolution / is a pure projection of the marking | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelEnvironment.test_place_variables_bind_token_color_and_data | — | ported in petrus-cel | `packages/petrus-cel/test/Impetus.hs`, on real Instances built with `Petrus.Cel.Impetus.celCompilers` (the example carries this test name). |
| TestCelEnvironment.test_a_black_token_reads_as_null_color_and_data | — | ported in petrus-cel | `packages/petrus-cel/test/Impetus.hs`, on real Instances built with `Petrus.Cel.Impetus.celCompilers` (the example carries this test name). |
| TestCelEnvironment.test_an_empty_place_binds_to_the_empty_list | — | ported in petrus-cel | `packages/petrus-cel/test/Impetus.hs`, on real Instances built with `Petrus.Cel.Impetus.celCompilers` (the example carries this test name). |
| TestNamedCompletion.test_named_symbol_binds_and_sees_the_marking | Instance completion / named completion / binds a named symbol that sees the marking | ported | |
| TestNamedCompletion.test_missing_implementation_fails_at_construction | Instance completion / named completion / fails at construction on a missing implementation | ported | exact message |
| TestCompletionValidation.test_invalid_cel_fails_at_construction_and_never_evaluates | Instance completion / completion validation / fails at construction on invalid CEL and never evaluates | ported via CEL stub | the stub answers the reference adapter's exact message; the kernel propagates it verbatim. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCompletionValidation.test_unknown_place_reference_fails_at_construction | Instance completion / completion validation / fails at construction on an unknown place reference | ported via CEL stub | the stub checks free names against the place list the kernel passes. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCompletionValidation.test_macro_bound_variables_are_not_place_references | — | ported in petrus-cel | `packages/petrus-cel/test/Impetus.hs`, on real Instances built with `Petrus.Cel.Impetus.celCompilers` (the example carries this test name). |
| TestCompletionValidation.test_a_non_symbol_non_cel_completion_is_rejected_at_build | — | enforced by types | `CompletionDeclaration` has only the symbol and `Cel` encodings |
| TestCompletionEvaluationErrors.test_a_raising_condition_reads_as_stuck_with_a_diagnostic | Instance completion / completion evaluation errors / reads a raising condition as stuck, with a diagnostic | ported | the warning is `statusWithDiagnostics`'s diagnostic; full text asserted |
| TestCompletionEvaluationErrors.test_unencodable_token_data_reads_as_stuck_with_a_diagnostic | — | enforced by types | token data is `Json`; an unencodable `object()` payload cannot exist |

## test_guard_branch.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestGuardDeclarationBindings.test_exact_declaration_uris_bind_same_named_guards_independently | Instance guards / guard declaration bindings / binds same-named guards independently by exact declaration URI | ported | |
| TestGuardDeclarationBindings.test_local_symbol_deliberately_shares_one_guard | Instance guards / guard declaration bindings / shares one guard through the local symbol | ported | |
| TestGuardDeclarationBindings.test_exact_and_local_binding_for_one_guard_is_ambiguous | Instance guards / guard declaration bindings / refuses an exact and a local binding for one guard as ambiguous | ported | exact message |
| TestGuardDeclarationBindings.test_anonymous_guard_requires_its_exact_declaration_uri | Instance guards / guard declaration bindings / requires the exact declaration URI for an anonymous guard | ported | exact message |
| TestGuardBranch.test_a_guard_failed_head_does_not_mask_a_deeper_admissible_selection | Instance guards / guard branch / does not let a guard-failed head mask a deeper admissible selection | ported | |
| TestGuardBranch.test_each_token_routes_by_its_own_guard | Instance guards / guard branch / routes each token by its own guard | ported | |
| TestGuardBranch.test_missing_guard_implementation_fails_at_construction | Instance guards / guard branch / fails at construction on a missing guard implementation | ported | exact message |
| TestGuardsSeeTheFullBinding.test_guard_correlates_consumed_and_read_tokens | Instance guards / guards see the full binding / correlates consumed and read tokens | ported | |
| TestGuardsSeeTheFullBinding.test_peeked_is_consumed_then_read_selections | Instance guards / guards see the full binding / peeks consumed selections, then read selections | ported | |
| TestGuardComposition.test_all_guards_must_hold | Instance guards / guard composition / requires all guards to hold | ported | |
| TestGuardEvaluationErrors.test_raising_guard_skips_the_binding_and_enablement_continues | Instance guards / guard evaluation errors / skips the binding of a raising guard and enablement continues | ported | `pytest.warns` -> a diagnostic from `candidatesWithDiagnostics` |
| TestGuardEvaluationErrors.test_an_unreadable_token_does_not_mask_a_deeper_valid_binding | Instance guards / guard evaluation errors / does not let an unreadable token mask a deeper valid binding | ported | same |
| TestGuardEvaluationErrors.test_the_diagnostic_carries_guard_transition_error_and_token | Instance guards / guard evaluation errors / carries the guard, transition, error, and token in the diagnostic | ported | full warning text asserted via `renderDiagnostic` |

## test_cel_guards.py

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| TestCelGuardRouting.test_a_cel_guard_failed_head_does_not_mask_a_deeper_admissible_selection | Instance CEL guards / CEL guard routing / does not let a CEL-guard-failed head mask a deeper admissible selection | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardRouting.test_each_token_routes_by_its_own_cel_guard | Instance CEL guards / CEL guard routing / routes each token by its own CEL guard | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardCorrelation.test_cel_guard_correlates_consumed_and_read_tokens | Instance CEL guards / CEL guard correlation / correlates consumed and read tokens | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestMixedGuards.test_named_and_cel_guards_compose_as_conjunction | Instance CEL guards / mixed guards / composes named and CEL guards as conjunction | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestMixedGuards.test_two_cel_guards_compose_as_conjunction | Instance CEL guards / mixed guards / composes two CEL guards as conjunction | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestMixedGuards.test_transitions_sharing_an_expression_share_one_sound_implementation | Instance CEL guards / mixed guards / lets transitions sharing an expression each enable off their own binding | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardValidation.test_invalid_cel_fails_at_construction_and_never_evaluates | Instance CEL guards / CEL guard validation / fails at construction on invalid CEL and never evaluates | ported via CEL stub | exact reference adapter message, propagated verbatim. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardValidation.test_a_place_not_feeding_the_transition_fails_at_construction | Instance CEL guards / CEL guard validation / fails at construction on a place not feeding the transition | ported via CEL stub | the stub checks names against the scope the kernel computes. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardValidation.test_an_inhibit_only_place_is_outside_the_guard_scope | Instance CEL guards / CEL guard validation / keeps an inhibit-only place outside the guard scope | ported via CEL stub | kernel scope excludes inhibit arcs. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardValidation.test_a_shared_expression_is_validated_against_each_declaring_transitions_scope | Instance CEL guards / CEL guard validation / validates a shared expression against each declaring transition's scope | ported via CEL stub | kernel compiles per declaration. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardValidation.test_a_read_place_is_inside_the_guard_scope | Instance CEL guards / CEL guard validation / keeps a read place inside the guard scope | ported via CEL stub | kernel scope includes read arcs. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardValidation.test_macro_bound_variables_are_not_place_references | — | ported in petrus-cel | `packages/petrus-cel/test/Impetus.hs`, on real Instances built with `Petrus.Cel.Impetus.celCompilers` (the example carries this test name). |
| TestCelGuardValidation.test_a_non_symbol_non_cel_guard_is_rejected_at_declaration | — | enforced by types | `GuardDeclaration` has only the symbol, `Cel`, and anonymous encodings |
| TestCelGuardEvaluationErrors.test_a_raising_cel_guard_skips_the_binding_and_enablement_continues | Instance CEL guards / CEL guard evaluation errors / skips the binding of a raising CEL guard and enablement continues | ported via CEL stub | Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
| TestCelGuardEvaluationErrors.test_the_diagnostic_carries_expression_transition_error_and_tokens | Instance CEL guards / CEL guard evaluation errors / carries the expression, transition, error, and tokens in the diagnostic | ported via CEL stub | the stub raises the reference's `CELEvalError(...)` spelling; the full warning text is asserted. Rerun on real CEL (`celCompilers`) in petrus-cel `test/KernelSeam.hs`. |
