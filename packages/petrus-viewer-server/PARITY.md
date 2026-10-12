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
purpose. [bench/RESULTS.md](bench/RESULTS.md) has the full benchmark
tables, the method and the commands.

## How to check

```bash
cabal test petrus-viewer-server                               # 114 examples
node packages/petrus-viewer-server/upstream-tests/run.mjs     # upstream suites
node packages/petrus-viewer-server/bench/run.mjs --reps 15    # benchmarks
```

The upstream suites need:

- `pnpm install` and `pnpm build` in `upstream/petrus-viewer`;
- `npx playwright install chromium` for the browser suites;
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
| `protocol` | `tests/agentProtocol.test.ts`, `tests/agentParseRegression.test.ts`, with `parseAgentMessage` answered by `Agent.Protocol` through `petrus-viewer-oracle` | 19/19 |
| `differential` | ours: JSON and URL ports against V8 and Node | 4/4 |
| `wire` | ours: WebSocket bytes against the `ws` relays, and HTTP endpoint bytes against `node:http` | 20/20 |
| `playwright` | `tests/playwright/bridge-live.test.mjs` | 4/4 |
| `live` | ours: every MCP tool through a headless browser; plain `petrus FILE` serves no collaboration relay | 13/13 |
| `history` | ours: replay and live watching in the browser from real producers | 8/8 |

## Capabilities

The ratios below come from [bench/RESULTS.md](bench/RESULTS.md), on a
machine shared with other agents:

- run I (2026-10-12): every scenario on the current code, 5 interleaved
  rounds, with a load average of 4.1–6.7;
- "Low-level code, measured": each low-level piece of the server against
  the clean version, in the same rounds as Node (7 each).

- "Median" is the median of the Haskell / Node ratios of the rounds.
- "Per round" is the lowest Haskell / Node ratio within a single round,
  and "ahead" the rounds Haskell won.

Each ratio compares the best Haskell server with the best Node server.

### `petrus` CLI (`bin/petrus.mjs`)

**Evidence:**

- `test/CliSpec.hs` (10 examples).
- Upstream `cli` (5/5).
- Upstream `playwright` (4/4): the upstream browser suite against
  `petrus`.
- Upstream `live` (13/13).

**Performance** (run I), against `node bin/petrus.mjs`, the Vite dev
server and `vite preview`:

| Scenario | Median | Per round | Ahead |
| --- | ---: | ---: | ---: |
| cold start until the file and the UI are served | 25.41x | ≥ 18.10x | 5 of 5 |
| GET / (index.html), 1 client | 1.63x | ≥ 1.43x | 5 of 5 |
| GET / (index.html), 16 clients | 1.49x | ≥ 1.38x | 5 of 5 |
| GET the JS bundle (592 KiB), 16 clients | 4.03x | ≥ 3.22x | 5 of 5 |
| GET /sample-net.json, 16 clients | 1.93x | ≥ 1.47x | 5 of 5 |
| GET /temporal/... (proxied), 1 client | 3.61x | ≥ 3.58x | 5 of 5 |
| GET /temporal/... (proxied), 16 clients | 1.98x | ≥ 1.69x | 5 of 5 |

`petrus FILE` serves the file and the UI 17 ms after it is spawned
(median); `bin/petrus.mjs` takes 417 ms. The endpoints and relays the
CLI's server also answers are in the rows below.

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

**Performance** (run I), `petrus-mcp` against `node server/mcp.mjs`, both
bridged to the same relay; one op is a `tools/call` line on stdin
answered on stdout:

| Scenario | Median | Per round | Ahead |
| --- | ---: | ---: | ---: |
| petrus_inspect_document (bridged), 1 call at a time | 1.36x | ≥ 1.23x | 5 of 5 |
| petrus_inspect_document (bridged), 16 calls in flight | 1.24x | ≥ 1.05x | 5 of 5 |
| petrus_status, 1 call at a time | 1.30x | ≥ 1.06x | 5 of 5 |

Per call, `petrus-mcp` uses about a third of Node's CPU time (run G).
Its event loop (`Mcp.Reactor`) and the C string escaper are what keep it
ahead with 16 calls in flight: without them it served 0.63x and 0.82x
as many calls ("Low-level code, measured").

**Status:** at parity.

### Agent WebSocket relay and protocol (`agentRelay` Vite plugin, `src/agent/protocol.ts`)

**Evidence:**

- `test/RelaySpec.hs` and `test/ProtocolSpec.hs` (31 examples;
  `ProtocolSpec` ports 18 of the 19 upstream protocol cases, all but
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

**Performance** (run I), against the Node relay on bare `ws` (Node's
fastest case), both without the timing log:

| Round trip | Median | Per round | Ahead |
| --- | ---: | ---: | ---: |
| 1 pair | 1.32x | ≥ 1.17x | 5 of 5 |
| 16 pairs | 1.39x | ≥ 0.94x | 4 of 5 |

Before this work the 16-pair round trip was 0.81–0.98x. With the timing
log on, `petrus` serves 1.06x and 1.18x as many round trips as the Vite
relay that `bin/petrus.mjs` runs (1 and 16 pairs, median ops/s).

**Status:** at parity.

### Collaboration relay (`server/collab.mjs`)

**Evidence:**

- `test/CollabSpec.hs` (6 examples).
- Upstream `collab` (6/6).
- `wire` (`ws-wire.test.mjs`, 2/2): every byte against `server/collab.mjs`.
- `live`: a plain `petrus FILE` refuses `/collab-ws`, as Vite without
  `--host` does, and the UI loads its file; `test/ServerSpec.hs` checks
  the same at the socket.

**Performance** (run I): fan-out to 50 or 200 peers is 4.05x and 3.59x
Node by median, and at least 3.14x in every round.

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

**Performance** (run I):

| Clients | Median | Per round | Ahead |
| --- | ---: | ---: | ---: |
| 1 | 1.07x | ≥ 0.78x | 3 of 5 |
| 16 | 1.08x | ≥ 1.03x | 5 of 5 |

Warp serves the endpoints. The hand-written HTTP front that served them
in runs E to H was 2–16% faster here, but Warp stays ahead of Node, so
it went ("Low-level code, measured": 1.17x and 1.11x by median there).
The file reads (`FileIO`, `cbits/file_io.c`) and the string escaper
(`cbits/json_escape.c`) stay: with the clean versions, resolve-ref fell
behind Node (0.94x and 0.78x, then 0.87x and 0.69x). The two 1-client
rounds below 1.0x are rounds in which every server slowed down (in the
0.78x one, all three ran at about half speed).

**Status:** at parity: ahead in every median, by a thin margin.

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

**Performance** (run I):

| Clients | Median | Per round | Ahead |
| --- | ---: | ---: | ---: |
| 1 | 1.05x | ≥ 0.93x | 4 of 5 |
| 16, in lockstep | 1.08x | ≥ 0.52x | 4 of 5 |

Warp serves the endpoint, as for resolve-ref above; in the A/B against
the HTTP front of runs E to H it was 1.11x (1 client) and 1.13x (16
clients) Node by median, the front 1.16x and 1.28x.

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

The rounds below 1.0x are rounds in which the shared machine slowed
servers together. The machine has 4 performance and 6 efficiency cores,
and other agents kept the load at 4–7. In run I's 0.52x round, `petrus`
and the bare Node server both fell to about half their speed (11.4k and
12.3k ops/s, against 21–29k in the other rounds), while the Vite dev
server, the faster Node server in that round, did not. The
details are in [bench/RESULTS.md](bench/RESULTS.md).

**Status:** at parity: ahead in every median, by a thin margin.

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
`petrus` CLI above (2.0–3.6x Vite's, run I).

**Status:** at parity.
