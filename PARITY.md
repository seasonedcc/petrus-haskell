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
| Instance | `impetus/instance` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md); `FiringFailed.error` text for Haskell exceptions is a [documented divergence](packages/petrus-impetus/DIVERGENCES.md) |
| Net definition v3 | `impetus/net_definition.py` | `petrus-impetus` | in progress | edge cases listed in [PARITY](packages/petrus-impetus/PARITY.md); [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md) |
| Net document v1 | `impetus/net_document.py` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md) |
| Golden traces | `spec/traces` | `petrus-impetus` | at parity | [GoldenTracesSpec](packages/petrus-impetus/test), `cabal run petrus-golden-traces` |
| History stores: memory | `impetus/history_store/memory.py` | `petrus-impetus` | at parity | [tests](packages/petrus-impetus/PARITY.md), [differential](packages/petrus-impetus/differential), [bench](packages/petrus-impetus/bench/RESULTS.md) |
| History stores: JSONL | `impetus/history_store/jsonl.py` | `petrus-history-store` | at parity | [PARITY](packages/petrus-history-store/PARITY.md), [DIVERGENCES](packages/petrus-history-store/DIVERGENCES.md), byte-identical interop both ways (`test/Petrus/HistoryStore/InteropSpec.hs`), [bench](packages/petrus-history-store/bench/RESULTS.md) |
| History stores: SQLite, Postgres | `impetus/history_store/{sqlite,postgres}.py` | `petrus-history-store` (SQLite place reserved) | not started | |
| Observation | `impetus/observation.py`, `engine/observation_http.py` | `petrus-observation` | in progress | `observation.py` and the Engine's read doors (`Petrus.Observation.Engine`) at parity: all 19 `test_observation.py` tests accounted for, the Engine lock, re-entry and commit-poisoning tests ported against a real Engine, fixtures byte for byte through Instance doors and through the Engine ([tests](packages/petrus-observation/PARITY.md), [EngineSpec](packages/petrus-observation/test/Petrus/Observation/EngineSpec.hs), [differential](packages/petrus-observation/differential), [bench](packages/petrus-observation/bench/RESULTS.md), [divergences](packages/petrus-observation/DIVERGENCES.md)). Remaining: the HTTP adapter `engine/observation_http.py` (7 tests in `test_observation_http.py`), which needs an HTTP core this repository does not have yet |
| Net DSL | `impetus/dsl.py` | `petrus-dsl` | at parity | 68-net differential corpus (v3 bytes, order, URIs, refusals); [tests](packages/petrus-dsl/PARITY.md), [differential](packages/petrus-dsl/differential), [bench](packages/petrus-dsl/bench/RESULTS.md), [divergences](packages/petrus-dsl/DIVERGENCES.md) |
| Activities | `motus/activity` | | in progress | value types in `petrus-activity` |
| Dispatch port, InlineDispatch, InMemoryDispatch | `motus/dispatch/{__init__,inline,memory}.py` | `petrus-motus` | at parity | [PARITY](packages/petrus-motus/PARITY.md), [DIVERGENCES](packages/petrus-motus/DIVERGENCES.md); exercised end to end by the [Engine bench](packages/petrus-engine/bench/RESULTS.md) |
| Dispatch: local, Absurd | `motus/dispatch` | | not started | |
| Execution, Gondolin | `motus/execution`, `motus/_execution` | `petrus-execution` | in progress (all upstream tests ported; real-Gondolin acceptance run pending) | [PARITY](packages/petrus-execution/PARITY.md), [divergences](packages/petrus-execution/DIVERGENCES.md), [bench](packages/petrus-execution/bench/RESULTS.md) |
| Workers | `motus/worker` | | not started | |
| Transport: ZeroMQ | `motus/transport` | | not started | |
| Engine (provider-neutral) and coordination | `engine/__init__.py`, `engine/_coordination.py` | `petrus-engine` | at parity | [PARITY](packages/petrus-engine/PARITY.md), [DIVERGENCES](packages/petrus-engine/DIVERGENCES.md), JSONL interop with crash/resume both ways (`test/Petrus/Engine/InteropSpec.hs`), [bench](packages/petrus-engine/bench/RESULTS.md) |
| Engine: SQLite, Postgres, Absurd | `engine/{sqlite,postgres,absurd}.py` | `petrus-engine` provider seam (`Petrus.Engine.Provider`) | not started | |
| Simulation + HTTP | `simulation.py`, `simulation_http.py` | | not started | |
| Telemetry | `telemetry.py` | | in progress | `petrus-telemetry`; Engine instrumentation pending |
| Deterministic simulation testing | `testing/dst.py`, `tests/dst/*_world.py` | `petrus-dst` | in progress | everything except the joined Postgres worlds is at parity. That covers the interpreter, artifacts v1 to v4, replay, the process runner (including the real public-Engine resource world in a child), and all 18 non-joined Engine worlds on the real Haskell Engine and the SQLite LocalDispatch. Every one of those fixtures replays through real profiles to the reference's result bytes, all 18 reference builders are authored byte for byte, and 26 checker verdicts match in full ([PARITY](packages/petrus-dst/PARITY.md), [EngineWorlds](packages/petrus-dst/test/Spec/EngineWorlds.hs), [EngineCheckers](packages/petrus-dst/test/Spec/EngineCheckers.hs), [divergences](packages/petrus-dst/DIVERGENCES.md)). Bench: Engine-world replay 2.6× and authoring 2.9× faster than Python ([RESULTS](packages/petrus-dst/bench/RESULTS.md)). Remaining: the 33 `joined-*` fixtures, which need the Postgres History store and the Absurd joined Engine and Dispatch. Their replay half is checked through recorded transcripts |
| Agenticus | `agenticus/` | | not started | |
| Fabric | `fabric/` | | in progress (spec written) | [spec/fabric.md](spec/fabric.md), [108 checks](spec/fabric-conformance.md) |
| Processes (call/spawn) | `processes/` | | in progress (spec written) | [spec/processes.md](spec/processes.md), [80 checks](spec/processes-conformance.md) |

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
| Contracts (V5 workflow models, agent protocol types) | `src/hamsterdan/contracts`, `src/hamsterdan/agents/protocol.py` (types) | `hamsterdan-contracts` | not started | |
| Python-literal repr/parse for dashboard entries and digests | `readiness/net_v5/dashboard.py`, `board.py` (`repr`, `ast.literal_eval`) | `hamsterdan-contracts` | not started | |
| Readiness net V5 (topology, nine loops, startup, folding) | `src/hamsterdan/readiness/net_v5`, `readiness/payloads.py` | `hamsterdan-readiness` | not started | |
| Gate handlers and `$variant` converter | `readiness/net_v5/gating.py` | `hamsterdan-readiness` | not started | |
| Summary board rendering | `readiness/net_v5/board.py` | `hamsterdan-readiness` | not started | |
| GitHub App config and installations TOML | `github_app/config.py` | `hamsterdan-github` | not started | |
| Webhook verification and durable inbox | `github_app/webhooks.py`, `host/api.py` | `hamsterdan-github`, `hamsterdan-host` | not started | |
| Installation and repository routing | `github_app/routing.py` | `hamsterdan-github` | not started | |
| App auth (JWT, installation tokens) and bounded transport | `github_app/auth.py`, `github_app/transport.py` | `hamsterdan-github` | not started | |
| Provider reads (REST and GraphQL) | `github_app/gateway.py` | `hamsterdan-github` | not started | |
| Effects (comments, reviews, thread resolution, rerun marker) | `github_app/effects.py` | `hamsterdan-github` | not started | |
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
| `petrus` CLI | `bin/petrus.mjs` | | not started | |
| MCP server | `server/mcp.mjs` | | not started | |
| Agent WebSocket protocol | `src/agent/protocol.ts`, bridge | | not started | |
| Collaboration relay | `server/collab.mjs` | | not started | |
| File and URL endpoints | `server/openFileEndpoint.mjs`, `server/urlCache.mjs` | | not started | |
| Simulation and history replay | `src/` | | not started | |

## petrus-engine

| Component | Upstream | Haskell package | Status | Evidence |
| --- | --- | --- | --- | --- |
| `fileVersion: "2"` net loading | `src/petrus/loader.py`, `net_file_schema.json` | | not started | |
