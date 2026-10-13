# petrus-observation-http: parity with the Python reference

`Petrus.Observation.Http` ports `petrus.engine.observation_http` (the
observation protocol 1 HTTP binding) at the pin in
[UPSTREAM.md](../../UPSTREAM.md). Its claim is byte identity: for any request
and Engine state, the response is the reference's, except for the `Server`
and `Date` header values (see [DIVERGENCES.md](DIVERGENCES.md)).

`cabal test petrus-observation-http` runs the suite with no failure and no pending example, in
four groups (the viewer end-to-end test is in petrus-viewer-server).

## Upstream tests: `tests/petrus/engine/test_observation_http.py`

All 7 functions are ported in `test/UpstreamSpec.hs`, each example named
after its upstream test, over the same Engine (`Support.makeEngine` is
`make_engine()`). Parametrized tests are one example per parameter, so the 7
functions are the 19 cases pytest collects.

| upstream test | items | status | notes |
| --- | ---: | --- | --- |
| test_factory_binds_without_starting_a_hidden_thread | 1 | ported | thread count from `GHC.Conc.listThreads` before and after `createObservationServer`, then serves only when the caller forks `serveForever` |
| test_snapshot_document_history_and_required_http_headers_are_exact | 1 | ported | the three bodies equal the Engine's own read doors, encoded compact, sorted and ASCII-escaped; exact headers |
| test_history_query_grammar_is_exact | 11 | ported | every upstream query string, same status and message |
| test_future_cursor_is_a_protocol_400 | 1 | ported | |
| test_mutation_methods_are_405_and_never_reach_engine | 3 | ported | POST, PUT, DELETE; the History is unchanged afterwards |
| test_unknown_route_options_and_closed_engine | 1 | ported | 404, OPTIONS 204, 503 after `Engine.close` |
| test_transport_shutdown_does_not_close_engine_and_engine_keeps_executing | 1 | ported | `shutdown` and `serverClose`, then `Engine.advance` still works |

## Spec conformance: `spec/observation-protocol-v1.md` (HTTP transport profile)

[spec/observation-conformance.md](../../spec/observation-conformance.md)
maps every obligation of the protocol, the HTTP profile included, to the
example that checks it, and lists the gaps.

`UpstreamSpec.profileSpec` checks what the profile states and the upstream
tests leave implicit:

- a requester that disconnects mid-response does not affect Engine
  execution;
- a poisoned Engine (a commit that failed) is a 503 `engine_unavailable`
  on every read door, as a closed one is;
- an unexpected failure in a read door is a generic 500 without exception
  details;
- every error has exactly the `{"error":{"code","message"}}` shape, and every
  body is compact, key-sorted JSON whose `Content-Length` is exact.

## Wire identity with the reference server

`test/WireSpec.hs` starts the upstream server (`test/reference_observation.py`
in the pinned virtual environment) and this one over Engines built the same
way. It sends both the same raw bytes and requires identical responses (the
`Server` and `Date` lines are removed first). The corpus has 101 hand-written
requests and 400 generated `/v1/history` queries, run on a fresh Engine, an
advanced one and a closed one. That is 501 requests per state, covering:

- every route and method, including methods outside the 405 list, which get
  the 501 page;
- HTTP/0.9, HTTP/1.1 and HTTP/2.0 request lines, and garbage;
- absolute-form targets, with IPv6 brackets, bad ports, user info and
  non-ASCII hosts, all through `urlsplit`'s own refusals;
- every query-grammar case: duplicates, blanks, `+`, percent escapes,
  invalid UTF-8, fragments and `;`;
- integers at and past CPython's 4,300-digit limit;
- `//` paths.

A fourth run uses read doors that fail the way the reference's can fail:
`KeyError` gives 500, `RecursionError` gives 503 and `TypeError` gives 500.

## Interop in both directions

- **Python clients against this server** (`test/PythonClientSpec.hs`).
  urllib clients import `make_engine` and `request` from the upstream test
  module. They assert the upstream test's status, header and body
  expectations against the Haskell server, then compare each body with what
  an upstream Engine in the same state returns. A closed Engine gives 503.
- **Haskell clients against the Python server.** `WireSpec`'s client sends
  the same bytes to both servers (above).
- **The viewer backend** (petrus-viewer-server's
  [`test/HistorySpec.hs`](../petrus-viewer-server/test/HistorySpec.hs)).
  It runs the viewer's `/temporal` routes once against this server and
  once against the upstream one, in the same scenario, stepping a chain
  Net to completion. The two runs must give the same answers at every
  step to the viewer's `list`, `get_state` and `get_schema`, and to a
  missing instance. The test lives in the viewer's package so the
  dependency between the two packages goes one way.

## Performance

[bench/RESULTS.md](bench/RESULTS.md) has two parts:

- tasty-bench rows against the `scripts/bench_timing.py` rows of
  `bench/python_bench.py`;
- an interleaved load comparison, in which one client drives both servers
  with identical requests.

Haskell is faster on every row in wall-clock time, by the thinnest margin
on `/v1/history` with 1 client.
