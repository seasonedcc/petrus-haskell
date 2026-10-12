# petrus-simulation: parity with the Python reference

This package ports two upstream modules at the pin in
[UPSTREAM.md](../../UPSTREAM.md):

- `Petrus.Simulation` is `petrus.simulation`, the bounded runner, profile
  `implementation-free-v1`.
- `Petrus.Simulation.Http` is `petrus.simulation_http`, simulation HTTP
  profile 1.

The claim is byte identity:

- For any build, marking and `max_actions`, `simulate` returns the
  reference's bytes, or refuses with the reference's `SimulationProfileError`
  message.
- For any request, the service answers with the reference's response,
  except for the `Server` and `Date` header values.

See [DIVERGENCES.md](DIVERGENCES.md) for the exceptions.

`cabal test petrus-simulation` runs the suite with no failure and no pending example. Its groups:

- `test_simulation.py`;
- `test_simulation_http.py`;
- `spec/simulation-http-v1.md` conformance;
- Wire identity;
- Differential corpus;
- Python clients.

Each upstream test is one example named after it. Parametrized tests have
one example per parameter, so the two modules' 43 functions are the 98
cases `pytest --collect-only` counts.

## Upstream tests: `tests/petrus/engine/test_simulation.py` (`test/RunnerSpec.hs`)

There are 19 functions and 27 items. The test-support module
`tests/simulation_support.py`, with `build_scenario` and the atomic
`export`, is ported in `test/Support.hs`. The constants the upstream tests
monkeypatch (`MAX_*`) are fields of `SimulationBounds`, lowered with
`simulateWith`, `admit` or `simulationProfileWith`.

| upstream test | items | status | notes |
| --- | ---: | --- | --- |
| test_owner_fixture_is_exact_strict_and_complete | 1 | ported | byte-for-byte equal to `spec/net-document-v1-simulation.json` |
| test_rest_and_exact_action_limit_have_no_extra_probe | 1 | ported | |
| test_max_actions_is_a_positive_bounded_non_boolean_integer | 7 | ported | `maxActionsFromJson` over `true`, `false`, 0, -1, 257, 1.5 and `"1"`, with the reference's messages |
| test_named_and_anonymous_handlers_are_refused_before_engine_creation | 2 | ported | |
| test_implementation_maps_and_non_json_tokens_are_refused | 1 | ported | |
| test_graph_initial_token_and_payload_bounds | 1 | ported | |
| test_transition_arc_cel_definition_and_result_bounds | 1 | ported | |
| test_retained_history_and_candidate_work_limits_precede_next_advance | 1 | ported | |
| test_legal_graph_cross_transition_scan_sum_is_refused_before_engine_create | 1 | ported | |
| test_completion_reports_completed_without_halting_an_enabled_action | 1 | ported | |
| test_simulation_does_not_change_a_separate_live_engine | 1 | ported | a live Engine with an inline Dispatch, before and after |
| test_admission_is_field_complete_and_precedes_engine_create | 1 | ported | |
| test_malformed_weight_and_multiple_selecting_inputs_are_explicitly_refused | 1 | ported | a boolean weight cannot be represented (`weight :: Int`); a weight of 2 checks the same refusal |
| test_read_selection_and_output_fanout_are_refused_before_engine_create | 1 | adapted | upstream forces a READ selecting arc past Net validation with `object.__setattr__`; the example asserts that `mkNet` refuses that Net (see DIVERGENCES.md), then checks the fan-out refusal as upstream |
| test_consume_plus_many_inhibits_is_rejected_by_reachable_scan_bound | 1 | ported | |
| test_mutating_input_after_simulate_cannot_change_returned_bytes | 1 | adapted | values are immutable; the example checks that the scenario echoes the input exactly |
| test_dispatch_is_structurally_impossible | 1 | ported | `forbiddenDispatch` |
| test_failed_atomic_replace_preserves_the_previous_destination | 1 | ported | `ExportOps.replace` fails; the files go in a temporary directory under `bench-results/tmp` |
| test_failed_temp_publication_preserves_destination_and_cleans_temp | 2 | ported | `ExportOps.write` or `ExportOps.fsync` fails |

## Upstream tests: `tests/petrus/engine/test_simulation_http.py` (`test/HttpSpec.hs`)

There are 24 functions and 71 items. Upstream replaces
`simulation_http.simulate` with `monkeypatch`; here the
`SimulationServerConfig` has a `runner` field for that. Tests that block a
run use `MVar`s where upstream uses `threading.Event`.

| upstream test | items | status | notes |
| --- | ---: | --- | --- |
| test_profile_fixture_and_factory_admission_precede_bind_and_engine | 1 | ported | profile equal to `spec/observation/simulation-service-profile-v1.json`; the runner is never reached |
| test_profile_routes_cors_options_and_origin_are_exact | 1 | ported | |
| test_profile_property_is_detached_and_head_and_extension_methods_have_no_body | 1 | ported | the profile is an immutable value, so the served bytes are compared |
| test_success_is_exact_direct_simulate_bytes | 1 | ported | |
| test_strict_json_schema_types_and_definition_mismatch | 5 | ported | |
| test_nested_non_strict_json_is_400_before_simulation | 3 | ported | |
| test_expected_definition_must_be_exact_object | 3 | ported | |
| test_foreign_place_is_structural_and_unexpected_producer_failure_does_not_leak | 1 | ported | |
| test_raw_framing_refusals | 8 | ported | |
| test_allowed_origin_is_one_exact_absolute_web_origin | 5 | ported | `validateOrigin` and `createSimulationServer` (`OriginRefused`) |
| test_one_slot_refuses_overlap_then_releases_after_success_and_profile_error | 1 | ported | |
| test_slot_is_released_before_response_write | 1 | ported, strengthened | upstream checks the slot from inside `_respond`; here a 16 MiB response goes to a client that never reads, and a second simulation must still get 200 while that write is blocked |
| test_shutdown_and_close_wait_for_active_simulation | 1 | ported | |
| test_partial_body_times_out_without_simulation_or_close_deadlock | 1 | ported | `connectionTimeout = Just 0.1` |
| test_content_length_lexemes_have_exact_errors | 7 | ported | |
| test_duplicate_headers_targets_short_body_and_pipeline_are_closed_exactly | 1 | ported | |
| test_short_body_is_exact_400 | 1 | ported | |
| test_malformed_color_is_400_before_simulation | 2 | ported | |
| test_typed_color_mismatch_and_runner_resource_rejection_are_422 | 1 | ported | |
| test_nested_definition_number_type_mismatch_is_409_before_engine_or_simulate | 2 | ported | `typeExactEq` |
| test_strict_value_failures_are_exact_400_before_simulate | 5 | ported | |
| test_head_and_all_extension_methods_have_exact_405_headers_cors_and_body_rules | 1 | ported | |
| test_allowed_origin_rejects_ambiguous_or_invalid_authorities | 17 | ported | |
| test_profile_copies_cannot_mutate_get_or_post_definition_compare | 1 | adapted | values are immutable; a changed copy differs, while the served profile and the POST comparison are unchanged |

## Spec conformance: `spec/simulation-http-v1.md`

These are points the profile states and the upstream tests leave implicit:

- `/v1/simulation-profile` serves the exact profile fixture, with
  `Content-Type` and `Cache-Control: no-store`;
- a simulation answers with one Net document and no credentials header;
- a simulation admitted after shutdown began gets 503
  `server_shutting_down`;
- a client that disconnects does not cancel admitted work, and the slot is
  freed afterwards;
- every error body is compact, sorted, strict JSON with exactly `code` and
  `message`.

## Wire identity with the reference service (`test/WireSpec.hs`)

The test starts the upstream service, through `test/reference_simulation.py`
in the pinned virtual environment, and this one over the same fixed build
(`build_scenario()`). It sends both the same raw bytes and requires
identical responses. The `Server` and `Date` lines are removed before
comparing.

- **The real runner: 501 requests.** 201 are hand-written and cover:
  - every route and method;
  - Origin and target rules;
  - each framing rule;
  - strict JSON;
  - exact keys;
  - definition mismatches;
  - marking decoding;
  - `max_actions`;
  - HTTP/0.9 and garbage lines.

  The other 300 are generated simulation bodies (seed 11): markings with
  typed, mistyped and untyped tokens of many data shapes, and every kind of
  `max_actions`. The responses must cover every status but 429 and 503,
  which need overlap or shutdown, and at least 50 must be 200.
- **A runner that always fails: 80 requests.** The answer must be a generic
  500, as upstream gives for an unexpected exception.

## Differential corpus for the runner (`test/CorpusSpec.hs`)

`test/corpus_simulation.py` builds 300 random scenarios per seed (seeds 1
and 2) with the upstream Python API. Each scenario has:

- a Net within the profile and sometimes outside it, with consume, read and
  inhibit arcs, CEL guards and filters, timers, completion conditions and
  occasionally heavy markings;
- a marking;
- a `max_actions`.

The script records the Net definition v3 document, the protocol-v1 marking
and what upstream `simulate` did. The Haskell side parses and compiles the
same definition, decodes the marking with the service's `decodeMarking`, and
runs `simulate`. The outcome must match in kind:

- the same result bytes;
- or the same `SimulationProfileError` message;
- or an unexpected failure on both sides.

Each seed must yield at least 100 results and at least 30 refusals.

## Interop in both directions

- **Python clients against this service** (`test/PythonClientSpec.hs`).
  `test/python_clients.py` imports the upstream test module and swaps its
  `serving()` for a stand-in that points at the Haskell server. It then runs
  each upstream test whose assertions hold for any correct server, with
  every parametrization: 15 functions, 42 cases, all passing. This includes
  `test_success_is_exact_direct_simulate_bytes`, which compares Python
  `simulate` bytes with the bytes the Haskell server returns.
- **Haskell clients against the Python service.** `WireSpec` sends the same
  bytes to both services (above). The benchmarks' load driver also checks
  that both answer each benchmark request identically before measuring.

## Performance

[bench/RESULTS.md](bench/RESULTS.md) has three sets of figures:

- `simulate` on seven scenarios;
- service round trips, against `bench/python_bench.py`;
- an interleaved load comparison, with one client driving both services.

Haskell is faster on every row in wall-clock time: from 1.6× (profile GET,
1 client) to 34× (`simulate.loop-24x256`).
