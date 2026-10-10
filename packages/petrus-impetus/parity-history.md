# Parity ledger: history slice

Upstream files (under `tests/petrus/impetus/`): `selection/test_selection.py`,
`history/test_history.py`, `history_store/test_history_backends.py` (in-memory
store and generic store contract), `history_store/test_persistence.py`
(schema-5 codec, line spelling, injection seam, raising appends), and the
History/Instance halves of `petrinet/test_read_arc.py` and
`petrinet/test_arc_filters.py`, plus `petrinet/test_golden_replay.py`.

`petrinet/test_arc_weights.py` and `petrinet/test_inhibitor_arc.py` assert no
History records or replay; all of their cases are already ported in
`EnablednessSpec` and `FiringSpec`. The cases of `test_read_arc.py` and
`test_arc_filters.py` not listed here are ported in `EnablednessSpec`,
`ArcFiltersSpec`, and `FiringSpec`.

The durable-backend fixture: `test_history_backends.py` runs over a `reopen`
fixture for JSONL/SQLite/Postgres. Here every case runs over `newReopen`
(`test/Petrus/Impetus/HistorySupport.hs`): a storage of schema-5 JSON lines and a
fresh `mirroredHistoryStore` loaded from it on each call. That keeps the
kill-and-reload move and the real JSON round trip.

| upstream test | Haskell spec (describe / it) | status | note |
| --- | --- | --- | --- |
| **selection/test_selection.py** | | | |
| test_first_proposes_immutably_and_empty_offer_bypasses_choice | Selection / First proposes the head immutably and an empty offer bypasses choice | ported | `is` becomes `==` |
| test_priority_is_stable_for_equal_and_unconfigured_transitions | Selection / Priority is stable for equal and unconfigured transitions | ported | |
| test_round_robin_proposes_next_state_without_mutating_prior_state | Selection / RoundRobin proposes the next state without mutating the prior state | ported | |
| test_round_robin_validates_cursor_and_wraps_the_last_position_to_zero | Selection / RoundRobin validates the cursor and wraps the last position to zero | ported | |
| test_round_robin_rejects_invalid_cursor_state[-1], [3] | Selection / RoundRobin rejects an invalid cursor state | ported | exact messages |
| test_round_robin_rejects_invalid_cursor_state[True], ['1'] | — | enforced by types | the cursor is `Maybe Int` |
| test_pipeline_filters_then_stably_ranks_then_runs_one_strategy | Selection / the pipeline filters, then stably ranks, then runs one strategy | ported | The call-order log is not asserted: pure filters and rankers have no observable call order. |
| test_all_filtered_bypasses_strategy_and_custom_strategy_is_boundary_checked | Selection / an all-filtered offer bypasses the strategy, and a custom strategy is boundary-checked | ported | A strategy that refuses if consulted stands in for `calls == 0`. Exact messages. |
| test_multiple_filters_and_rankers_preserve_order_and_final_ties | Selection / multiple filters and rankers preserve order and final ties | ported | The call log is not asserted (pure filters). |
| test_replay_folds_only_exact_committed_selection_pairs_and_spends_orphans | Selection / replay folds only exact committed selection pairs and spends orphans | ported | over `inMemoryHistoryStore` |
| test_replay_threads_accumulated_policy_state_through_committed_pairs | Selection / replay threads accumulated policy state through committed pairs | ported | |
| test_replay_refuses_duplicate_or_mismatched_selection_lifecycle[0..2] | Selection / test_replay_refuses_... / (3 its) | ported | exact messages |
| **history/test_history.py** | | | |
| TestExternalEventDelivered.test_identity_must_be_a_non_empty_string | History / ExternalEventDelivered / requires a non-empty string identity | ported | Checked through `recordInvariants`. The `7` and `None` identities are enforced by types. |
| TestReplayMarking.test_rebuilds_marking_from_recorded_movements | History / replayMarking / rebuilds the marking from recorded movements | ported | |
| TestReplayMarking.test_projects_each_complete_marking_from_one_history_iteration | History / replayMarking / projects each complete marking from one history iteration | ported | |
| TestReplayMarking.test_empty_history_is_an_empty_marking | History / replayMarking / an empty history is an empty marking | ported | |
| TestReplayMarking.test_only_movement_records_affect_the_marking | History / replayMarking / only movement records affect the marking | ported | |
| TestReplayMarking.test_tokens_read_is_a_movement_category_record_yet_replay_inert | History / replayMarking / TokensRead is a movement-category record, yet replay-inert | ported | |
| TestReplayMarking.test_a_diverging_consume_record_fails_loud | History / replayMarking / a diverging consume record fails loud | ported | exact message |
| **history_store/test_history_backends.py** | | | |
| `reopen` fixture params jsonl / sqlite / postgres | — | ported in petrus-history-store (jsonl) | The jsonl parameter: `packages/petrus-history-store/test/Petrus/HistoryStore/BackendContractSpec.hs` runs `test_history_backends.py` over the real JSONL store. The sqlite and postgres parameters wait for those backends, which are out of scope as `test_sqlite_history.py` and `test_postgres_history.py` are. |
| TestRoundTrip.test_a_store_contains_history_without_being_history | HistoryStore contract / round trip / a store contains history | ported | The `isinstance` half is enforced by types: a store is one record of operations. |
| TestRoundTrip.test_every_record_category_round_trips_value_equal | HistoryStore contract / round trip / every record category round-trips value-equal | ported | |
| TestRoundTrip.test_append_and_extend_accumulate_and_a_reload_continues | HistoryStore contract / round trip / append and extend accumulate, and a reload continues | ported | |
| TestRoundTrip.test_durable_before_in_memory | HistoryStore contract / round trip / is durable before in memory | ported | |
| TestRoundTrip.test_an_unencodable_record_fails_loud_and_enters_nothing | — | enforced by types | Token data is `Json`; the one unencodable `Json` (non-finite) is the NaN case. |
| TestRoundTrip.test_nan_token_data_is_refused_loud_on_both_backends | HistoryStore contract / round trip / a refused (NaN) record fails loud and enters nothing | ported | The refusal text belongs to the backend. Asserted: the write throws, and neither the mirror nor the storage takes anything. |
| TestRoundTrip.test_a_mid_batch_encode_failure_writes_nothing | HistoryStore contract / round trip / a mid-batch encode failure writes nothing | ported | Infinity stands in for `object()`. |
| TestInstanceParity.test_construction_over_a_recorded_history_is_rejected | HistoryStore contract / Instance parity / construction over a recorded history is rejected | ported | exact message |
| TestInstanceParity.test_a_full_drive_kills_and_resumes_identical | HistoryStore contract / Instance parity / a full drive kills and resumes identical | ported | |
| TestInstanceParity.test_the_occurrence_counter_resumes_past_every_recorded_id | HistoryStore contract / Instance parity / the occurrence counter resumes past every recorded id | ported | `isinstance(FiringOutcome)` holds by type |
| TestInstanceParity.test_the_accepted_identity_index_resumes_from_the_records | HistoryStore contract / Instance parity / the accepted-identity index resumes from the records | ported | |
| TestInstanceParity.test_the_terminal_activity_index_resumes_from_the_records | HistoryStore contract / Instance parity / the terminal-activity index resumes from the records | ported | exact message |
| TestKillWindowParity.test_killed_after_the_begin_batch_resumes_and_redispatches | HistoryStore contract / kill-window parity / killed after the begin batch: resumes and redispatches | ported | `prepared == 0`: the resumed handler's prepare refuses if consulted. `projected == 1`: the one projected receipt. |
| TestKillWindowParity.test_killed_after_the_frozen_result_resumes_projection_pending | HistoryStore contract / kill-window parity / killed after the frozen result: resumes projection-pending | ported | same counting translation |
| **history_store/test_persistence.py** | | | |
| TestRecordCodec.test_every_record_category_round_trips_value_equal | History codec / record codec / every record category round-trips value-equal | ported | Completeness check: an exhaustive `category` match, so a new constructor fails `-Werror`. The round trip goes through `dumps`/`parseJson` text. |
| TestRecordCodec.test_the_ratified_wire_shape | History codec / record codec / spells the ratified wire shape | ported | |
| TestRecordCodec.test_schema_5_is_the_only_current_record_spelling | History codec / record codec / schema 5 is the only current record spelling | ported | exact message |
| TestRecordCodec.test_schema_5_refuses_partial_or_invalid_scope_provenance | History codec / record codec / schema 5 refuses partial or invalid scope provenance | ported | exact messages; every generation/name value spelled as JSON |
| TestRecordCodec.test_token_data_must_be_json_faithful_to_round_trip | — | enforced by types | `Json` has no tuple to read back as a list. |
| TestRecordCodec.test_an_unknown_record_name_fails_loud | History codec / record codec / an unknown record name fails loud | ported | exact message |
| TestRecordCodec.test_a_payload_without_a_discriminator_fails_loud | History codec / record codec / a payload without a discriminator fails loud | ported | exact message |
| TestRecordCodec.test_field_drift_fails_as_the_record_types_own_rejection | History codec / record codec / field drift fails as the record type's own rejection | ported | Python's `TypeError` becomes a `Left` with the same text. |
| TestRecordCodec.test_schema_5_activity_request_refuses_noncanonical_policy_shapes[policy0..3] | History codec / record codec / test_schema_5_activity_request_refuses_noncanonical_policy_shapes / (4 its) | ported | exact messages, including the Python dict repr |
| TestRecordCodec.test_a_delivery_identity_must_be_a_non_empty_string_to_decode | History codec / record codec / a delivery identity must be a non-empty string to decode | ported | exact messages |
| TestRecordCodec.test_a_payload_without_a_schema_version_fails_naming_the_migration | History codec / record codec / a payload without a schema version fails naming the migration | ported | exact message |
| TestRecordCodec.test_a_wrong_schema_version_fails_naming_the_migration | History codec / record codec / a wrong schema version fails naming the migration | ported | 1, True, 5.0, '5' |
| TestRecordCodec.test_schema_2_is_refused_before_record_interpretation | History codec / record codec / schema 2 is refused before record interpretation | ported | |
| TestRecordCodec.test_schema_3_is_refused_before_record_interpretation | History codec / record codec / schema 3 is refused before record interpretation | ported | |
| TestRecordCodec.test_unversioned_old_discriminators_are_refused_before_interpretation | History codec / record codec / unversioned old discriminators are refused before interpretation | ported | |
| TestDurableAppend.test_appends_accumulate_across_calls | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestDurableAppend / appends accumulate across calls", against the real JSONL store. |
| TestDurableAppend.test_makes_the_parent_directory_once_needed | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestDurableAppend / makes the parent directory once needed", against the real JSONL store. |
| TestJsonlHistoryStore.test_the_durable_spelling_is_byte_stable | History codec / durable line spelling / the durable spelling is byte-stable | ported | Each line is pinned byte for byte in both directions (`json.dumps` spelling). Writing the file is the backend's job. |
| TestJsonlHistoryStore.test_direct_firing_lifecycle_jsonl_bytes_are_stable | History codec / durable line spelling / the direct firing lifecycle's lines are byte-stable | ported | lines, not the file |
| TestJsonlHistoryStore.test_every_append_is_durable_immediately | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / every append is durable immediately", against the real JSONL store. |
| TestJsonlHistoryStore.test_loading_then_appending_continues_the_file | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / loading then appending continues the file", against the real JSONL store. |
| TestJsonlHistoryStore.test_a_missing_file_is_an_empty_history | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / a missing file is an empty history", against the real JSONL store. |
| TestJsonlHistoryStore.test_a_v1_encoded_line_fails_loud_at_load_naming_the_migration | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / a v1-encoded line fails loud at load naming the migration", against the real JSONL store. |
| TestJsonlHistoryStore.test_a_schema_2_line_fails_through_the_actual_jsonl_load | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / a schema-2 line fails through the actual JSONL load", against the real JSONL store. |
| TestJsonlHistoryStore.test_a_torn_tail_fails_loud_naming_the_line | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / a torn tail fails loud naming the line", against the real JSONL store. |
| TestJsonlHistoryStore.test_unencodable_data_fails_loud_and_appends_nothing | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / unencodable data fails loud and appends nothing", against the real JSONL store. |
| TestJsonlHistoryStore.test_a_mid_batch_encoding_failure_writes_nothing | — | ported in petrus-history-store | `packages/petrus-history-store/test/Petrus/HistoryStore/JsonlSpec.hs` / "TestJsonlHistoryStore / a mid-batch encoding failure writes nothing", against the real JSONL store. |
| TestInstanceDurableHistory.test_construction_records_are_durable_at_construction | History codec / Instance over an injected history / construction records are durable at construction | ported | over `newReopen` |
| TestInstanceDurableHistory.test_every_appending_door_writes_through | History codec / Instance over an injected history / every appending door writes through | ported | over `newReopen` |
| TestInstanceDurableHistory.test_a_refused_delivery_payload_leaves_the_instance_unchanged | History codec / Instance over an injected history / a refused delivery payload leaves the instance unchanged | ported | NaN stands in for `object()`; exact Python NaN message |
| TestInstanceDurableHistory.test_a_recorded_history_is_rejected_at_construction | History codec / Instance over an injected history / a recorded history is rejected at construction | ported | exact messages (2 and 1 records) |
| TestARaisingAppendMovesNothingElse.test_a_refused_seal_keeps_the_registration_armed | History codec / a raising append moves nothing else / a refused seal keeps the registration armed | ported | `RefusingHistory` is built with `mirroredHistoryStore`; `OSError` becomes `IOError` |
| TestARaisingAppendMovesNothingElse.test_a_refused_complete_leaves_the_occurrence_in_flight | History codec / a raising append moves nothing else / a refused complete leaves the occurrence in flight | ported | |
| **petrinet/test_read_arc.py** (History/Instance half) | | | |
| TestReadArc.test_begin_records_the_read_selection_in_the_begin_batch | Petrinet.Firing through the Instance / read arcs / begin records the read selection in the begin batch | ported | The kernel half is in FiringSpec. |
| TestReadArc.test_a_binding_that_consumes_its_own_read_token_cannot_begin | Petrinet.Firing through the Instance / read arcs / a binding that consumes its own read token cannot begin | ported | exact Instance message ("stale selection — ..."); nothing appended |
| TestReadArc.test_the_read_validates_against_the_surviving_token | Petrinet.Firing through the Instance / read arcs / the read validates against the surviving token | ported | |
| TestReadArc.test_tokens_read_is_replay_inert_for_the_marking | Petrinet.Firing through the Instance / read arcs / TokensRead is replay-inert for the marking | ported | |
| **petrinet/test_arc_filters.py** (History/Instance half) | | | |
| TestColoredConsumeSelection.test_movement_records_carry_the_selected_token_and_replay | Petrinet.Firing through the Instance / colored consume selection / movement records carry the selected token, and replay | ported | |
| TestNamedFilterSelection.test_movement_records_carry_the_filter_selected_token_and_replay | Petrinet.Firing through the Instance / named filter selection / movement records carry the filter-selected token, and replay | ported | |
| TestNamedFilterSelection.test_missing_filter_implementation_fails_at_construction | Petrinet.Firing through the Instance / named filter selection / a missing filter implementation fails at construction | ported | The Instance half, with the exact message. The kernel half is in ArcFiltersSpec. |
| TestNamedFilterSelection.test_exact_and_bare_filter_binding_is_ambiguous | Petrinet.Firing through the Instance / named filter selection / an exact and a bare filter binding is ambiguous | ported | exact message |
| TestCelFilterSelection.test_cel_selection_consumes_and_replays_like_any_other | Petrinet.Firing through the Instance / CEL filter selection / consumes and replays like any other selection | ported via CEL stub | |
| TestCelFilterSelection.test_invalid_cel_fails_at_construction_and_never_evaluates | Petrinet.Firing through the Instance / CEL filter selection / invalid CEL fails at construction and never evaluates | ported via CEL stub | The stub returns the CEL package's compile error text. |
| TestCelFilterSelection.test_exact_override_of_inline_cel_filter_is_refused | Petrinet.Firing through the Instance / CEL filter selection / an exact override of an inline CEL filter is refused | ported via CEL stub | The refusal is the kernel's and comes before compilation. |
| **petrinet/test_golden_replay.py** | | | |
| test_manifest_hashes_every_normative_fixture | Impetus golden traces / the manifest hashes every normative fixture | ported | Ported after this slice, with the golden-trace generator (`GoldenTracesSpec`). |
| test_migration_contracts_are_visible_in_raw_fixtures | Impetus golden traces / migration contracts are visible in raw fixtures | ported | `GoldenTracesSpec`. |
| test_normative_fixture_replays | Impetus golden traces / normative fixtures replay / (one per fixture) | ported | `GoldenTracesSpec` ports `tests/harness.py::replay` over the Net-definition compiler. |

## Extra properties (not upstream; no Hypothesis in these files)

- Selection / properties: the round-robin replay state is one past the last committed transition; First's fold is the identity.
- History / properties: k front-to-back moves (with reads) replay to the moved queue; `replayMarkings` yields one marking per record and ends at `replayMarking`.
- History codec / record codec / properties: arbitrary movement records round-trip through JSON text; every decoded category re-encodes to its payload.

## Counts

81 rows: 64 ported, 3 ported via CEL stub, 3 enforced by types, 11 ported in
`petrus-history-store` (the JSONL store and its `reopen` parameter)
(the three golden-replay rows were ported after the slice, in `GoldenTracesSpec`).
No kernel (`src/`) changes were needed.
