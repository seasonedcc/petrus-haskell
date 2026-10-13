# petrus-viewer-server: parity with petrus-viewer

This package replaces the Node backend of petrus-viewer at the pin in
[UPSTREAM.md](../../UPSTREAM.md). The browser UI is still the upstream
TypeScript bundle, served by `petrus`. Everything the UI, agents and MCP
clients talk to is Haskell.

For each capability, this file gives:

- the functional evidence: the ported upstream tests, our own specs, and
  differential tests against the Node code;
- the benchmark against the Node implementation.

[DIVERGENCES.md](DIVERGENCES.md) lists every behavior that differs on
purpose. Two of them are known gaps in the JavaScript emulation, kept
deliberately and each with its reason
([Faithfulness limits](DIVERGENCES.md#faithfulness-limits-of-the-javascript-emulation)):
a `$ref` host with compatibility characters (`ﬀ`) is not UTS #46 mapped as
Node maps it, and a malformed-JSON message from a history server loses a
surrogate cut in half. [bench/RESULTS.md](bench/RESULTS.md) has the full benchmark
tables, the method and the commands.

## How to check

```bash
cabal test petrus-viewer-server                               # the hspec suite
node packages/petrus-viewer-server/upstream-tests/run.mjs     # upstream suites
node packages/petrus-viewer-server/bench/run.mjs --reps 15    # benchmarks
```

The upstream suites need:

- `pnpm install` and `pnpm build` in `upstream/petrus-viewer`;
- `npx playwright install --with-deps chromium` for the browser suites;
- the pinned Python reference (`scripts/upstream-python`) for `history`.

`run.mjs` copies the upstream test files unchanged. It rewrites only the
lines that start the backend, so the tests run against the Haskell
executables, and every rewrite must match the upstream text exactly. The
suites marked "ours" were written for this port.

| `upstream-tests/run.mjs` suite | Source | Result |
| --- | --- | ---: |
| `relay` | `tests/bridgeVitePlugin.test.mjs` | 5/5 |
| `endpoints` | `tests/openFileEndpoint.test.mjs`, `tests/resolveRefEndpoint.test.mjs` | 14/14 |
| `url-cache` | `tests/urlCache.test.mjs` | 9/9 |
| `cli` | `tests/petrusCli.test.mjs` | 5/5 |
| `mcp` | `tests/mcpServer.test.mjs` | 7/7 |
| `mcp-haskell-relay` | `tests/mcpServer.test.mjs` with the relay in `petrus` | 7/7 |
| `mcp-node-haskell-relay` | `tests/mcpServer.test.mjs` with the upstream `server/mcp.mjs` on the relay in `petrus` | 7/7 |
| `collab` | `tests/collab-server.test.mjs` | 6/6 |
| `protocol` | `tests/agentProtocol.test.ts`, `tests/agentParseRegression.test.ts`, with `parseAgentMessage` answered by `Agent.Protocol` through the test executable's oracle mode (`petrus-viewer-server-test --oracle`) | 19/19 |
| `differential` | ours: JSON and URL ports against V8 and Node | 4/4 |
| `wire` | ours: WebSocket bytes against the `ws` relays, and HTTP endpoint bytes against `node:http` | 20/20 |
| `playwright` | `tests/playwright/bridge-live.test.mjs` | 4/4 |
| `live` | ours: every MCP tool through a headless browser; plain `petrus FILE` serves no collaboration relay | 13/13 |
| `history` | ours: replay and live watching in the browser from real producers | 8/8 |

### Upstream tests not run here: the UI's own

The other upstream test files test the browser UI's TypeScript, which this
port does not replace: `petrus` serves the upstream bundle unchanged, so
these tests would exercise exactly the code upstream's own runs exercise
(vitest, in upstream's CI), with no Haskell in the path. They are not
ported, and not run here. Where a file covers code that talks to the
backend, the right column names the evidence that the Haskell backend
answers that code as Node does.

| Upstream file | What it tests (UI side) | Haskell-side evidence for the backend it talks to |
| --- | --- | --- |
| `tests/temporalClient.test.ts` | `queryWorkflowSchema` and the Temporal HTTP client | `history` (the UI's Temporal client against `/temporal` served from real producers); `test/ProxySpec.hs` (the `/temporal` proxy) and `test/HistorySpec.hs` (`/temporal` answered from observation producers) |
| `tests/temporalState.test.ts` | parsing and normalizing a workflow's runtime state | `history` (the same parser fed by the Haskell `/temporal` answers) |
| `tests/temporalSchema.test.ts` | converting a workflow schema to a net file | `history` |
| `tests/openFileBoot.test.ts` | `parseNetFile` on the payloads the UI boots from | `endpoints` (`tests/openFileEndpoint.test.mjs`, the payloads it parses), `test/EndpointsSpec.hs`, `wire` (the endpoint bytes against `node:http`) |
| `tests/resolveRef.test.ts`, `tests/unifiedRefLoader.test.ts`, `tests/githubUrl.test.ts` | the browser's `$ref` path resolution, its loader over `/__petrus/resolve-ref`, and its own `normalizeGitHubUrl` | `endpoints` (`tests/resolveRefEndpoint.test.mjs`), `url-cache` (the server's `normalizeGitHubUrl` and cache), `test/UrlSpec.hs`, `differential` (URL resolution against Node), `live` (`petrus_open_file` with refs in a browser) |
| `tests/agentE2e.test.ts`, `tests/agentHost.test.ts`, `tests/agentStoreAdapter.test.ts` | the browser's agent host and store adapter | `live` (every MCP tool through the Haskell relay in a browser), `relay`, `mcp*`, `wire` |
| `tests/agentHighlightWiring.test.ts`, `tests/agentHighlights.test.ts`, `tests/agentMutationAffected.test.ts`, `tests/agentMutationExecutor.test.ts`, `tests/agentMutationOps.test.ts`, `tests/agentUndoRedo.test.ts` | applying agent mutations and highlights to the editor state | none needed: browser state only (`live` drives them end to end) |
| `tests/autoLayout.test.ts`, `tests/compactJson.test.ts`, `tests/computeEnabled-fireTransition.test.ts`, `tests/edgeRouting.test.ts`, `tests/namespace.test.ts`, `tests/netFileSlim.test.ts`, `tests/netpath.test.ts`, `tests/toReactFlow.test.ts` | layout, serialization, simulation and rendering helpers of the editor | none needed: browser-only code (simulation stays in the UI, see Simulation below) |
| `tests/ui/**` (`App`, `ArcPieMenu`, `CollabPopover`, `PlaceNode`, `RemoteCursors`, `TemporalConnect`, `Toolbar`, `TransitionNode`, `collabStore`, `collaboration`, `idbSession`, `loadFileSession`, `sessionPersistence`) | React components, collaboration store and session persistence (jsdom) | `collab` and `wire` for the collaboration relay the store talks to; `playwright`, `live` and `history` drive the real UI against `petrus` |

`tests/helpers.ts` and `tests/ui/setup.ts` are shared helpers, not tests.

## Capabilities

The figures are in [bench/RESULTS.md](bench/RESULTS.md), measured on a
machine shared with other agents: its latest run covers every scenario on
the current code in interleaved rounds, and "Low-level code, measured"
measures each low-level piece of the server against the clean version, in
the same rounds as Node. Each ratio there compares the best Haskell server
with the best Node server, by the median of the rounds' ratios; this file
names the scenarios and does not restate their figures, which change with
every run.

### `petrus` CLI (`bin/petrus.mjs`)

**Evidence:**

- `test/CliSpec.hs`.
- Upstream `cli` (5/5).
- Upstream `playwright` (4/4): the upstream browser suite against
  `petrus`.
- Upstream `live` (13/13).

**Performance**, against `node bin/petrus.mjs`, the Vite dev server and
`vite preview`: ahead of Node by median on every scenario, the cold start
until the file and the UI are served, `GET /` (index.html) with 1 and 16
clients, the JS bundle and `/sample-net.json` with 16 clients, and
`/temporal/...` (proxied) with 1 and 16 clients. The endpoints and relays
the CLI's server also answers are in the rows below.

**Status:** at parity. `petrus` serves the built UI instead of running
Vite (see [DIVERGENCES.md](DIVERGENCES.md)).

### MCP server (`server/mcp.mjs`)

**Evidence:**

- `test/McpSpec.hs`: the 16 tools in order, and the upstream Node
  transcript reproduced byte for byte: a session that calls every tool
  past input validation (checked), plus validation failures, unknown
  tools and methods, a garbage line and version negotiation.
  `test/record-mcp-transcript.mjs` records the transcript from
  `server/mcp.mjs`; its `--check` runs in CI's `viewer` job and in
  `scripts/check-all --viewer`. `test/record-node-corpora.mjs` re-records
  the V8 `JSON.parse` and WHATWG URL corpora (`scripts/check-corpora`).
- Upstream `mcp` (7/7) and `mcp-haskell-relay` (7/7); `mcp-node-haskell-relay` (7/7), the
  other direction: the upstream Node MCP server on the `petrus` relay.
- `live` (13/13): every tool, through `petrus-mcp` (Haskell), the `petrus`
  relay (Haskell) and the built UI in headless Chromium.

**Performance**, `petrus-mcp` against `node server/mcp.mjs`, both
bridged to the same relay; one op is a `tools/call` line on stdin
answered on stdout. `petrus-mcp` is ahead by median on every scenario:
`petrus_inspect_document` (bridged) with 1 call at a time and with 16 in
flight, and `petrus_status` with 1 call at a time, and uses less CPU time
per call than Node (run G). Its event loop (`Mcp.Reactor`) and the C string
escaper are what keep it ahead with 16 calls in flight: without them it
fell behind Node ("Low-level code, measured").

**Status:** at parity.

### Agent WebSocket relay and protocol (`agentRelay` Vite plugin, `src/agent/protocol.ts`)

**Evidence:**

- `test/RelaySpec.hs` and `test/ProtocolSpec.hs` (`ProtocolSpec` ports 18 of the 19 upstream protocol cases, all but
  `selectedEdgeToRef`, a browser-side helper).
- Upstream `relay` (5/5), `protocol` (19/19: the upstream protocol tests,
  verbatim, against the Haskell parser) and `differential` (4/4).
- `wire` (`ws-wire.test.mjs`, 2/2):
  - the opening handshake, compared byte for byte with `ws` over 20
    requests: the 101 and the 400/405 refusals, subprotocols, repeated
    headers, versions, keys, and methods;
  - frames, close codes and reasons, and protocol errors, also byte for
    byte.
- `live` (13/13).

**Performance**, against the Node relay on bare `ws` (Node's fastest
case), both without the timing log: the round trip is ahead by median with
1 pair and with 16 pairs. Before this work the 16-pair round trip was
behind. With the timing log on, `petrus` also serves more round trips than
the Vite relay that `bin/petrus.mjs` runs (1 and 16 pairs, median ops/s).

**Status:** at parity.

### Collaboration relay (`server/collab.mjs`)

**Evidence:**

- `test/CollabSpec.hs`.
- Upstream `collab` (6/6).
- `wire` (`ws-wire.test.mjs`, 2/2): every byte against `server/collab.mjs`.
- `live`: a plain `petrus FILE` refuses `/collab-ws`, as Vite without
  `--host` does, and the UI loads its file; `test/ServerSpec.hs` checks
  the same at the socket.

**Performance:** fan-out to 50 or 200 peers is ahead of Node in every
round.

**Status:** at parity. Unlike upstream, the Haskell relay keeps running
after a WebSocket protocol error (see [DIVERGENCES.md](DIVERGENCES.md)).

### `resolve-ref` endpoint (`server/openFileEndpoint.mjs`, `server/urlCache.mjs`)

**Evidence:**

- `test/EndpointsSpec.hs` and `test/UrlSpec.hs`.
- Upstream `endpoints` (14/14) and `url-cache` (9/9).
- `differential` (4/4): `new URL`, `decodeURIComponent` and
  `JSON.parse`/`JSON.stringify` against Node.
- `wire` (`http-wire.test.mjs`): raw requests to `petrus` and to the
  upstream endpoint on bare `node:http` give the same status, the same
  handler headers in the same order, the same body, and close the
  connection at the same point. That covers local files and every
  refusal, `Connection: close`, HTTP/1.0, split and pipelined requests,
  `Expect: 100-continue`, and a 400-request pipelined burst read slowly.
  The framing around them is Warp's (`Date` first, no `Keep-Alive`
  header, the HTTP/1.0 status line and keep-alive); a separate case pins
  the one difference in when a connection closes (an HTTP/1.0 request
  that asks for keep-alive), as [DIVERGENCES.md](DIVERGENCES.md) records.

**Performance:** ahead of Node by median with 1 and with 16 clients.
Warp serves the endpoints. The hand-written HTTP front that
served them in earlier runs was a little faster here, but Warp stays ahead
of Node, so it went ("Low-level code, measured"). The file reads
(`FileIO`, `cbits/file_io.c`) and the string escaper
(`cbits/json_escape.c`) stay: with the clean versions, resolve-ref fell
behind Node. Single 1-client rounds behind Node are rounds in which every
server slowed down together. On GitHub's Linux runner the 1-client row
came out even with Node. Profiled there, every request made a safe
foreign call (`F_OK`, imported without `unsafe`), which handed the
capability to a second OS thread and back, and the 16 MB allocation area
cost cache misses. With `F_OK` unsafe and GHC's default 4 MB area, the
row is ahead on Linux too, with 1 and with 16 clients (bench/RESULTS.md,
"Where a request spends its time on Linux").

**Status:** at parity: ahead in every median, on the Mac and on Linux.

### `open-file` endpoint (`server/openFileEndpoint.mjs`)

**Evidence:**

- `test/EndpointsSpec.hs`, including a pending file served to one of 16
  concurrent `GET`s only, as Node's single thread does.
- Upstream `endpoints` (14/14).
- `wire` (`http-wire.test.mjs`): the bytes of `GET` 204 and 200, `POST`
  and its refusals, `OPTIONS`, 405 and `HEAD`, and a pending file that
  cannot be read (500, and it stays pending) are identical to Node's, as
  for resolve-ref above.
- `live`: the UI loads `PETRUS_OPEN_FILE` through the endpoint.

**Performance:** ahead of Node by median with 1 client and with 16
clients in lockstep. Warp serves the endpoint, as for
resolve-ref above; in the A/B against the earlier HTTP front, both were
ahead of Node, the front a little more. On GitHub's Linux runner the
1-client row came out even with Node, with the front too. The two changes
that lifted resolve-ref there (an unsafe `F_OK` for the `POST`'s existence
check, and a 4 MB allocation area) lift this row too, with 1 and with 16
clients (bench/RESULTS.md, "Where a request spends its time on Linux").

What changed:

- **The 16-client workload is now the same on every server.** All
  clients share one pending file, so with free-running clients the
  number of `GET`s that read it depended on how each server interleaved
  them. The load client now runs lockstep rounds (every client `POST`s,
  then every client `GET`s), and the runner fails if any run's status
  counts differ.
- **A race fixed.** The workload check caught the previous server: its
  `GET` read the pending file and cleared it afterwards, so two Warp
  threads could both serve one pending file (up to 6 extra 200s in a
  run). Node's single thread cannot. The `GET` now takes the file
  atomically.
- **The load client.** It now speaks HTTP/1.1 itself. With `http-client`
  it was slower than the servers at 16 clients and set the pace for all
  of them.

Single rounds behind Node are rounds in which the shared machine slowed
servers together: it has 4 performance and 6 efficiency cores, and other
agents kept its load high. In such a round, `petrus` and the bare Node
server both fell to about half their speed, while the Vite dev server did
not. The details are in [bench/RESULTS.md](bench/RESULTS.md).

**Status:** at parity: ahead in every median, on the Mac and on Linux.

### Simulation (browser UI)

**Evidence:**

- Upstream `playwright` (4/4) against `petrus`.
- `live`: `petrus_simulation_command`, `petrus_scenario_save`,
  `petrus_scenario_compare` and `petrus_inspect_simulation` through the
  Haskell relay.

**Performance:** simulation runs in the browser. The backend's part is
the agent relay.

**Status:** at parity. Simulation runs in the UI upstream as well.
Upstream petrus-viewer never calls a simulation service:
`simulation-http-v1`, ported in `petrus-simulation`, has no consumer in
the pinned UI. Its consumer upstream is plausibly Arx, the separately
maintained editor and inspector that upstream's README names; upstream's
`test_simulation_http.py` calls the service from the browser origin
`http://localhost:5173`. Arx is private, so interop with it is untested
(SCOPE.md).

### History replay and live watching (`/temporal`)

**Evidence:**

- `test/ObservationSpec.hs`: the mapping from the observation fixtures in
  `upstream/petrus/spec`.
- `test/HistorySpec.hs`: real producers in the same scenario, a chain Net
  advanced one step at a time.
  - The producers are a Haskell Engine (`petrus-engine` with
    `petrus-observation-http`) and the pinned Python reference
    (`withPython`).
  - Replay: the list, `get_schema` and `get_state` queries, and a query
    for an unknown workflow.
  - Live watching: `get_state` is polled after every step, and the states
    the UI appends (`states.slice(length)`) are checked until the Engine
    is terminal.
  - Both producers give the same answers at every step.
- `history` (8/8), in the built UI, with both producers behind one
  `petrus`:
  - the Connect dialog lists both instances;
  - Load State replays one;
  - Watch Live follows each Engine as it advances, and leaves live mode
    once the Engine is terminal;
  - `petrus_trace_import` replays the finished run;
  - the UI ends up with the same history from both producers.
- `live`: replay through `petrus_trace_import` with `PETRUS_HISTORY_URL`.
- `test/ProxySpec.hs`: the `/temporal` proxy to a Temporal-like target
  passes content codings through as Vite's http-proxy does. The browser's
  `Accept-Encoding` arrives as sent, or absent when the browser sent none.
  A `br`, `deflate` or `gzip` body comes back byte for byte, with its
  `Content-Encoding`.

**Performance:** the observation source has no Node counterpart: upstream
proxies `/temporal` to Temporal. The proxy itself is benchmarked under the
`petrus` CLI above, ahead of Vite's.

**Status:** at parity.
