# petrus-observation: parity with the Python reference

This file maps every upstream test of `petrus.impetus.observation` and of
the Engine's three read doors
(`upstream/petrus/tests/petrus/engine/test_observation.py` and
`test_observation_http.py`) to its Haskell counterparts:

- `test/Petrus/Observation/ObservationSpec.hs` drives the projections with
  the Instance doors the Engine performs (see `Support.hs`), then projects
  with `capture` and the pure projections.
- `test/Petrus/Observation/EngineSpec.hs` drives a real Engine
  (`petrus-engine`) and reads through `Petrus.Observation.Engine`
  (`snapshot`, `historyPage`, `historyPageJson`, `netDocument`), the
  reference's `Engine.snapshot()`, `Engine.history_page()` and
  `Engine.net_document()`. It holds the three Engine tests (lock, re-entry,
  commit poisoning) and an Engine-driven twin of every projection test that
  `ObservationSpec` drives with Instance doors.

Each Hspec example has a `-- test_name` comment naming the upstream test it
ports.

Statuses:

- **ported**: the same scenario with the same assertions.
- **enforced by types**: the case can't be represented in Haskell.
- **deferred**: it needs the observation HTTP adapter, which does not exist
  yet in this repository (see below).

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
| engine/test_observation.py (19 tests) | 15 | 3 | 1 | 0 |
| engine/test_observation_http.py (7 tests) | 7 (in `petrus-observation-http`) | | | 0 |

`cabal test petrus-observation` runs the suite with no failure and no pending example:

- 22 port upstream tests through Instance doors (`ObservationSpec`;
  parametrized cases are separate examples).
- 23 drive a real Engine (`EngineSpec`): the 3 Engine tests, 18 Engine-driven
  twins of the projection tests (the 6 malformed-cursor cases are separate
  examples, now with the reference's full refusal texts), and 2 beyond
  upstream (a sensor inside `advance` is refused a protocol view but may read
  `status`; a closed Engine refuses every view with the reference's text).
- 3 test the Haskell seam.
- 26 come from the differential corpus: 10 scenarios and 16 refusals.
- 1 is a live round trip beyond upstream (`LiveSpec`): every scenario's
  observed Net document and History page records, as Haskell writes them,
  go to the pinned reference's own `parse_net_document` and
  `decode_record`, which must accept them and serialize them back byte for
  byte (selected by `scripts/interop`; without the reference it fails).

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
| test_snapshot_blocks_between_append_and_projection_then_sees_coherent_after_state | ported (Engine) | `EngineSpec`. `PausingHistory` wraps the in-memory store; `threading.Event` becomes an `MVar` and `Event.wait(t)` becomes `timeout`. The writer's `deliver` pauses after its first append; a reader's `snapshot` must not complete within 20 ms, and after resume sees `frontier == length records` and the delivered token. Replacing the door with an unlocked `capture` makes this example fail. |
| test_same_thread_public_reentry_is_refused_but_sensor_status_observation_remains_supported | ported (Engine) | `EngineSpec`. The reference calls the private `Engine._guarded`; the port calls `Petrus.Engine.Internal.guarded`, the same door wrapper. `snapshot` inside it is refused (`cannot re-enter`); `marking`, `status`, `inFlight` and `records` inside it equal the values read outside. A beyond-upstream example does the same from a real sensor inside `advance`. |
| test_joined_commit_failure_poisons_observation_and_hides_uncommitted_frontier | ported (Engine) | `EngineSpec`. The reference swaps `engine._resources` for `_EngineResources(commit=<raises>)` after construction; the port opens the Engine through `Petrus.Engine.Provider.openEngine` with a commit hook that raises `commit refused` once armed. The in-memory History keeps the uncommitted records, and `snapshot` and `history_page` (and, beyond upstream, `net_document`) refuse with `poisoned`. |

The other 12 tests in this file that drive an Engine in the reference are
also driven through a real Engine in `EngineSpec`, with the same assertions
as in `ObservationSpec`. (The remaining 4 call `definition` or
`net_inspection` on a bare Net, with no Engine.) The three
fixtures are checked byte for byte there too. Where the reference reaches
into `engine._instance` (the pure-pending begin and the recorded Activity
result or failure) the port uses `Petrus.Engine.Provider.engineInstance`.
The reference forces a boolean watermark into the Instance; the Engine twin
creates the Engine at the float instant 7.5 instead (same refusal).

## engine/test_observation_http.py: ported in petrus-observation-http

The HTTP adapter is the package `petrus-observation-http` (on
`petrus-http-core`); its [PARITY.md](../petrus-observation-http/PARITY.md)
maps these 7 tests to their Hspec ports. What follows is what the adapter
needed from this package.

All 7 functions test the observation HTTP adapter (routes, headers, query
grammar, 405/404/OPTIONS, and transport shutdown) over a live Engine:

- test_factory_binds_without_starting_a_hidden_thread
- test_snapshot_document_history_and_required_http_headers_are_exact
- test_history_query_grammar_is_exact (parametrized over the query string)
- test_future_cursor_is_a_protocol_400
- test_mutation_methods_are_405_and_never_reach_engine (POST, PUT, DELETE)
- test_unknown_route_options_and_closed_engine
- test_transport_shutdown_does_not_close_engine_and_engine_keeps_executing

They need an HTTP core: `create_observation_server(engine, host, port)` binding a
threaded server to one Engine without starting a thread or owning the
Engine's lifecycle (the caller runs `serve_forever` and `shutdown`); the
routes `GET /v1/snapshot`, `/v1/document` (both refuse any query) and
`/v1/history?after=&limit=` with the exact query grammar (strict
`parse_qsl`, each parameter exactly once, no others, non-empty unsigned
decimals, `limit` at most `MAX_HISTORY_PAGE_LIMIT` = 1000) and its error
texts; the body spelling (compact, key-sorted, ASCII-escaped JSON); the
headers (`Content-Type`, `Content-Length`, `Cache-Control: no-store`, CORS,
`Allow`); `OPTIONS` → 204; `POST`/`PUT`/`PATCH`/`DELETE`/`HEAD` → 405 without
reaching the Engine; unknown routes → 404; and the error mapping
(`ValueError` → 400 `invalid_request`, `RuntimeError` → 503
`engine_unavailable`, anything else → 500 `internal_error`).

Everything those routes read is ported: `Petrus.Observation.Engine` gives
the three doors; a projection refusal is an `ObservationError` (the
reference's `ValueError`), and an Engine refusal (closed, poisoned,
re-entry) is an `EngineRuntimeError` (its `RuntimeError`), so the error
mapping is a match on the exception type. `historyPageJson` runs the
reference's cursor checks inside the read door, after the Engine's own
checks, as `Engine.history_page` does.

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
