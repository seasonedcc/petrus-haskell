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
| Petri net kernel | `impetus/petrinet`, `impetus/scope` | `petrus-impetus` | in progress | |
| Event history + schema-5 codec | `impetus/history` | `petrus-impetus` | in progress | |
| Bindings, handlers, selection | `impetus/binding`, `impetus/selection` | `petrus-impetus` | in progress | |
| CEL | `impetus/binding/cel.py` (cel-python 0.5.0) | `petrus-cel` | in progress | |
| Instance | `impetus/instance` | `petrus-impetus` | in progress | |
| Net definition v3 | `impetus/net_definition.py` | `petrus-impetus` | in progress | |
| Net document v1 | `impetus/net_document.py` | `petrus-impetus` | in progress | |
| Golden traces | `spec/traces` | `petrus-impetus` | in progress | |
| History stores: memory | `impetus/history_store/memory.py` | `petrus-impetus` | in progress | |
| History stores: JSONL, SQLite, Postgres | `impetus/history_store/{jsonl,sqlite,postgres}.py` | | not started | |
| Observation | `impetus/observation.py`, `engine/observation_http.py` | | not started | |
| Net DSL | `impetus/dsl.py` | | not started | |
| Activities | `motus/activity` | | not started | |
| Dispatch: local, Absurd | `motus/dispatch` | | not started | |
| Execution, Gondolin | `motus/execution`, `motus/_execution` | | not started | |
| Workers | `motus/worker` | | not started | |
| Transport: ZeroMQ | `motus/transport` | | not started | |
| Engine: SQLite, Postgres, Absurd, coordination | `engine/` | | not started | |
| Simulation + HTTP | `simulation.py`, `simulation_http.py` | | not started | |
| Telemetry | `telemetry.py` | | not started | |
| Deterministic simulation testing | `testing/dst.py` | | not started | |
| Agenticus | `agenticus/` | | not started | |
| Fabric | `fabric/` | | in progress (spec) | |
| Processes (call/spawn) | `processes/` | | in progress (spec) | |

## hamsterdan

| Component | Upstream | Haskell package | Status | Evidence |
| --- | --- | --- | --- | --- |
| Contracts | `src/hamsterdan/contracts` | | not started | |
| Readiness nets | `src/hamsterdan/readiness` | | not started | |
| Host | `src/hamsterdan/host` | | not started | |
| GitHub App | `src/hamsterdan/github_app` | | not started | |
| Agents | `src/hamsterdan/agents` | | not started | |
| Operator | `src/hamsterdan/operator.py` | | not started | |
| End-to-end against a real GitHub App | — | | not started | |

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
