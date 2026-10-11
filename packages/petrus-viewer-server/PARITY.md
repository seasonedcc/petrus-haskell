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
cabal test petrus-viewer-server                               # 99 examples
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
| `collab` | `tests/collab-server.test.mjs` | 6/6 |
| `protocol` | `tests/agentProtocol.test.ts`, `tests/agentParseRegression.test.ts`, with `parseAgentMessage` answered by `Agent.Protocol` through `petrus-viewer-oracle` | 19/19 |
| `differential` | ours: JSON and URL ports against V8 and Node | 4/4 |
| `wire` | ours: WebSocket bytes against the `ws` relays, and HTTP endpoint bytes against `node:http` | 20/20 |
| `playwright` | `tests/playwright/bridge-live.test.mjs` | 4/4 |
| `live` | ours: every MCP tool through a headless browser | 12/12 |
| `history` | ours: replay and live watching in the browser from real producers | 8/8 |

## Capabilities

The ratios below come from [bench/RESULTS.md](bench/RESULTS.md), on a
machine shared with other agents:

- run F: the final code, every scenario, 15 interleaved rounds;
- run E: the HTTP endpoints only, 15 interleaved rounds, with the previous
  server (Warp) running in the same rounds;
- runs C and D: the relays before the HTTP front, 7 rounds each.

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
- `live` (12/12).

**Performance**, against the Node relay on bare `ws` (Node's fastest
case), both without the timing log:

| Round trip | Median (C / D / F) | Per round (C / D / F) |
| --- | ---: | ---: |
| 1 pair | 1.41x / 1.40x / 1.32x | ≥ 1.09x / ≥ 1.23x / ≥ 1.01x |
| 16 pairs | 1.17x / 1.31x / 1.09x | ≥ 1.07x / ≥ 1.07x / ≥ 1.02x |

Before this work the 16-pair round trip was 0.81–0.98x. With the timing
log on, `petrus` is 1.35x the Vite relay that `bin/petrus.mjs` runs
(1 pair, run F).

**Status:** at parity.

### Collaboration relay (`server/collab.mjs`)

**Evidence:**

- `test/CollabSpec.hs` (6 examples).
- Upstream `collab` (6/6).
- `wire` (`ws-wire.test.mjs`, 2/2): every byte against `server/collab.mjs`.

**Performance:** fan-out to 50 or 200 peers is 3.9–4.5x Node by median
(runs C, D and F), and at least 3.21x in every round.

**Status:** at parity. Unlike upstream, the Haskell relay keeps running
after a WebSocket protocol error (see [DIVERGENCES.md](DIVERGENCES.md)).

### `resolve-ref` endpoint (`server/openFileEndpoint.mjs`, `server/urlCache.mjs`)

**Evidence:**

- `test/EndpointsSpec.hs` and `test/UrlSpec.hs`.
- Upstream `endpoints` (14/14) and `url-cache` (9/9).
- `differential` (4/4): `new URL`, `decodeURIComponent` and
  `JSON.parse`/`JSON.stringify` against Node.
- `wire` (`http-wire.test.mjs`): raw requests to `petrus` and to the
  upstream endpoint on bare `node:http` give the same bytes (only the
  `Date` value masked). That covers the status line, headers in order and
  body, local files and every refusal, `Connection: close`, HTTP/1.0,
  split and pipelined requests, `Expect: 100-continue`, and a 400-request
  pipelined burst read slowly.

**Performance:**

| Clients | Median (E / F) | Per round (E / F) |
| --- | ---: | ---: |
| 1 | 1.17x / 1.16x | ≥ 0.83x / ≥ 1.01x |
| 16 | 1.31x / 1.37x | ≥ 1.07x / ≥ 1.06x |

Before the HTTP front, run D had 1.07x and 1.17x by median, with rounds
at 0.96x and 0.84x. In run E the previous server ran in the same rounds:
1.08x and 1.16x. With the lean C client, 16 threads get 33.7k req/s
(Node 21.9k, the previous server 24.5k). The one round below 1.0x
(0.83x, run E, 1 client) is explained under the open-file endpoint.

**Status:** at parity: ahead in every median, and at or above 1.0x in
every round of run F.

### `open-file` endpoint (`server/openFileEndpoint.mjs`)

**Evidence:**

- `test/EndpointsSpec.hs`, and `test/ServerSpec.hs` (the HTTP front hands
  a connection to Warp mid-stream, and closes idle connections after
  Node's 5 s).
- Upstream `endpoints` (14/14).
- `wire` (`http-wire.test.mjs`): the bytes of `GET` 204 and 200, `POST`
  and its refusals, `OPTIONS`, 405 and `HEAD`, and a pending file that
  cannot be read (500, and it stays pending) are identical to Node's, as
  for resolve-ref above.
- `live`: the UI loads `PETRUS_OPEN_FILE` through the endpoint.

**Performance:**

| Clients | Median (E / F) | Per round (E / F) |
| --- | ---: | ---: |
| 1 | 1.14x / 1.20x | ≥ 0.66x / ≥ 0.78x |
| 16, in lockstep | 1.39x / 1.54x | ≥ 0.94x / ≥ 0.97x |

Before the HTTP front, run D had 1.10x and 1.00x by median, with rounds
down to 0.97x and 0.58x. In run E the previous server ran in the same
rounds: 1.03x and 1.12x.

What changed:

- **The HTTP front.** Both endpoints are served by one event-loop
  thread that keeps every socket registered with kqueue/epoll and writes
  each answer with one `writev`. Before, Warp paid a thread wake-up and a
  one-shot I/O-manager registration on every wait. With the lean C
  client, a `GET` that answers 204 takes 11.7 µs (Node about 19 µs, the
  previous server 18.8 µs). Any other request, or a request the front
  does not parse conservatively, hands the connection to Warp.
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

The rounds below 1.0x are 1-client rounds and two 16-client rounds at
0.94x and 0.97x. A 1-client run has one request in flight, so it runs at
the speed of the cores the scheduler gives the server and the client for
that second. The machine has 4 performance and 6 efficiency cores, and
other agents kept the load at 5–9. In the low rounds, servers fall to
about half speed together: in run E's 0.66x round, three of the four
servers ran at 7.4–7.8k ops/s against 11–15k elsewhere. Within run F, the
same server's 1-client runs range over 9.2–16.9k (`petrus`) and
5.6–14.4k (Node bare). The details are in
[bench/RESULTS.md](bench/RESULTS.md).

**Status:** at parity: ahead in every median of runs E and F. The
remaining low rounds are 1-client rounds in which the machine slowed the
servers together.

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

**Performance:** there is no Node counterpart. Upstream proxies
`/temporal` to Temporal and has no observation source.

**Status:** at parity.
