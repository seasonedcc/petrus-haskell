# Simulation HTTP profile conformance checklist (upstream `spec/` at the pin)

This list enumerates the testable obligations of upstream's
`simulation-http-v1.md` (`upstream/petrus/spec/` at the commit UPSTREAM.md
pins), with its fixture `observation/simulation-service-profile-v1.json`,
and maps each one to the Haskell example that checks it. Upstream states
that "a normative behavior without an executable check remains a coverage
gap" (`spec/README.md`); this ledger makes those gaps visible. The format
follows [impetus-conformance.md](impetus-conformance.md).

Each check gives:

- its identifier;
- its level:
  - `runner`: the simulation runner (`Petrus.Simulation.simulate`) and the
    Net document it writes;
  - `http`: the service (`Petrus.Simulation.Http`);
  - `interop`: compared with the pinned reference (the reference service's
    bytes for the same raw requests, the upstream runner on generated
    scenarios, or the upstream test clients against this service);
  - `types`: the Haskell types rule the violation out;
- the section of the upstream document it verifies;
- the evidence.

Evidence names Hspec examples of the `petrus-simulation` suite by their
path, written `group › subgroup › example`. The groups live in these
modules (`packages/petrus-simulation/test/`):

| group | module |
| --- | --- |
| `test_simulation.py` | `RunnerSpec.hs` |
| `test_simulation_http.py` | `HttpSpec.hs` |
| `spec/simulation-http-v1.md` | `HttpSpec.hs` |
| `byte-identical to the upstream server` | `WireSpec.hs` |
| `differential corpus against the upstream runner` | `CorpusSpec.hs` |
| `upstream Python clients against this server` | `PythonClientSpec.hs` |

`WireSpec`'s example `byte-identical to the upstream server › with the real
simulation (… requests)` sends the reference service and this one the same
raw requests and requires identical responses (`Server` and `Date` aside).
Where the ledger cites it, its requests include the case named.

## A Scope and profile

- **S-001** `http` §Introduction. CORS admits one configured exact HTTP(S)
  origin; an ambiguous or invalid origin is refused when the server is
  created. *(`test_simulation_http.py ›
  test_allowed_origin_is_one_exact_absolute_web_origin`;
  `test_allowed_origin_rejects_ambiguous_or_invalid_authorities`)*
- **S-002** `http` §Profile. `GET /v1/simulation-profile` returns the exact
  fixture: format `petrus-simulation-service-profile`, integer version 1,
  profile `implementation-free-v1`, the canonical definition, and every
  runner and transport bound. *(`spec/simulation-http-v1.md › serves the
  exact profile fixture (format, version, profile, definition, bounds)`;
  `test_simulation_http.py ›
  test_profile_fixture_and_factory_admission_precede_bind_and_engine`)*
- **S-003** `http` §Profile. The definition is captured, and the Net
  admitted, before the socket is bound. *(`test_simulation_http.py ›
  test_profile_fixture_and_factory_admission_precede_bind_and_engine`)*
- **S-004** `interop` §Profile. The exact definition is a race
  precondition: object member order is insignificant, JSON types and array
  order are exact. *(`test_simulation_http.py ›
  test_nested_definition_number_type_mismatch_is_409_before_engine_or_simulate`
  (`1.0` and `true` for an integer); `test_strict_json_schema_types_and_definition_mismatch`;
  `test_profile_copies_cannot_mutate_get_or_post_definition_compare`; `byte-identical
  to the upstream server`: the served definition with its members reversed)*
- **S-005** `types` §Simulation. The application cedes the immutable built
  Net to the server, and returned profile values are detached copies:
  Haskell values are immutable. *(`test_simulation_http.py ›
  test_profile_property_is_detached_and_head_and_extension_methods_have_no_body`;
  `test_profile_copies_cannot_mutate_get_or_post_definition_compare`)*

## B Simulation

- **S-006** `http` §Simulation. `POST /v1/simulations` accepts exactly
  `expected_definition`, `initial_marking` and `max_actions`.
  *(`test_simulation_http.py ›
  test_strict_json_schema_types_and_definition_mismatch`;
  `test_nested_non_strict_json_is_400_before_simulation`;
  `test_expected_definition_must_be_exact_object`)*
- **S-007** `http` §Simulation. The marking has the protocol-v1 sorted place
  and token shape, each token exactly `color` and strict-JSON `data`.
  *(`test_simulation_http.py ›
  test_malformed_color_is_400_before_simulation`;
  `test_strict_value_failures_are_exact_400_before_simulate`; `byte-identical
  to the upstream server`: marking decoding)*
- **S-008** `runner` §Simulation. The response is one Net document carrying
  the profile's exact definition and one `simulated` Timeline entry per
  canonical History record, each with its complete marking and its History
  record in non-authoritative metadata; the first entry's metadata carries
  the profile, scenario and outcome context. *(`test_simulation.py ›
  test_owner_fixture_is_exact_strict_and_complete`;
  `test_simulation_http.py › test_success_is_exact_direct_simulate_bytes`;
  `spec/simulation-http-v1.md › answers a simulation with one Net document and
  no credentials header`; `differential corpus against the upstream runner`,
  both seeds)*
- **S-009** `http` §Simulation. A request needs exactly one valid
  `Content-Length`, an uncompressed `application/json` body (optionally
  `charset=utf-8`) and no query. *(`test_simulation_http.py ›
  test_raw_framing_refusals`; `test_content_length_lexemes_have_exact_errors`;
  `test_duplicate_headers_targets_short_body_and_pipeline_are_closed_exactly`;
  `test_short_body_is_exact_400`; `test_profile_routes_cors_options_and_origin_are_exact`
  (a query is 400); `byte-identical to the upstream server`: every
  `Content-Type` spelling and `Content-Length` lexeme of its list)*
- **S-010** `http` §Simulation. The body is at most 1,048,576 bytes.
  *(`test_simulation_http.py › test_content_length_lexemes_have_exact_errors`
  (`1048577`); `byte-identical to the upstream server`: `1048576` and
  `1048577`)*
- **S-011** `http` §Simulation. Exactly one `Origin` and one `Content-Type`
  are required; `Expect`, transfer encoding and content encoding are
  refused. *(`test_simulation_http.py › test_raw_framing_refusals`;
  `test_duplicate_headers_targets_short_body_and_pipeline_are_closed_exactly`)*
- **S-012** `http` §Simulation. The server speaks HTTP/1.0 and serves
  exactly one parsed request per connection. *(`test_simulation_http.py ›
  test_duplicate_headers_targets_short_body_and_pipeline_are_closed_exactly`
  (a pipelined second request gets no answer); `byte-identical to the
  upstream server`: a pipelined pair and an `HTTP/1.1` request line)*
- **S-013** `http` §Simulation. A connection timeout bounds an incomplete
  body without running a simulation or deadlocking close; it is five
  seconds by default. *(`test_simulation_http.py ›
  test_partial_body_times_out_without_simulation_or_close_deadlock`;
  `spec/simulation-http-v1.md › bounds a response write to a client that
  never reads by the five-second connection timeout`; the default is a
  transport bound of the profile fixture, S-002)*
- **S-014** `http` §Simulation. Only one simulation runs at a time; an
  overlap is refused without a queue, and the slot is released before the
  response is written. *(`test_simulation_http.py ›
  test_one_slot_refuses_overlap_then_releases_after_success_and_profile_error`;
  `test_slot_is_released_before_response_write`)*
- **S-015** `http` §Simulation. A disconnect is not cancellation: admitted
  work finishes, its result is discarded, and nothing retries.
  *(`spec/simulation-http-v1.md › does not cancel admitted work when the
  client disconnects, and frees the slot after`)*
- **S-016** `http` §Simulation. Shutdown and close wait for an active
  simulation; a simulation admitted after shutdown began is refused.
  *(`test_simulation_http.py ›
  test_shutdown_and_close_wait_for_active_simulation`;
  `spec/simulation-http-v1.md › refuses a simulation admitted after shutdown
  began with 503 server_shutting_down`)*

## C Routes and errors

- **S-017** `http` §Routes and errors. The profile route allows `GET,
  OPTIONS` and the simulation route `POST, OPTIONS`; other methods get 405
  with the route's `Allow`, and an unknown route 404.
  *(`test_simulation_http.py ›
  test_profile_routes_cors_options_and_origin_are_exact`;
  `test_head_and_all_extension_methods_have_exact_405_headers_cors_and_body_rules`;
  `byte-identical to the upstream server`: every method on both routes)*
- **S-018** `http` §Routes and errors. Every request needs the configured
  exact `Origin`. *(`test_simulation_http.py ›
  test_profile_routes_cors_options_and_origin_are_exact`;
  `test_duplicate_headers_targets_short_body_and_pipeline_are_closed_exactly`
  (a repeated `Origin`); `byte-identical to the upstream server`: a missing,
  foreign, differently spelled or repeated `Origin`)*
- **S-019** `http` §Routes and errors. Responses set the exact
  `Access-Control-Allow-Origin`, `Vary: Origin`, no credentials, and the
  route's preflight method and header declarations.
  *(`test_simulation_http.py ›
  test_profile_routes_cors_options_and_origin_are_exact`;
  `test_head_and_all_extension_methods_have_exact_405_headers_cors_and_body_rules`;
  `spec/simulation-http-v1.md › answers a simulation with one Net document and
  no credentials header`; `byte-identical to the upstream server`: `OPTIONS`
  on both routes)*
- **S-020** `http` §Routes and errors. The decoder owns wire structure,
  exact types and ordering: a violation is 400 before any simulation.
  *(`test_simulation_http.py ›
  test_strict_value_failures_are_exact_400_before_simulate`;
  `test_nested_non_strict_json_is_400_before_simulation`;
  `test_malformed_color_is_400_before_simulation`)*
- **S-021** `http` §Routes and errors. A foreign place, a typed-place color
  mismatch or a runner resource refusal is a structurally valid scenario:
  422. *(`test_simulation_http.py ›
  test_foreign_place_is_structural_and_unexpected_producer_failure_does_not_leak`;
  `test_typed_color_mismatch_and_runner_resource_rejection_are_422`)*
- **S-022** `http` §Routes and errors. A definition mismatch is checked
  before simulation and is 409. *(`test_simulation_http.py ›
  test_nested_definition_number_type_mismatch_is_409_before_engine_or_simulate`)*
- **S-023** `http` §Routes and errors. An unexpected producer failure is 500
  without details. *(`test_simulation_http.py ›
  test_foreign_place_is_structural_and_unexpected_producer_failure_does_not_leak`;
  `byte-identical to the upstream server › with a failing producer (500
  without details)`)*
- **S-024** `http` §Routes and errors. Errors are compact, sorted, strict
  JSON of exactly `{"error":{"code":"...","message":"..."}}`.
  *(`spec/simulation-http-v1.md › writes every error as compact sorted
  strict JSON with exactly code and message`)*
- **S-025** `interop` §Routes and errors. The error codes and the status
  table: `invalid_request` 400, `length_required` 411, `payload_too_large`
  413, `unsupported_media_type` 415, `simulation_rejected` 422,
  `definition_mismatch` 409, `simulation_busy` 429, `internal_error` 500,
  and `origin_not_allowed`, `not_found`, `method_not_allowed`,
  `server_shutting_down`. *(the examples of S-009 to S-024, each asserting
  its status and code; `byte-identical to the upstream server › with the
  real simulation (… requests)` requires every status but 429 and 503 among
  its answers)*
- **S-026** `interop` §Routes and errors. Malformed HTTP syntax before the
  handler stays the standard-library server's territory. *(`byte-identical
  to the upstream server`: HTTP/0.9, HTTP/2.0 and garbage request lines;
  `upstream Python clients against this server › pass the upstream HTTP
  tests' assertions (42 cases)`)*

## Not obligations

The trusted-network premise (no authentication; CORS is not an
authorization boundary) and the absence of persistence, jobs, status, run
IDs, continuations and a retry protocol describe what the profile leaves
out. The routes of S-017 are the only ones the service answers.

## Gaps

None.
