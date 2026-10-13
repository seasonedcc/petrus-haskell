# Observation protocol conformance checklist (upstream `spec/` at the pin)

This list enumerates the testable obligations of upstream's
`observation-protocol-v1.md` (`upstream/petrus/spec/` at the commit
UPSTREAM.md pins), with its fixtures `observation/engine-snapshot-v1.json`
and `observation/engine-history-page-v1.json`, and maps each one to the
Haskell example that checks it. Upstream states that "a normative behavior
without an executable check remains a coverage gap" (`spec/README.md`); this
ledger makes those gaps visible. The format follows
[impetus-conformance.md](impetus-conformance.md).

Each check gives:

- its identifier;
- its level:
  - `projection`: the pure projections over a captured Instance
    (`Petrus.Observation`), driven through the Instance doors the Engine
    performs;
  - `engine`: through a real Engine's read doors
    (`Petrus.Observation.Engine`);
  - `http`: the standard-library HTTP transport profile
    (`Petrus.Observation.Http`);
  - `interop`: compared with the pinned reference (the differential corpus,
    the reference server's bytes, or a live round trip);
  - `types`: the Haskell types rule the violation out;
- the section of the upstream document it verifies;
- the evidence.

Evidence names Hspec examples by their path, written `group › subgroup ›
example`, in the suite of the package named. The groups live in these
modules:

| group | package | module |
| --- | --- | --- |
| `observation (test_observation.py)` | `petrus-observation` | `test/Petrus/Observation/ObservationSpec.hs` |
| `observation through the Engine (test_observation.py)` | `petrus-observation` | `test/Petrus/Observation/EngineSpec.hs` |
| `observation differential corpus` | `petrus-observation` | `test/Petrus/Observation/CorpusSpec.hs` |
| `live round trip through the pinned reference` | `petrus-observation` | `test/Petrus/Observation/LiveSpec.hs` |
| `test_observation_http.py` | `petrus-observation-http` | `test/UpstreamSpec.hs` |
| `spec/observation-protocol-v1.md, HTTP transport profile` | `petrus-observation-http` | `test/UpstreamSpec.hs` |
| `byte-identical to the upstream server` | `petrus-observation-http` | `test/WireSpec.hs` |
| `Python urllib clients against the Haskell server` | `petrus-observation-http` | `test/PythonClientSpec.hs` |

`observation (…)` is short for `observation (test_observation.py)`, and
`through the Engine (…)` for `observation through the Engine
(test_observation.py)`. Where an example of `ObservationSpec` has an
Engine-driven twin in `EngineSpec` (under `Engine-driven projections (twins
of the Instance-door ports)`), both check the obligation; the ledger names
the first. The corpus scenarios and refusals are named after their keys in
`packages/petrus-observation/differential/observation_corpus.json`; each
scenario's snapshot, History page and Net document must equal the
reference's member for member, int and float spelling included.

## A Producer contract

- **O-001** `interop` §Introduction. The fixtures are exact producer output:
  the snapshot and History page the producer emits equal the fixtures
  structurally. *(`observation (…) › produces the exact snapshot fixture with
  a typed FIFO activity-pending state`; `produces the exact complete History
  page fixture`; both byte for byte, and again through the Engine)*
- **O-002** `projection` §Introduction. The producer materializes its current
  definition and complete History prefix as one Net document. *(`observation
  (…) › produces the exact observed Net document fixture, one complete
  marking per record`; `live round trip through the pinned reference ›
  accepts and rewrites byte for byte every observed Net document and History
  page record`)*
- **O-003** `projection` §Introduction. Every response is strict JSON with
  finite numbers. *(`observation (…) › refuses non-finite token data and a
  non-integer current watermark`; corpus refusals `snapshot_nan`,
  `snapshot_inf`, `document_unsafe_integer`)*
- **O-004** `interop` §Introduction. Snapshot and History responses start
  with integer `protocol: 1` and the canonical `instance` identity; the
  document starts with `format: "petrus-net-document"` and integer
  `version: 1`. *(the fixtures of O-001 and O-002, byte for byte; every
  corpus scenario, member order included)*
- **O-005** `types` §Introduction. Mutable values are detached from producer
  state. Haskell values are immutable; the examples check that what was
  captured is carried exactly. *(`observation (…) › keeps nested token and
  Activity values as captured`; `reports pure and projection-pending phases
  with the frozen result`; corpus scenario `detached`)*

## B Snapshot

- **O-006** `engine` §Snapshot. A snapshot contains `definition`,
  `frontier` and `current`; `frontier` is the exclusive History length
  captured atomically with the current state. *(`through the Engine (…) ›
  the Engine's coherence › a snapshot blocks between a writer's append and
  projection, then sees the coherent after state`; `… › a document read
  blocks between a writer's append and projection, then sees the coherent
  after state (beyond upstream)`; `observation (…) › pages a captured
  frontier while History keeps appending`)*
- **O-007** `projection` §Snapshot. The definition has `name`, exactly
  `time_domain: "integer"`, path-sorted `places` and `transitions`,
  authored-order `arcs` and `completion`; each arc carries its zero-based
  authored `position`, so duplicate endpoints stay distinct; resolved arc
  colors are emitted. *(`observation (…) › projects the exact definition
  shape, order, declarations, URIs, and duplicate arcs`; corpus scenario
  `unicode_places`)*
- **O-008** `projection` §Snapshot. Declarations use `kind` as their
  discriminator (`symbol` adds `name`, `cel` adds `expression`, `anonymous`
  adds neither); `null` means absent; handler and guard declarations carry
  their canonical `uri`; anonymous display names and implementations never
  cross the protocol. *(`observation (…) › projects the exact definition
  shape, order, declarations, URIs, and duplicate arcs`; `projects the exact
  inspection fixture from a definition-only net`)*
- **O-009** `projection` §Snapshot. Timers keep authored order and are
  `kind: delay` with an integer `duration` or `kind: until` with an integer
  `instant`. *(`observation (…) › test_protocol_strictly_refuses_non_integer_timer_values
  › refuses a float Delay duration`; `refuses a float Until instant`; corpus
  scenario `timed`; corpus refusals `delay_float`, `until_float`,
  `until_unsafe`. A boolean or string timer value cannot be built: a timer
  holds a `Number`)*
- **O-010** `projection` §Snapshot. `current` holds the sparse, place-sorted
  `marking` with FIFO `{color, data}` tokens, `status`, an integer
  `watermark`, ordered `in_flight`, source- and key-sorted `armed`, and an
  integer-or-null `next_maturation`. *(`observation (…) › produces the exact
  snapshot fixture with a typed FIFO activity-pending state`; `emits an
  integer next maturation and refuses a non-integer one`; `refuses non-finite
  token data and a non-integer current watermark`; corpus scenarios
  `canonical`, `timed`, `sealed`; corpus refusal `snapshot_float_watermark`)*
- **O-011** `projection` §Snapshot. An in-flight occurrence has its
  transition, binding selections, invocation and result, and exactly one
  phase: `pure_pending`, `activity_pending` or `projection_pending`.
  *(`observation (…) › produces the exact snapshot fixture with a typed FIFO
  activity-pending state`; `reports pure and projection-pending phases with
  the frozen result`; `reports a classified failure while its firing
  terminal is pending`; `Haskell seam › phaseOf reads the frozen outcomes
  before the invocation`; corpus scenarios `pure_pending`,
  `projection_pending_result`, `projection_pending_failure`,
  `projected_and_next_begun`)*
- **O-012** `interop` §Snapshot. Protocol-v1 `current` adds no
  `active_scopes` projection; the History transports the complete current
  schema. *(`observation (…) › transports the complete current schema, scope
  fields included`; corpus scenario `scoped`, compared member for member)*
- **O-013** `engine` §Snapshot. Snapshot status is current-only: it may
  evaluate the current pure completion declaration, and stays readable from
  inside a door that refuses a protocol view. *(`through the Engine (…) ›
  the Engine's coherence › same-thread public re-entry is refused, but
  status observation from inside a door remains supported`; `a sensor
  consulted inside advance is refused a protocol view but may read status
  (beyond upstream)`)*
- **O-014** `engine` §Snapshot. A view of an Engine whose joined commit
  failed, or that is closed, is refused rather than showing an uncommitted
  frontier. *(`through the Engine (…) › the Engine's coherence › a joined
  commit failure poisons observation and hides the uncommitted frontier`; `a
  closed Engine refuses every view`)*

## C History pages and cursors

- **O-015** `projection` §History pages and cursors. A page returns dense
  zero-based positions in `[after, next)` with `next = min(after + limit,
  frontier)`; the first request uses zero, a reconnect uses the last
  confirmed `next`, and `after == frontier` is an empty page.
  *(`observation (…) › polls with no gap or duplicate across concurrent
  arrival and reconnect`; `pages a captured frontier while History keeps
  appending`; `produces the exact complete History page fixture`)*
- **O-016** `projection` §History pages and cursors. Negative, boolean,
  non-integer and future cursors, and non-positive, boolean and non-integer
  limits, are refused, never clamped. *(`observation (…) ›
  test_history_page_refuses_malformed_cursor_or_limit` (six examples, and
  `refuses the same values through the typed API`); its Engine twin, with
  the reference's full texts; corpus refusals `history_page_-1_1`,
  `history_page_True_1`, `history_page_0.5_1`, `history_page_0_0`,
  `history_page_0_True`, `history_page_0_1.5`, `history_page_0_-3`,
  `history_page_8_1`)*
- **O-017** `interop` §History pages and cursors. Each nested `record` is
  the unchanged canonical History schema-5 encoding. *(`observation (…) ›
  produces the exact complete History page fixture`; `live round trip
  through the pinned reference › accepts and rewrites byte for byte every
  observed Net document and History page record`)*

## D Standard-library HTTP transport profile

- **O-018** `http` §HTTP profile. `create_observation_server(engine, host,
  port)` binds to one Engine and starts no thread; the application owns
  serving, shutdown and closing. *(`test_observation_http.py ›
  test_factory_binds_without_starting_a_hidden_thread`)*
- **O-019** `http` §HTTP profile. Closing the server never closes its
  Engine. *(`test_observation_http.py ›
  test_transport_shutdown_does_not_close_engine_and_engine_keeps_executing`)*
- **O-020** `http` §HTTP profile. `GET /v1/snapshot`, `GET
  /v1/history?after=&limit=` and `GET /v1/document` return the snapshot, one
  History page and the Engine's Net document. *(`test_observation_http.py ›
  test_snapshot_document_history_and_required_http_headers_are_exact`)*
- **O-021** `projection` §HTTP profile. The document has one `observed`
  Timeline entry per canonical History record, a complete marking on every
  entry, the record in non-authoritative `metadata.history_record`, and the
  final current observation in the head entry's metadata. *(`observation
  (…) › produces the exact observed Net document fixture, one complete
  marking per record`; every corpus scenario's Net document)*
- **O-022** `interop` §HTTP profile. The document route takes no query.
  *(`byte-identical to the upstream server` over a fresh, an advanced and a
  closed Engine: `/v1/document?a=1` among the requests)*
- **O-023** `http` §HTTP profile. Both History query fields are required
  exactly once; unknown, duplicate, empty, signed, whitespace and
  non-ASCII-decimal forms get 400, as does a semantic cursor or limit
  refusal, and `limit > 1000` is refused rather than clamped.
  *(`test_observation_http.py › test_history_query_grammar_is_exact`;
  `test_future_cursor_is_a_protocol_400`; `byte-identical to the upstream
  server`, whose requests include `after=%D9%A3`, `after=0+`, percent
  escapes, duplicates and `limit=1001`)*
- **O-024** `http` §HTTP profile. Unknown routes get 404. Methods other than
  GET and OPTIONS get 405 and never reach the Engine; OPTIONS answers a
  preflight. *(`test_observation_http.py ›
  test_unknown_route_options_and_closed_engine`;
  `test_mutation_methods_are_405_and_never_reach_engine` (`POST`, `PUT`,
  `DELETE`); `byte-identical to the upstream server`, every method of its
  list)*
- **O-025** `http` §HTTP profile. Every response allows origin `*`, methods
  `GET, OPTIONS` and header `Content-Type`, without credentials.
  *(`test_observation_http.py ›
  test_snapshot_document_history_and_required_http_headers_are_exact`;
  `test_unknown_route_options_and_closed_engine`; `byte-identical to the
  upstream server`, every header line)*
- **O-026** `http` §HTTP profile. JSON is deterministic, compact UTF-8, with
  `application/json`, an exact `Content-Length` and `Cache-Control:
  no-store`. *(`test_observation_http.py ›
  test_snapshot_document_history_and_required_http_headers_are_exact`;
  `spec/observation-protocol-v1.md, HTTP transport profile › errors have the
  strict shape and JSON is compact, sorted and exactly sized`)*
- **O-027** `http` §HTTP profile. Errors have exactly the shape
  `{"error":{"code":"...","message":"..."}}`: a query or protocol
  `ValueError` is 400, a closed or poisoned Engine's `RuntimeError` is 503,
  and an unexpected failure is a generic 500 without exception details.
  *(`spec/observation-protocol-v1.md, HTTP transport profile › errors have
  the strict shape and JSON is compact, sorted and exactly sized`;
  `unexpected failures are generic 500 responses without exception details`;
  `test_observation_http.py › test_unknown_route_options_and_closed_engine`
  (503 from a closed Engine); `spec/observation-protocol-v1.md, HTTP
  transport profile › a poisoned Engine is a 503 on every read door, as a
  closed one is`; `byte-identical to the upstream server › over read doors
  that fail (500, 503, 500)`; `Python urllib clients against the Haskell
  server › see 503 from a closed Engine`)*
- **O-028** `http` §HTTP profile. A disconnected requester does not affect
  Engine execution. *(`spec/observation-protocol-v1.md, HTTP transport
  profile › a disconnected requester does not affect Engine execution`)*

## Consumer obligations

These statements bind a consumer of the protocol, not its producer. This
repository ports the producer; the consumer upstream ships (the
petrus-viewer UI) runs unchanged against the Haskell backend
(petrus-viewer-server's `history` suite), so neither implementation here
has a check of its own:

- a scope-aware consumer derives active generations by folding the
  complete History prefix, never from token values or a generation's name
  (§Snapshot);
- historical status and enabledness are not inferred by re-executing
  historical declarations (§Snapshot);
- a cursor inside one append batch is an explanatory record prefix;
  historical consumers fold record projections only and do not label a
  folded prefix as authoritative (§History pages and cursors).

## Gaps

None.
