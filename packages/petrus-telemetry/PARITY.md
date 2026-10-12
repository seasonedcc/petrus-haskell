# petrus-telemetry: parity with the Python reference

`petrus-telemetry` ports `petrus/telemetry.py`. It is layer zero: it depends
on nothing in the runtime except the JSON value model and petrus-posix,
whose memory gauges (`max_rss_mb`, `current_rss_mb`) it re-exports. The `impetus_*` events that the Instance, the
Engine and the JSONL History store emit through it are checked by
[`petrus-telemetry-instrumentation`](../petrus-telemetry-instrumentation/PARITY.md).
That package exists only to hold tests and a benchmark, so the library never
depends on what it instruments.

Every Hspec example is named after the upstream test it ports.
Divergences are listed in [DIVERGENCES.md](DIVERGENCES.md).

## Evidence

| What | Where | Result |
| --- | --- | --- |
| `test_telemetry.py`, 29 tests | `petrus-telemetry/test/Main.hs` | 28 ported, 1 unrepresentable (DIVERGENCES 13); 36 examples, 0 failures |
| `test_telemetry_instrumentation.py`, 22 tests | `petrus-telemetry-instrumentation/test/Petrus/Telemetry/InstrumentationSpec.hs` | all 22 ported as is |
| Instrumentation differential: 25 scenarios, 290 events, compared raw | [`differential/`](../petrus-telemetry-instrumentation/differential), `DifferentialSpec.hs` | every event name, field, field order and value is exact, and every routed line is byte-identical with `ts` pinned |
| Routed-line bytes | `pinned` in the differential fixture | 4 fixed payloads, including non-ASCII, non-finite floats, a payload `ts`, and the benchmark payload |
| Overhead benchmark | [`bench/RESULTS.md`](../petrus-telemetry-instrumentation/bench/RESULTS.md) | a routed emit costs 2.5 µs vs Python's 4.5 µs; the default (no route) costs 0.06 µs vs 2.6 µs; `profile`-level gauges on a 1 000-firing Engine chain cost ~25 µs per firing routed vs ~52 µs |

The instrumentation suite runs 56 examples, 0 failures:

- the 22 ported tests;
- 4 Haskell-specific examples;
- 30 differential examples. One of them regenerates the reference's events
  from the pinned checkout; it provisions the reference through
  `scripts/upstream-python` and fails, never goes pending, when it cannot.

## `test_telemetry.py` → `petrus-telemetry/test/Main.hs`

| Upstream test | Haskell example | |
| --- | --- | --- |
| `test_stdlib_logger_preserves_its_operational_identity` | `stdlib logger preserves its operational identity` | ported (`telemetryLoggerName`) |
| `TestTelemetryLoggerEmit::test_json_logger_writes_namespaced_json_log_line_stamped_with_wall_clock_ts` | `TelemetryLogger emit` / `json logger writes namespaced json log line stamped with wall clock ts` | ported |
| `TestTelemetryLoggerEmit::test_json_logger_spells_non_json_values_as_strings` | `json logger spells non json values as strings` | ported (`exceptionJson`; DIVERGENCES 7) |
| `TestTelemetryLoggerEmit::test_recorder_payloads_carry_no_wall_clock_ts` | `recorder payloads carry no wall clock ts` | ported |
| `TestTelemetryLoggerEmit::test_injected_recorder_receives_bound_structured_payloads` | `injected recorder receives bound structured payloads` | ported |
| `TestTelemetryLoggerEmit::test_capture_replaces_default_sink_for_existing_loggers` | `capture replaces default sink for existing loggers` | ported |
| `TestTelemetryLoggerEmit::test_capture_restores_the_previous_sink_on_exit` | `capture restores the previous sink on exit` | ported |
| `TestTelemetryLoggerEmit::test_capture_uses_provided_empty_recorder` | `capture uses provided empty recorder` | ported |
| `TestTelemetryLoggerEmit::test_bound_context_is_inherited_without_mutating_parent` | `bound context is inherited without mutating parent` | ported |
| `TestTelemetryLoggerEmit::test_rebinding_existing_context_field_fails_loudly` | `rebinding existing context field fails loudly` | ported (`Either`; DIVERGENCES 4) |
| `TestTelemetryLoggerEmit::test_emit_cannot_override_bound_context_field` | `emit cannot override bound context field` | ported (DIVERGENCES 4) |
| `TestTelemetryLoggerEmit::test_a_failing_sink_never_gates_execution` | `a failing sink never gates execution` | ported (DIVERGENCES 5) |
| `TestTelemetrySpan::test_elapsed_time_before_span_entry_fails_with_lifecycle_error` | — | not ported: an unstarted span is unrepresentable (DIVERGENCES 13) |
| `TestTelemetrySpan::test_span_emits_started_and_finished_events_with_result_fields` | `span emits started and finished events with result fields` | ported |
| `TestTelemetrySpan::test_failed_span_emits_failed_status_and_reraises` | `failed span emits failed status and reraises` | ported (DIVERGENCES 3) |
| `TestTelemetrySpan::test_child_span_inherits_parent_span_context` | `child span inherits parent span context` | ported |
| `TestTelemetrySpan::test_span_emit_inherits_span_context` | `span emit inherits span context` | ported |
| `TestTelemetrySpan::test_span_accumulate_time_sums_repeated_timing_fields` | `span accumulate time sums repeated timing fields` | ported (injected clock; DIVERGENCES 8) |
| `TestTelemetrySpan::test_span_accumulate_time_is_retained_when_block_fails` | `span accumulate time is retained when block fails` | ported |
| `TestTelemetrySpan::test_span_increments_counter_fields` | `span increments counter fields` | ported |
| `TestTelemetrySpan::test_span_milestone_emits_elapsed_time_since_span_started` | `span milestone emits elapsed time since span started` | ported |
| `TestLevels::test_default_level_is_facts` | `Levels` / `default level is facts` | ported |
| `TestLevels::test_unknown_level_is_refused_loud` | `unknown level is refused loud` | ported (`parseLevel`; DIVERGENCES 2) |
| `TestLevels::test_off_silences_every_emit` | `off silences every emit` | ported |
| `TestLevels::test_at_level_orders_the_ladder` | `at level orders the ladder` | ported |
| `TestLevels::test_capture_restores_the_previous_level` | `capture restores the previous level` | ported |
| `TestMaxRss::test_reports_positive_megabytes` | `MaxRss` / `reports positive megabytes` | ported |
| `TestCurrentRss::test_parses_resident_pages_from_statm` | `CurrentRss` / `parses resident pages from statm` | ported |
| `TestCurrentRss::test_returns_none_when_statm_unavailable` | `returns none when statm unavailable` | ported |

Haskell-specific examples:

- routes byte-identical CPython `json.dumps` lines;
- a payload `ts` keeps its position with the stamped value;
- the default route drops lines;
- names duplicate fields sorted;
- result fields keep first-set order ahead of status;
- `error_type` names the Python class the reference reports;
- quotes unknown levels like Python's repr;
- statm parsing refuses malformed contents.

## `test_telemetry_instrumentation.py` → `petrus-telemetry-instrumentation/test/Petrus/Telemetry/InstrumentationSpec.hs`

Each example keeps the upstream test's name, under a `describe` named after
its upstream class.

| Upstream test | |
| --- | --- |
| `TestKernelDoorEvents::test_construction_emits_instance_created` | ported |
| `TestKernelDoorEvents::test_step_emits_begun_then_completed_correlated_by_occurrence` | ported |
| `TestKernelDoorEvents::test_a_fruitless_step_emits_nothing` | ported |
| `TestKernelDoorEvents::test_a_raising_handler_emits_firing_failed` | ported (the handler returns the reference's failure text; DIVERGENCES 16) |
| `TestKernelDoorEvents::test_acceptance_and_completion_emit_the_delivery_lifecycle_and_redelivery_answer` | ported |
| `TestKernelDoorEvents::test_the_supplied_identity_is_spelled_on_the_acceptance` | ported |
| `TestKernelDoorEvents::test_seal_emits_the_closed_count` | ported |
| `TestKernelDoorEvents::test_wake_emits_only_when_a_maturation_derives` | ported |
| `TestKernelDoorEvents::test_resume_emits_instance_resumed_under_the_recorded_identity` | ported |
| `TestJsonlCommitEvents::test_every_durable_commit_emits_batch_size_bytes_and_latency` | ported |
| `TestEngineSpan::test_advance_is_a_span_whose_counters_summarize_the_turn` | ported |
| `TestEngineSpan::test_a_halting_advance_finishes_the_span_failed` | ported (`error_type` is `RuntimeError`, DIVERGENCES 15) |
| `TestInstanceIdentity::test_every_door_event_carries_the_minted_identity` | ported |
| `TestInstanceIdentity::test_two_instances_mint_distinct_identities` | ported |
| `TestInstanceIdentity::test_the_driver_span_carries_the_instance_identity` | ported |
| `TestInstanceIdentity::test_a_named_net_stamps_the_kind_beside_the_identity` | ported |
| `TestInstanceIdentity::test_resume_speaks_the_recorded_identity_not_a_resupplied_one` | ported |
| `TestInstanceIdentity::test_a_trace_without_identity_refuses_before_emitting_resume` | ported |
| `TestPhaseTimings::test_drive_finished_breaks_the_loop_down_by_phase` | ported |
| `TestGauges::test_profile_level_emits_state_gauges_each_firing` | ported |
| `TestGauges::test_facts_level_gathers_no_gauges` | ported |
| `TestEngineOutcomeSpan::test_drive_span_reports_actions_firings_and_waiting` | ported |

Haskell-specific examples:

- **An all-filtered offer emits `candidate_selection_declined` with the
  enabled count.** This is the telemetry half of `test_coordinator.py`'s
  `test_all_filtered_appends_no_history_and_emits_decline_telemetry`. The
  Engine's suite checks the History half.
- Level off silences every door, span and commit.
- An explicit Instance or Engine sink bypasses the process default
  (DIVERGENCES 17).
- A failing sink never breaks a run.

## Events emitted by other components

The reference also emits telemetry from components with their own rows in
the top-level [PARITY.md](../../PARITY.md), whose Haskell ports emit them
through this library:

- the workers (`worker_started`, `worker_stopped`, and a span per
  activity);
- the local and Absurd dispatch;
- the Postgres History store's commit event;
- the Postgres fabric (`fabric_*`);
- the Postgres processes store (`lifecycle_*`).

Those events are part of each component's own parity, and none of them has
an upstream test in either telemetry test file. Every event kind the
Instance, the Engine and the JSONL store emit appears in the differential:

`instance_created`, `instance_resumed`, `firing_begun`, `firing_completed`,
`firing_failed`, `delivery_accepted`, `delivery_redelivered`,
`delivery_conflicted`, `activity_result_recorded`,
`activity_redelivery_acknowledged`, `activity_cancelled`,
`registrations_sealed`, `timer_matured`, `candidate_selection_declined`,
`drive_started`, `drive_finished`, `gauges` and `jsonl_commit`.
