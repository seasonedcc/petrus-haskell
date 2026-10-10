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
| History stores: SQLite, Postgres | `impetus/history_store/{sqlite,postgres}.py` | `petrus-history-store` (SQLite place reserved) | not started | |
| Observation | `impetus/observation.py`, `engine/observation_http.py` | `petrus-observation` | in progress | `observation.py` and the Engine's read doors (`Petrus.Observation.Engine`) at parity: all 19 `test_observation.py` tests accounted for, the Engine lock, re-entry and commit-poisoning tests ported against a real Engine, fixtures byte for byte through Instance doors and through the Engine ([tests](packages/petrus-observation/PARITY.md), [EngineSpec](packages/petrus-observation/test/Petrus/Observation/EngineSpec.hs), [differential](packages/petrus-observation/differential), [bench](packages/petrus-observation/bench/RESULTS.md), [divergences](packages/petrus-observation/DIVERGENCES.md)). Remaining: the HTTP adapter `engine/observation_http.py` (7 tests in `test_observation_http.py`), which needs an HTTP core this repository does not have yet |
| Net DSL | `impetus/dsl.py` | `petrus-dsl` | at parity | 68-net differential corpus (v3 bytes, order, URIs, refusals); [tests](packages/petrus-dsl/PARITY.md), [differential](packages/petrus-dsl/differential), [bench](packages/petrus-dsl/bench/RESULTS.md), [divergences](packages/petrus-dsl/DIVERGENCES.md) |
| Activities | `motus/activity` | | in progress | value types in `petrus-activity` |
| Dispatch port, InlineDispatch, InMemoryDispatch | `motus/dispatch/{__init__,inline,memory}.py` | `petrus-motus` | at parity | [PARITY](packages/petrus-motus/PARITY.md), [DIVERGENCES](packages/petrus-motus/DIVERGENCES.md); exercised end to end by the [Engine bench](packages/petrus-engine/bench/RESULTS.md) |
| Dispatch: local (SQLite) | `motus/dispatch/local.py` | `petrus-motus` (`Petrus.Motus.Dispatch.Local`) | at parity | all 36 upstream tests ported ([PARITY](packages/petrus-motus/PARITY.md); Engine-level tests in [LocalDispatchSpec](packages/petrus-engine/test/Petrus/Engine/LocalDispatchSpec.hs)), [DIVERGENCES](packages/petrus-motus/DIVERGENCES.md), shared-file interop both ways with identical rows and telemetry ([LocalInteropSpec](packages/petrus-motus/test/Petrus/Motus/Dispatch/LocalInteropSpec.hs)), [bench](packages/petrus-motus/bench/RESULTS.md) (1.3–1.9× faster at equal IO) |
| Dispatch: Absurd | `motus/dispatch` | | not started | |
| Execution, Gondolin | `motus/execution`, `motus/_execution` | `petrus-execution` | in progress (all upstream tests ported; real-Gondolin acceptance run pending) | [PARITY](packages/petrus-execution/PARITY.md), [divergences](packages/petrus-execution/DIVERGENCES.md), [bench](packages/petrus-execution/bench/RESULTS.md) |
| Workers | `motus/worker` | | not started | |
| Transport: ZeroMQ | `motus/transport` | | not started | |
| Engine (provider-neutral) and coordination | `engine/__init__.py`, `engine/_coordination.py` | `petrus-engine` | at parity | [PARITY](packages/petrus-engine/PARITY.md), [DIVERGENCES](packages/petrus-engine/DIVERGENCES.md), JSONL interop with crash/resume both ways (`test/Petrus/Engine/InteropSpec.hs`), [bench](packages/petrus-engine/bench/RESULTS.md) |
| Engine: SQLite, Postgres, Absurd | `engine/{sqlite,postgres,absurd}.py` | `petrus-engine` provider seam (`Petrus.Engine.Provider`) | not started | |
| Simulation + HTTP | `simulation.py`, `simulation_http.py` | | not started | |
| Telemetry | `telemetry.py`; the `impetus_*` events of `impetus/instance`, `engine/_coordination.py`, `impetus/history_store/jsonl.py` | `petrus-telemetry`, `petrus-telemetry-instrumentation` | at parity | all 29 + 22 upstream tests ported ([PARITY](packages/petrus-telemetry/PARITY.md), [DIVERGENCES](packages/petrus-telemetry/DIVERGENCES.md)); [differential](packages/petrus-telemetry-instrumentation/differential): 23 scenarios, 282 events exact and routed lines byte-identical; [bench](packages/petrus-telemetry-instrumentation/bench/RESULTS.md): routed emit 3× cheaper than Python. Events of unported components (workers, local/Absurd dispatch, Postgres stores, fabric) belong to those components' rows |
| Deterministic simulation testing | `testing/dst.py`, `tests/dst/*_world.py` | `petrus-dst` | in progress | everything except the joined Postgres worlds is at parity. That covers the interpreter, artifacts v1 to v4, replay, the process runner (including the real public-Engine resource world in a child), and all 18 non-joined Engine worlds on the real Haskell Engine and the SQLite LocalDispatch. Every one of those fixtures replays through real profiles to the reference's result bytes, all 18 reference builders are authored byte for byte, and 26 checker verdicts match in full ([PARITY](packages/petrus-dst/PARITY.md), [EngineWorlds](packages/petrus-dst/test/Spec/EngineWorlds.hs), [EngineCheckers](packages/petrus-dst/test/Spec/EngineCheckers.hs), [divergences](packages/petrus-dst/DIVERGENCES.md)). Bench: Engine-world replay 2.0× and authoring 2.1× faster than Python over 18 fixtures and 18 stories ([RESULTS](packages/petrus-dst/bench/RESULTS.md)). Remaining: the 33 `joined-*` fixtures, which need the Postgres History store and the Absurd joined Engine and Dispatch. Their replay half is checked through recorded transcripts |
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
| HTTP/1.0 server core | `http.server` (`ThreadingHTTPServer`, `BaseHTTPRequestHandler`) under the observation and simulation services | `petrus-http-core` | in progress | `packages/petrus-http-core/test`, [benchmarks](packages/petrus-http-core/bench/RESULTS.md), [divergences](packages/petrus-http-core/DIVERGENCES.md) |

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
| Readiness net V5 (topology, nine loops, startup, folding) | `src/hamsterdan/readiness/net_v5`, `readiness/payloads.py` | `hamsterdan-readiness` | at parity | net definition byte-identical (fingerprint gate: [net_definition.sha256](packages/hamsterdan-readiness/test/corpus/net_definition.sha256)); [3292-call fold corpus](packages/hamsterdan-readiness/test/corpus/folds.jsonl) over all ten loops; every upstream `net_v5` test ported ([PARITY](packages/hamsterdan-readiness/PARITY.md); the five inline-recovery convergence cases run against a ledger double until `hamsterdan-host` has the real gates), [DIVERGENCES](packages/hamsterdan-readiness/DIVERGENCES.md), [bench](packages/hamsterdan-readiness/bench/RESULTS.md) (folding 4.0–11.0×) |
| Gate handlers and `$variant` converter | `readiness/net_v5/gating.py` | `hamsterdan-readiness` | at parity | 465 `prepare`/`project`/`project_failure` calls byte for byte, `$variant` routing included ([folds.jsonl](packages/hamsterdan-readiness/test/corpus/folds.jsonl)); `test_gating.py` over JSONL history and SQLite Local dispatch, `test_inline_recovery.py` ([PARITY](packages/hamsterdan-readiness/PARITY.md)), [DIVERGENCES](packages/hamsterdan-readiness/DIVERGENCES.md) |
| Summary board rendering | `readiness/net_v5/board.py` | `hamsterdan-readiness` | at parity | `render_board` and `gate_facts` byte for byte on [1569 entry logs](packages/hamsterdan-readiness/test/corpus/board.jsonl), `test_board.py` ported ([PARITY](packages/hamsterdan-readiness/PARITY.md)), [bench](packages/hamsterdan-readiness/bench/RESULTS.md) (3.7–4.7×) |
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
| Readiness model oracle | `src/hamsterdan/testing/readiness.py` | `hamsterdan-testing` | at parity | [2000-document oracle corpus](packages/hamsterdan-testing/test/corpus/oracle.jsonl) (admission and construction rules, strict dumps, expectations, liveness), `test_readiness_model.py` ported ([PARITY](packages/hamsterdan-testing/PARITY.md)), [DIVERGENCES](packages/hamsterdan-testing/DIVERGENCES.md), [bench](packages/hamsterdan-testing/bench/RESULTS.md) (1.7–22.8×) |
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
| `fileVersion: "2"` net loading | `src/petrus/loader.py`, `net_file_schema.json` | | not started | |
