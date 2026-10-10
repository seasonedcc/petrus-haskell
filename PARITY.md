# Parity

Status of every in-scope upstream component against the pins in
[UPSTREAM.md](UPSTREAM.md).

A component is **at parity** only when all of these hold at the current pin:

1. **Tests** — every behavior its upstream tests check is checked by a Haskell
   test (or recorded as enforced by the Haskell types).
2. **Conformance** — everything `upstream/petrus/spec/` (and this repo's
   `spec/`) specifies for it holds.
3. **Interop** — where it has a wire format or protocol, Haskell and Python
   exchange it in both directions with no loss.
4. **Performance** — its committed benchmarks show it at least as fast as the
   pinned Python on equivalent workloads.

Statuses: `not started`, `in progress`, `at parity`. Evidence links point at
the tests, conformance suites, and benchmark results that justify the status.

## petrus

| Component | Upstream | Haskell package | Status | Evidence |
| --- | --- | --- | --- | --- |
| JSON fidelity (foundation) | CPython `json` as used by every format | `petrus-json` | in progress | `packages/petrus-json/test` |
| Petri net kernel | `impetus/petrinet`, `impetus/scope` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md) |
| Event history + schema-5 codec | `impetus/history` | `petrus-impetus` | at parity | decode 2.5× faster than Python, canonical-spelling refusals checked against the pre-optimization codec; [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md) |
| Bindings, handlers, selection | `impetus/binding`, `impetus/selection` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), CEL via `Petrus.Cel.Impetus.celCompilers` |
| CEL | `impetus/binding/cel.py` (cel-python 0.5.0) | `petrus-cel` | at parity | [corpus: 1978 expressions, 17850 operator cases](packages/petrus-cel/test/corpus), [test_cel.py port + Instance end-to-end](packages/petrus-cel/test), [bench](packages/petrus-cel/bench/RESULTS.md) |
| Instance | `impetus/instance` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md); `FiringFailed.error` matches 452 reference texts ([failure_text_corpus](packages/petrus-impetus/differential/failure_text_corpus.json), `FailureTextSpec`); only a non-`PythonException`'s class name is its Haskell type name ([DIVERGENCES 11](packages/petrus-impetus/DIVERGENCES.md)) |
| Net definition v3 | `impetus/net_definition.py` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md); differential corpora: [1763 parse/serialize cases](packages/petrus-impetus/differential/net_definition_corpus.json) and [1996 hand-built cases](packages/petrus-impetus/differential/hand_built_corpus.json) (validating constructors, `model_construct` compile/serialize/project, depth limits); [printability vector](packages/petrus-json/test/python-printable.txt) for every code point; [bench](packages/petrus-impetus/bench/RESULTS.md) (serialize 4.2×, parse 2.2×) |
| Net document v1 | `impetus/net_document.py` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md) |
| Golden traces | `spec/traces` | `petrus-impetus` | at parity | [GoldenTracesSpec](packages/petrus-impetus/test), `cabal run petrus-golden-traces` |
| History stores: memory | `impetus/history_store/memory.py` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md) |
| History stores: JSONL | `impetus/history_store/jsonl.py` | `petrus-history-store` | at parity | [PARITY](packages/petrus-history-store/PARITY.md), [DIVERGENCES](packages/petrus-history-store/DIVERGENCES.md), byte-identical interop both ways (`test/Petrus/HistoryStore/InteropSpec.hs`), [bench](packages/petrus-history-store/bench/RESULTS.md) |
| History stores: SQLite, and the SQLite writer fence | `impetus/history_store/sqlite.py` | `petrus-history-store` (`Petrus.HistoryStore.Sqlite`; fence in `petrus-sqlite`) | at parity | all 11 `test_sqlite_history.py` tests (14 cases) and the 13 backend-contract tests with `reopen` = sqlite ported ([PARITY](packages/petrus-history-store/PARITY.md)), [DIVERGENCES](packages/petrus-history-store/DIVERGENCES.md); interop both ways with the same DDL text, rows and payload bytes, verify-on-conflict answers, 36 identical refusal texts, a mixed-language first-initialization race, and crash/resume ([SqliteInteropSpec](packages/petrus-history-store/test/Petrus/HistoryStore/SqliteInteropSpec.hs)); [bench](packages/petrus-history-store/bench/RESULTS.md) (1.04× to 135× faster on every row) |
| History stores: Postgres | `impetus/history_store/postgres.py` | `petrus-history-postgres` | at parity | all 21 `test_postgres_history.py` tests, the 14 backend-contract tests with `reopen` = postgres and the 2 package-boundary rows ported ([PARITY](packages/petrus-history-postgres/PARITY.md), [DIVERGENCES](packages/petrus-history-postgres/DIVERGENCES.md)); interop with the reference on one database ([InteropSpec](packages/petrus-history-postgres/test/Petrus/HistoryStore/Postgres/InteropSpec.hs)): same DDL bytes and catalog, same payload bytes and rows, cross-language verify-on-conflict (stale and racing writers), joined batches and `impetus_dispatch` NOTIFY commit-or-vanish both ways; [bench](packages/petrus-history-postgres/bench/RESULTS.md): 1.7–3.8× faster |
| Observation | `impetus/observation.py`, `engine/observation_http.py` | `petrus-observation`, `petrus-observation-http` | at parity | `observation.py` and the Engine's read doors (`Petrus.Observation.Engine`): all 19 `test_observation.py` tests accounted for, the Engine lock, re-entry and commit-poisoning tests ported against a real Engine, fixtures byte for byte through Instance doors and through the Engine ([tests](packages/petrus-observation/PARITY.md), [EngineSpec](packages/petrus-observation/test/Petrus/Observation/EngineSpec.hs), [differential](packages/petrus-observation/differential), [bench](packages/petrus-observation/bench/RESULTS.md), [divergences](packages/petrus-observation/DIVERGENCES.md)). HTTP adapter (`Petrus.Observation.Http`): all 7 `test_observation_http.py` tests (19 items) ported, plus the protocol's HTTP-profile checks; byte-identical to the upstream server on 501 raw requests over fresh, advanced and closed Engines and on failing read doors ([WireSpec](packages/petrus-observation-http/test/WireSpec.hs)); upstream urllib clients against the Haskell server ([PythonClientSpec](packages/petrus-observation-http/test/PythonClientSpec.hs)); the viewer backend `petrus --observation <url>` answers identically against both servers ([ViewerSpec](packages/petrus-observation-http/test/ViewerSpec.hs)); [tests](packages/petrus-observation-http/PARITY.md), [bench](packages/petrus-observation-http/bench/RESULTS.md) (1.6–3.7× faster), [divergences](packages/petrus-observation-http/DIVERGENCES.md) |
| Net DSL | `impetus/dsl.py` | `petrus-dsl` | at parity | 68-net differential corpus (v3 bytes, order, URIs, refusals); [tests](packages/petrus-dsl/PARITY.md), [differential](packages/petrus-dsl/differential), [bench](packages/petrus-dsl/bench/RESULTS.md), [divergences](packages/petrus-dsl/DIVERGENCES.md) |
| Activities | `motus/activity` | | in progress | value types in `petrus-activity` |
| Dispatch port, InlineDispatch, InMemoryDispatch | `motus/dispatch/{__init__,inline,memory}.py` | `petrus-motus` | at parity | [PARITY](packages/petrus-motus/PARITY.md), [DIVERGENCES](packages/petrus-motus/DIVERGENCES.md); exercised end to end by the [Engine bench](packages/petrus-engine/bench/RESULTS.md) |
| Dispatch: local (SQLite) | `motus/dispatch/local.py` | `petrus-motus` (`Petrus.Motus.Dispatch.Local`) | at parity | all 36 upstream tests ported ([PARITY](packages/petrus-motus/PARITY.md); Engine-level tests in [LocalDispatchSpec](packages/petrus-engine/test/Petrus/Engine/LocalDispatchSpec.hs)), [DIVERGENCES](packages/petrus-motus/DIVERGENCES.md), shared-file interop both ways with identical rows and telemetry ([LocalInteropSpec](packages/petrus-motus/test/Petrus/Motus/Dispatch/LocalInteropSpec.hs)), [bench](packages/petrus-motus/bench/RESULTS.md) (1.3–1.9× faster at equal IO) |
| Dispatch: Absurd | `motus/dispatch` | | not started | |
| Execution, Gondolin | `motus/execution`, `motus/_execution` | `petrus-execution` | in progress (all upstream tests ported; real-Gondolin acceptance run pending) | [PARITY](packages/petrus-execution/PARITY.md), [divergences](packages/petrus-execution/DIVERGENCES.md), [bench](packages/petrus-execution/bench/RESULTS.md) |
| Workers | `motus/worker` | | not started | |
| Transport: ZeroMQ | `motus/transport` | | not started | |
| Engine (provider-neutral) and coordination | `engine/__init__.py`, `engine/_coordination.py` | `petrus-engine` | at parity | [PARITY](packages/petrus-engine/PARITY.md), [DIVERGENCES](packages/petrus-engine/DIVERGENCES.md), JSONL interop with crash/resume both ways (`test/Petrus/Engine/InteropSpec.hs`), [bench](packages/petrus-engine/bench/RESULTS.md) |
| Engine: SQLite | `engine/sqlite.py` | `petrus-engine-sqlite` (`Petrus.Engine.Sqlite`) | at parity | all 5 `test_sqlite_engine.py` tests ported, including spawned-process contention and fork ([PARITY](packages/petrus-engine-sqlite/PARITY.md)), [DIVERGENCES](packages/petrus-engine-sqlite/DIVERGENCES.md); interop with identical History rows, crash/resume both ways and fence contention against reference processes ([SqliteInteropSpec](packages/petrus-engine-sqlite/test/Petrus/Engine/SqliteInteropSpec.hs)); [bench](packages/petrus-engine-sqlite/bench/RESULTS.md) (1.2× to 6.8× faster) |
| Engine: Postgres | `engine/postgres.py`, `engine/_postgres.py` | `petrus-engine-postgres` (fence in `petrus-postgres`) | at parity | all 13 `test_postgres_engine.py` cases and the provider package-boundary row ported ([PARITY](packages/petrus-engine-postgres/PARITY.md), [DIVERGENCES](packages/petrus-engine-postgres/DIVERGENCES.md)); interop with the reference's own Engines ([InteropSpec](packages/petrus-engine-postgres/test/Petrus/Engine/Postgres/InteropSpec.hs)): turn-taking create/load both ways, fence exclusion both ways (including a killed holder), failure fates decided across languages, LISTEN/NOTIFY doorbells through the joined seam; [bench](packages/petrus-engine-postgres/bench/RESULTS.md): 3.8–13.6× faster |
| Engine: Absurd | `engine/absurd.py` | `petrus-engine` provider seam (`Petrus.Engine.Provider`); Absurd reuses `Petrus.Engine.Postgres.Joined` | not started | |
| Simulation + HTTP | `simulation.py`, `simulation_http.py` | `petrus-simulation` | at parity | all 19 + 24 upstream test functions (27 + 71 items) ported, plus 5 `spec/simulation-http-v1.md` checks ([tests](packages/petrus-simulation/PARITY.md)); owner and service-profile fixtures byte for byte; 600 random scenarios replayed against upstream `simulate` with identical bytes or refusal messages ([CorpusSpec](packages/petrus-simulation/test/CorpusSpec.hs)); byte-identical to the upstream service on 581 raw requests ([WireSpec](packages/petrus-simulation/test/WireSpec.hs)); 15 upstream urllib/socket tests (42 cases) pass against the Haskell service ([PythonClientSpec](packages/petrus-simulation/test/PythonClientSpec.hs)); [bench](packages/petrus-simulation/bench/RESULTS.md) (runner 4.3–48×, service 1.6–9.3× faster), [divergences](packages/petrus-simulation/DIVERGENCES.md) |
| Telemetry | `telemetry.py`; the `impetus_*` events of `impetus/instance`, `engine/_coordination.py`, `impetus/history_store/jsonl.py` | `petrus-telemetry`, `petrus-telemetry-instrumentation` | at parity | all 29 + 22 upstream tests ported ([PARITY](packages/petrus-telemetry/PARITY.md), [DIVERGENCES](packages/petrus-telemetry/DIVERGENCES.md)); [differential](packages/petrus-telemetry-instrumentation/differential): 23 scenarios, 282 events exact and routed lines byte-identical; [bench](packages/petrus-telemetry-instrumentation/bench/RESULTS.md): routed emit 3× cheaper than Python. Events of unported components (workers, local/Absurd dispatch, Postgres stores, fabric) belong to those components' rows |
| Deterministic simulation testing | `testing/dst.py`, `tests/dst/*_world.py` | `petrus-dst` | in progress | everything except the joined Postgres worlds is at parity. That covers the interpreter, artifacts v1 to v4, replay, the process runner (including the real public-Engine resource world in a child), and all 18 non-joined Engine worlds on the real Haskell Engine and the SQLite LocalDispatch. Every one of those fixtures replays through real profiles to the reference's result bytes, all 18 reference builders are authored byte for byte, and 26 checker verdicts match in full ([PARITY](packages/petrus-dst/PARITY.md), [EngineWorlds](packages/petrus-dst/test/Spec/EngineWorlds.hs), [EngineCheckers](packages/petrus-dst/test/Spec/EngineCheckers.hs), [divergences](packages/petrus-dst/DIVERGENCES.md)). Bench: Engine-world replay 2.0× and authoring 2.1× faster than Python over 18 fixtures and 18 stories ([RESULTS](packages/petrus-dst/bench/RESULTS.md)). Remaining: the 33 `joined-*` fixtures, which need the Absurd joined Engine and Dispatch. The Postgres History store and the joined seam Absurd composes on are now in `petrus-history-postgres` and `petrus-engine-postgres`. Their replay half is checked through recorded transcripts |
| Agenticus | `agenticus/` | | not started | |
| Fabric | `fabric/` | | in progress (spec written) | [spec/fabric.md](spec/fabric.md), [108 checks](spec/fabric-conformance.md) |
| Processes (call/spawn) | `processes/` | | in progress (spec written) | [spec/processes.md](spec/processes.md), [80 checks](spec/processes-conformance.md) |

### Shared platform layers

These kernel-free layers sit under the components above. Each one mirrors the
Python facility upstream uses and is checked differentially against it. Each
reaches parity together with the components that use it.

| Component | Upstream | Haskell package | Status | Evidence |
| --- | --- | --- | --- | --- |
| POSIX: `flock`, `openat`, `Path.resolve`, atomic replace, rusage | `fcntl`, `os`, `pathlib`, `resource` as used by the stores and workers | `petrus-posix` | in progress | `packages/petrus-posix/test`, [benchmarks](packages/petrus-posix/bench/RESULTS.md), [divergences](packages/petrus-posix/DIVERGENCES.md) |
| SQLite connections, `BEGIN IMMEDIATE`, writer fence | `sqlite3` as used by the SQLite store and Engine | `petrus-sqlite` | in progress | `packages/petrus-sqlite/test`, [benchmarks](packages/petrus-sqlite/bench/RESULTS.md), [divergences](packages/petrus-sqlite/DIVERGENCES.md) |
| PostgreSQL connections, transactions, LISTEN/NOTIFY, authority fence | psycopg 3 as used by the Postgres store, Engine and Absurd dispatch | `petrus-postgres` | in progress | `packages/petrus-postgres/test`, [benchmarks](packages/petrus-postgres/bench/RESULTS.md), [divergences](packages/petrus-postgres/DIVERGENCES.md) |
| HTTP/1.0 server core | `http.server` (`ThreadingHTTPServer`, `BaseHTTPRequestHandler`), `urllib.parse.urlsplit`/`parse_qsl` and `ipaddress` under the observation and simulation services | `petrus-http-core` | at parity | `packages/petrus-http-core/test` (raw-request and generated-line comparisons with CPython, [UrlSpec](packages/petrus-http-core/test/UrlSpec.hs)); both services byte-identical to upstream through it ([observation WireSpec](packages/petrus-observation-http/test/WireSpec.hs), [simulation WireSpec](packages/petrus-simulation/test/WireSpec.hs)); [benchmarks](packages/petrus-http-core/bench/RESULTS.md), [divergences](packages/petrus-http-core/DIVERGENCES.md) |

## hamsterdan

The port plan is [docs/hamsterdan.md](docs/hamsterdan.md). The target is the V5
runtime in `src/hamsterdan`; `src/hamsterdan2` (non-selectable CV21 rebuild) is
deferred.

Petrus pin reconciliation: Hamsterdan pins Petrus `89baf78` (production runs
`913acb0`); this repo pins `3f85fc2`. Upstream rewrote Petrus history on
2026-09-12, so the old commits must be fetched by SHA. Across all three, `src/`
differs only in ImportError text (`petrus[x]` became `petrus-runtime[x]`) in
modules Hamsterdan does not import, plus a telemetry docstring. **No behavior
Hamsterdan depends on differs** (docs/hamsterdan.md §2.3).

| Component | Upstream | Haskell package | Status | Evidence |
| --- | --- | --- | --- | --- |
| Contracts (V5 workflow models, agent protocol types) | `src/hamsterdan/contracts`, `src/hamsterdan/agents/protocol.py` (types) | `hamsterdan-contracts` | at parity | [PARITY](packages/hamsterdan-contracts/PARITY.md), `packages/hamsterdan-contracts/test/corpus/{contracts,projection,protocol}.jsonl`, [bench](packages/hamsterdan-contracts/bench/RESULTS.md) |
| Python-literal repr/parse for dashboard entries and digests | `readiness/net_v5/dashboard.py`, `board.py` (`repr`, `ast.literal_eval`) | `hamsterdan-contracts` | at parity | [PARITY](packages/hamsterdan-contracts/PARITY.md), `packages/hamsterdan-contracts/test/corpus/{repr,literal_eval}.jsonl`, [bench](packages/hamsterdan-contracts/bench/RESULTS.md) |
| Readiness net V5 (topology, nine loops, startup, folding) | `src/hamsterdan/readiness/net_v5`, `readiness/payloads.py` | `hamsterdan-readiness` | not started | |
| Gate handlers and `$variant` converter | `readiness/net_v5/gating.py` | `hamsterdan-readiness` | not started | |
| Summary board rendering | `readiness/net_v5/board.py` | `hamsterdan-readiness` | not started | |
| GitHub App config and installations TOML | `github_app/config.py` | `hamsterdan-github` | at parity | [PARITY](packages/hamsterdan-github/PARITY.md), `packages/hamsterdan-github/test/corpus/config.jsonl`, [bench](packages/hamsterdan-github/bench/RESULTS.md) |
| Webhook verification and durable inbox | `github_app/webhooks.py` | `hamsterdan-github` | at parity | [PARITY](packages/hamsterdan-github/PARITY.md), `packages/hamsterdan-github/test/corpus/webhooks.jsonl`, [bench](packages/hamsterdan-github/bench/RESULTS.md) |
| Webhook HTTP endpoint (`POST /github/webhooks`, `GET /healthz`) | `host/api.py` | `hamsterdan-host` | not started | |
| Installation and repository routing | `github_app/routing.py` | `hamsterdan-github` | at parity | [PARITY](packages/hamsterdan-github/PARITY.md), `packages/hamsterdan-github/test/corpus/webhooks.jsonl`, [bench](packages/hamsterdan-github/bench/RESULTS.md) |
| App auth (JWT, installation tokens, startup permission check) and bounded transport, with the githubkit/httpx/hishel client stack | `github_app/auth.py`, `github_app/transport.py` | `hamsterdan-github` | at parity | [PARITY](packages/hamsterdan-github/PARITY.md), `packages/hamsterdan-github/test/corpus/http.jsonl`, [bench](packages/hamsterdan-github/bench/RESULTS.md) |
| Provider reads (REST and GraphQL), Git object writes, GraphQL ref compare-and-swap | `github_app/gateway.py`, `github_app/transport.py` (`GitHubGraphQL`) | `hamsterdan-github` | at parity | [PARITY](packages/hamsterdan-github/PARITY.md), `packages/hamsterdan-github/test/corpus/effects.jsonl`, [bench](packages/hamsterdan-github/bench/RESULTS.md) |
| Effects (comments, reviews, thread resolution, rerun marker) | `github_app/effects.py` | `hamsterdan-github` | at parity | [PARITY](packages/hamsterdan-github/PARITY.md), `packages/hamsterdan-github/test/corpus/effects.jsonl`, [bench](packages/hamsterdan-github/bench/RESULTS.md) |
| Host service (custody, pump, sweep, runnable index, bindings) | `host/service.py`, `host/runnable.py`, `host/binding.py` | `hamsterdan-host` | not started | |
| Host CLI (`serve`, `validate`, `inbox`, `requeue`, `inspect-instance`) | `host/__main__.py` | `hamsterdan-host` | not started | |
| V5 runtime (Engine wiring, ingress manifests, authority grants, claims) | `host/v5/{runtime,application,ingress,claim}.py` | `hamsterdan-host` | not started | |
| V5 gates (publication, rerun, review, mutation) | `host/v5/{gates,rerun,review,mutation}.py` | `hamsterdan-host` | not started | |
| V5 timers | `host/v5/timers.py` | `hamsterdan-host` | not started | |
| Host Git publication (Git objects, ref CAS, reconcile) | `host/git_publish.py` | `hamsterdan-host` | not started | |
| Agents (Pi runner, prompts, result validation) | `src/hamsterdan/agents` | `hamsterdan-agents` | not started | |
| Agent routes, Pi A2 composition, workspaces | `host/agenticus.py`, `host/pi_a2.py`, `host/pi_workspace.py` | `hamsterdan-agents` | not started | |
| Evidence export | `host/export.py` | `hamsterdan-export` | not started | |
| Readiness model oracle | `src/hamsterdan/testing/readiness.py` | `hamsterdan-testing` | not started | |
| Deterministic World and campaigns | `src/hamsterdan/host/testing` | `hamsterdan-testing` | not started | |
| Deterministic journeys (11 scenarios, byte-exact against Python) | `tests/integration/host/test_readiness_scenarios.py` | `hamsterdan-testing` | not started | |
| Operator CLI | `src/hamsterdan/operator.py`, `host/publication_qualification.py` | `hamsterdan-operator` | not started | |
| Container runtime contract | `deployment/Containerfile`, `deployment/config`, `scripts/with-runtime-secrets` | | not started | |
| Replacement outer system (deferred until upstream CV22 cutover) | `src/hamsterdan2` | | not started | |
| End-to-end against a real GitHub App | — (docs/hamsterdan.md §5) | | not started | |

## petrus-viewer

| Component | Upstream | Haskell package | Status | Evidence |
| --- | --- | --- | --- | --- |
| `petrus` CLI | `bin/petrus.mjs` | `petrus-viewer-server` | at parity | `packages/petrus-viewer-server/test/CliSpec.hs`; upstream `cli` 5/5 and `playwright` 4/4 against `petrus` (`packages/petrus-viewer-server/upstream-tests/run.mjs`). Serves the built UI instead of running Vite (`packages/petrus-viewer-server/DIVERGENCES.md`) |
| MCP server | `server/mcp.mjs` | `petrus-viewer-server` | at parity | `packages/petrus-viewer-server/test/McpSpec.hs` (upstream transcript byte for byte); upstream `mcp` 7/7, `mcp-haskell-relay` 7/7, `live` 12/12 (every tool through `petrus-mcp`, `petrus`, and a headless browser) |
| Agent WebSocket protocol | `src/agent/protocol.ts`, bridge | `petrus-viewer-server` | in progress | Tests and interop: `packages/petrus-viewer-server/test/RelaySpec.hs`, `ProtocolSpec.hs`; upstream `relay` 5/5, `differential` 4/4, `live` 12/12. Performance: at or above the Vite relay that `bin/petrus.mjs` runs; the 16-pair round trip is 0.81–0.98x of a bare-`ws` Node relay on a shared machine (`packages/petrus-viewer-server/bench/RESULTS.md`) |
| Collaboration relay | `server/collab.mjs` | `petrus-viewer-server` | at parity | `packages/petrus-viewer-server/test/CollabSpec.hs`; upstream `collab` 6/6; fan-out 3.2–4.5x Node (`packages/petrus-viewer-server/bench/RESULTS.md`) |
| File and URL endpoints | `server/openFileEndpoint.mjs`, `server/urlCache.mjs` | `petrus-viewer-server` | in progress | Tests and interop: `packages/petrus-viewer-server/test/EndpointsSpec.hs`, `UrlSpec.hs`; upstream `endpoints` 14/14, `url-cache` 9/9, `differential` 4/4. Performance: open-file 1.05–1.27x Node; resolve-ref at parity within the noise of a shared machine (0.69–1.10x across runs, `packages/petrus-viewer-server/bench/RESULTS.md`) |
| Simulation and history replay | `src/` | `petrus-viewer-server` | in progress | Simulation stays in the TypeScript UI (upstream `playwright` 4/4 against `petrus`). Replay and live watching of Petrus engines through `/temporal` from `observation-protocol-v1` producers: `packages/petrus-viewer-server/test/ObservationSpec.hs` and the upstream `live` replay case; real producers need the engine packages (`packages/petrus-viewer-server/README.md`) |

## petrus-engine

| Component | Upstream | Haskell package | Status | Evidence |
| --- | --- | --- | --- | --- |
| `fileVersion: "2"` net loading | `src/petrus/schema.py`, `loader.py`, `json_formatter.py`, `cli/format_json.py`, `net_file_schema.json` | `petrus-engine-file` | at parity | [tests](packages/petrus-engine-file/PARITY.md); [differential corpus: 911 cases, 4618 operations](packages/petrus-engine-file/differential/corpus.json) (every upstream loader/resolution/formatter fixture, 157 viewer re-saves, edge and fuzz cases): same bytes written, same refusal class and text; live fuzzing against the pinned engine; `petrus-format-json` against `python -m petrus.cli.format_json` (40 scenarios); loaded nets convert to kernel `Net`s; [bench](packages/petrus-engine-file/bench/RESULTS.md) (parse 1.6–2×, write 3–5×, load 1.4–2.3×); lone surrogates in `json.loads` input are refused ([DIVERGENCES](packages/petrus-engine-file/DIVERGENCES.md)) |
