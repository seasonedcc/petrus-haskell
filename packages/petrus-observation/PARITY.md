# petrus-observation: parity with the Python reference

This file maps every upstream test of `petrus.impetus.observation`
(`upstream/petrus/tests/petrus/engine/test_observation.py` and
`test_observation_http.py`) to its Haskell counterpart in
`test/Petrus/Observation/ObservationSpec.hs`. Each Hspec example has a
`-- test_name` comment naming the upstream test it ports.

Statuses:

- **ported**: the same scenario with the same assertions. The reference
  drives an `Engine`; the port drives the same Instance doors the Engine
  performs, under the Engine's simulated clock (see `Support.hs`), then
  projects with `capture` and the pure projections.
- **enforced by types**: the case can't be represented in Haskell.
- **deferred**: it needs the Engine (its lock, re-entry guard, or commit
  poisoning) or the HTTP adapter. Neither exists yet in this repository.

Fixtures are compared byte for byte: the produced value, written with
`dumps indented` plus a trailing newline, must equal the fixture file's bytes.
The fixtures are `spec/observation/engine-snapshot-v1.json`,
`spec/observation/engine-history-page-v1.json`,
`spec/net-document-v1-observation.json`, and
`spec/net-document-v1-inspection.json`.
(`spec/observation/simulation-service-profile-v1.json` belongs to the
simulation HTTP service, so it is out of scope here.)

## Summary

Counts are upstream test functions. A parametrized test counts once; its
parameters are separate Hspec examples where they are ported.

| upstream file | ported | partly by types | by types | deferred |
| --- | ---: | ---: | ---: | ---: |
| engine/test_observation.py (19) | 12 | 3 | 1 | 3 |
| engine/test_observation_http.py (7) | | | | 7 |

The Hspec suite has 51 examples:

- 22 port upstream tests (parametrized cases are separate examples).
- 3 test the Haskell seam.
- 26 come from the differential corpus: 10 scenarios and 16 refusals.

## engine/test_observation.py

| upstream test | status | notes |
| --- | --- | --- |
| test_exact_definition_shape_order_declarations_uris_and_duplicate_arcs | ported | |
| test_canonical_net_inspection_fixture_is_exact_pre_instance_dsl_build_without_implementations | ported | The net is built with `mkNet` in the DSL's first-touch order (the Haskell DSL is a separate package). |
| test_canonical_fixture_is_exact_producer_output_and_has_typed_fifo_activity_pending_state | ported | byte for byte |
| test_canonical_history_fixture_is_exact_complete_page_with_current_typed_occurrences | ported | byte for byte |
| test_protocol_v1_history_transports_one_field_complete_current_schema | ported | |
| test_canonical_observed_net_document_fixture_has_one_complete_marking_per_history_record | ported | byte for byte |
| test_capture_pages_freeze_snapshot_frontier_while_history_continues_to_append | ported | |
| test_snapshot_reports_pure_and_projection_pending_phases_and_detaches_frozen_result | ported | Mutating the result afterwards can't happen: Haskell values are immutable. |
| test_snapshot_detaches_a_classified_failure_while_its_firing_terminal_is_pending | ported | |
| test_snapshot_detaches_nested_tokens_and_activity_values | ported | Detachment is by construction. The test checks that the nested values are carried exactly. |
| test_protocol_strictly_refuses_non_integer_timer_values | partly by types | Ported: `Delay(1.5)` and `Until(1.5)`. Enforced by types: `Delay(True)`, `Delay("1")`, `Until(True)` and `Until("1")`, because a timer holds a `Number`. |
| test_definition_strictly_refuses_non_json_output | by types | A net name is `Text`, so `object()` can't be stored. |
| test_snapshot_emits_integer_next_maturation_and_refuses_boolean_when_reachable | partly by types | Ported: the integer `next_maturation`. `Until(True)` can't be built, so the reachable non-integer, `Until(1.5)`, is refused instead (same message). |
| test_history_page_refuses_malformed_cursor_or_limit | ported | All 6 cases go through `historyCursor`, the Json-level validator (`True` and `0.5` are Json values). A seventh example covers the typed `Integer` API. |
| test_strict_json_refuses_nonfinite_and_unencodable_nested_data_and_bad_current_time | partly by types | Ported: NaN token data, and a non-integer watermark, using a float instead of `True`. Enforced by types: `{"bad": object()}` (token data is `Json`) and a boolean watermark (an `Instant` is a `Number`). |
| test_cursor_algebra_polling_concurrent_arrival_and_reconnect_have_no_gap_or_duplicate | ported | |
| test_snapshot_blocks_between_append_and_projection_then_sees_coherent_after_state | deferred (Engine) | It tests the Engine lock, which makes a reader wait for a writer's append and projection. The seam is described in `DIVERGENCES.md` §1: `capture` must run under that exclusion. |
| test_same_thread_public_reentry_is_refused_but_sensor_status_observation_remains_supported | deferred (Engine) | It tests the Engine's re-entry guard. |
| test_joined_commit_failure_poisons_observation_and_hides_uncommitted_frontier | deferred (Engine) | It tests the Engine's commit poisoning. |

## engine/test_observation_http.py: deferred to the HTTP adapter

All 7 functions test the observation HTTP adapter (routes, headers, query
grammar, 405/404/OPTIONS, and transport shutdown) over a live Engine:

- test_factory_binds_without_starting_a_hidden_thread
- test_snapshot_document_history_and_required_http_headers_are_exact
- test_history_query_grammar_is_exact (parametrized over the query string)
- test_future_cursor_is_a_protocol_400
- test_mutation_methods_are_405_and_never_reach_engine (POST, PUT, DELETE)
- test_unknown_route_options_and_closed_engine
- test_transport_shutdown_does_not_close_engine_and_engine_keeps_executing

The projections those routes serve (`snapshot`, `historyPage` with the
`historyCursor` refusal texts, and `netDocument`) are ported here. The adapter
should be built on them.

## Differential corpus

`differential/observation_corpus.py` drives a reference Engine through 10
scenarios and records its three read doors, plus 16 refusal texts. The
generator and its output (`observation_corpus.json`) are both committed.

- Scenarios: canonical, a frozen result, a frozen failure, projected-then-next-begun, pure pending, detached nested values, a timer, a closed scope, a sealed source, and non-ASCII place ordering.
- Refusals: float and unsafe timers, NaN, ±inf, an unsafe integer in a document, a float watermark, every malformed cursor, a future cursor, and an empty History.

`CorpusSpec` rebuilds each scenario with Instance doors and requires the
snapshot, `history_page(0, 1000)`, and `net_document` to be exactly equal
(`exactEq`: member order and int/float spelling included), and every refusal
to have the same full text.

To regenerate the corpus:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-observation/differential/observation_corpus.py
