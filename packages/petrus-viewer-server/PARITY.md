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
cabal test petrus-viewer-server                               # 97 examples
node packages/petrus-viewer-server/upstream-tests/run.mjs     # upstream suites
node packages/petrus-viewer-server/bench/run.mjs --reps 7     # benchmarks
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
| `collab` | `tests/collab-server.test.mjs` | 6/6 |
| `differential` | ours: JSON and URL ports against V8 and Node | 4/4 |
| `wire` | ours: WebSocket bytes against the `ws` relays | 2/2 |
| `playwright` | `tests/playwright/bridge-live.test.mjs` | 4/4 |
| `live` | ours: every MCP tool through a headless browser | 12/12 |
| `history` | ours: replay and live watching in the browser from real producers | 8/8 |

## Capabilities

The ratios below come from the two final runs in
[bench/RESULTS.md](bench/RESULTS.md): run C and run D (the final code),
each with 7 interleaved rounds, on a machine shared with other agents.

- "Median" is median Haskell ops/s over median Node ops/s.
- "Per round" is the lowest Haskell / Node ratio within a single round.

Each ratio compares the best Haskell server with the best Node server.

### `petrus` CLI (`bin/petrus.mjs`)

**Evidence:**

- `test/CliSpec.hs` (8 examples).
- Upstream `cli` (5/5).
- Upstream `playwright` (4/4): the upstream browser suite against
  `petrus`.
- Upstream `live` (12/12).

**Performance:** startup is not benchmarked. Every request the CLI's
server answers is benchmarked in the rows below.

**Status:** at parity. `petrus` serves the built UI instead of running
Vite (see [DIVERGENCES.md](DIVERGENCES.md)).

### MCP server (`server/mcp.mjs`)

**Evidence:**

- `test/McpSpec.hs`: the 16 tools in order, and the upstream Node
  transcript reproduced byte for byte.
- Upstream `mcp` (7/7) and `mcp-haskell-relay` (7/7).
- `live` (12/12): every tool, through `petrus-mcp` (Haskell), the `petrus`
  relay (Haskell) and the built UI in headless Chromium.

**Performance:** the MCP server is a stdio bridge, so its cost is the
relay's.

**Status:** at parity.

### Agent WebSocket relay and protocol (`agentRelay` Vite plugin, `src/agent/protocol.ts`)

**Evidence:**

- `test/RelaySpec.hs` and `test/ProtocolSpec.hs` (25 examples).
- Upstream `relay` (5/5) and `differential` (4/4).
- `wire` (2/2):
  - the opening handshake, compared byte for byte with `ws` over 20
    requests: the 101 and the 400/405 refusals, subprotocols, repeated
    headers, versions, keys, and methods;
  - frames, close codes and reasons, and protocol errors, also byte for
    byte.
- `live` (12/12).

**Performance**, against the Node relay on bare `ws` (Node's fastest
case), both without the timing log:

| Round trip | Median (C / D) | Per round (C / D) |
| --- | ---: | ---: |
| 1 pair | 1.41x / 1.40x | ≥ 1.09x / ≥ 1.23x |
| 16 pairs | 1.17x / 1.31x | ≥ 1.07x / ≥ 1.07x |

Before this work the 16-pair round trip was 0.81–0.98x. With the timing
log on, `petrus` is 1.38x the Vite relay that `bin/petrus.mjs` runs
(run D).

**Status:** at parity.

### Collaboration relay (`server/collab.mjs`)

**Evidence:**

- `test/CollabSpec.hs` (6 examples).
- Upstream `collab` (6/6).
- `wire` (2/2): every byte against `server/collab.mjs`.

**Performance:** fan-out to 50 or 200 peers is 3.9–4.5x Node (median),
and at least 3.78x in every round.

**Status:** at parity. Unlike upstream, the Haskell relay keeps running
after a WebSocket protocol error (see [DIVERGENCES.md](DIVERGENCES.md)).

### `resolve-ref` endpoint (`server/openFileEndpoint.mjs`, `server/urlCache.mjs`)

**Evidence:**

- `test/EndpointsSpec.hs` and `test/UrlSpec.hs`.
- Upstream `endpoints` (14/14) and `url-cache` (9/9).
- `differential` (4/4): `new URL`, `decodeURIComponent` and
  `JSON.parse`/`JSON.stringify` against Node.

**Performance:**

| Clients | Median (C / D) | Per round (C / D) |
| --- | ---: | ---: |
| 1 | 1.07x / 1.07x | ≥ 1.07x / 0.96x |
| 16 | 1.16x / 1.17x | ≥ 1.01x / 0.84x |

Before this work the 16-client median was 0.69–0.91x.

Every round of run C is at or above 1.0x. Run D, under heavier outside
load, has two rounds below it. One round at or above 1.0x every time
cannot be guaranteed on this machine, because the margin is smaller than
the noise:

- With a lean sequential client, a request takes 42.9 µs on Haskell and
  43.5 µs on Node.
- Most of those 43 µs is kernel work both servers pay alike: loopback TCP,
  `open`/`read`/`close` of the file, and the readiness wait.
- That leaves a margin of a few percent per request.
- A single round on the shared machine swings by tens of percent.

The details are in [bench/RESULTS.md](bench/RESULTS.md).

**Status:** at parity: ahead in every median and in every round of the
quieter run.

### `open-file` endpoint (`server/openFileEndpoint.mjs`)

**Evidence:**

- `test/EndpointsSpec.hs`.
- Upstream `endpoints` (14/14).
- `live`: the UI loads `PETRUS_OPEN_FILE` through the endpoint.

**Performance:**

| Clients | Median (C / D) | Per round (C / D) |
| --- | ---: | ---: |
| 1 | 1.00x / 1.10x | 0.79x / 0.97x |
| 16 | 1.10x / 1.00x | 0.77x / 0.58x |

The Haskell server is not reliably ahead. Measured with a lean
sequential client, one request at a time, Haskell's fixed cost per
request is 0.5–2.5 µs (about 3%) above Node's:

| Request | Haskell | Node |
| --- | ---: | ---: |
| `GET` (204) | 17.0 µs | 16.5 µs |
| `POST` | 22.6 µs | 22.1 µs |
| `resolve-ref`, for comparison | 42.9 µs | 43.5 µs |

The `open-file` handlers do almost no work, so that fixed cost decides
the ratio. It comes from Warp's request loop and GHC's I/O manager: one
kqueue registration and one wake-up per wait, where libuv keeps every
socket registered.

At 16 clients the workload also differs between the two servers. All
clients share one pending file, so how many `GET`s actually read the file
depends on how the server interleaves requests.

**Status:** in progress (performance).

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
the pinned UI.

### History replay and live watching (`/temporal`)

**Evidence:**

- `test/ObservationSpec.hs`: the mapping from the observation fixtures in
  `upstream/petrus/spec`.
- `test/HistorySpec.hs`: real producers in the same scenario, a chain Net
  advanced one step at a time.
  - The producers are a Haskell Engine (`petrus-engine` with
    `petrus-observation-http`) and the pinned Python reference
    (`withPython`).
  - Replay: the list, `get_schema` and `get_state` queries.
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

**Performance:** there is no Node counterpart. Upstream proxies
`/temporal` to Temporal and has no observation source.

**Status:** at parity.
