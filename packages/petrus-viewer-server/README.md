# petrus-viewer-server

A Haskell backend for [petrus-viewer](https://github.com/henriquebastos/petrus-viewer),
the visual Petri net editor and simulator (pinned in
[`upstream/petrus-viewer`](../../upstream/petrus-viewer), see
[UPSTREAM.md](../../UPSTREAM.md)). The browser UI stays the upstream
React/TypeScript bundle; everything it talks to is served from Haskell, with
the same paths, wire formats, status codes, and error texts as the Node
backend. Where behavior differs, [DIVERGENCES.md](DIVERGENCES.md) says how
and why.

## Executables

| Executable | Upstream | What it does |
| --- | --- | --- |
| `petrus` | `bin/petrus.mjs` + the Vite dev server's backend plugins | Serves the built UI and every backend route (below), opens the browser, accepts a file or URL argument. |
| `petrus-mcp` | `server/mcp.mjs` | MCP stdio server: the 16 `petrus_*` tools with the upstream schemas and results, bridge URL resolution (`PETRUS_AGENT_URL`, else the upstream default URLs), auto-start of `petrus` when no bridge answers. |
| `petrus-collab` | `server/collab.mjs` | Standalone collaboration relay (`petrus-collab [port]`, default 4567). |
| `petrus-viewer-oracle` | none | Test helper: the upstream Node tests and differential fuzzing call the Haskell JSON/URL ports through it. |

Routes served by `petrus`:

| Route | Upstream source | Notes |
| --- | --- | --- |
| `GET/POST/OPTIONS /__petrus/open-file` | `server/openFileEndpoint.mjs` | Pending file, consumed once by the UI. |
| `POST/OPTIONS /__petrus/resolve-ref` | `server/openFileEndpoint.mjs` | `$ref` resolution: local files, and http(s) refs fetched and cached with the GitHub URL normalization (`raw.githubusercontent.com`, `blob/` URLs) of `server/urlCache.mjs`. |
| `/ws/agent` (WebSocket) | `agentRelay` Vite plugin | Browser ↔ agents relay, `[petrus-relay-perf]` timing log. |
| `/collab-ws` (WebSocket) | `server/collab.mjs` behind Vite's proxy | Collaboration relay, in process. |
| `/temporal/*` | Vite proxy to `localhost:7243` | Reverse proxy to the Temporal HTTP API; optionally answered from Petrus observation producers (below). |
| everything else | Vite static serving | The built UI (`--ui-dir`), with SPA fallback to `index.html`. |

## Running

```bash
# once: build the upstream UI
(cd upstream/petrus-viewer && pnpm install && pnpm build)

cabal build petrus-viewer-server:exes
cabal run petrus -- --ui-dir upstream/petrus-viewer/dist upstream/petrus-viewer/examples/sample-net.json

# an MCP client (Claude Code, ...) runs petrus-mcp over stdio:
#   command: $(cabal list-bin petrus-mcp)
#   env:     PETRUS_AGENT_URL=ws://localhost:5173/ws/agent   (optional)
```

`petrus --help` lists the options. The upstream ones (`--no-open`, `-h`,
file and URL arguments, `PETRUS_OPEN_FILE`, `PETRUS_SOURCE_URL`) behave as
upstream. Server options: `--port` (default 5173, next free port like Vite),
`--strict-port`, `--host` (default `localhost`), `--ui-dir` /
`PETRUS_UI_DIR` (default: `./dist` when it holds a build, else a build next
to the executable: `<prefix>/share/petrus-viewer/ui` for executables in
`<prefix>/bin`, or `upstream/petrus-viewer/dist` in the checkout they were
built in), `--temporal-target` / `PETRUS_TEMPORAL_TARGET`,
`--observation` / `PETRUS_OBSERVATION_URLS`. `PETRUS_RELAY_PERF=0` turns the
relay timing log off (it is on, as in Vite). `petrus-mcp` reads the upstream
variables (`PETRUS_AGENT_URL`, `PETRUS_PERF`,
`PETRUS_MCP_REQUEST_TIMEOUT_MS`, `PETRUS_MCP_BRIDGE_WAIT_MS`) plus `PETRUS_MCP_DEV_COMMAND`,
`PETRUS_HISTORY_URL`, and `PETRUS_HISTORY_NAMESPACE`. When no bridge answers,
`petrus-mcp` starts `petrus --no-open` with the UI found the same way
(`PETRUS_UI_DIR`, else next to `petrus-mcp` or `petrus`, passed as
`--ui-dir`), so the auto-started server serves the UI whatever the MCP
client's working directory is.

## Simulation and history replay

What each depends on (upstream pin):

- **Simulation** runs in the browser (`src/store/domain/runtime`). The
  backend's part is the agent relay: `petrus_simulation_command`,
  `petrus_scenario_save/compare`, and `petrus_inspect_simulation` are
  relayed to the UI and answered there. Nothing else is needed.
- **History replay and live watching** load a `RuntimeState` either from a
  file (browser only) or from the Temporal HTTP API at `/temporal`: list
  workflows, then the `get_schema` and `get_state` queries, polled every two
  seconds while live. `petrus` proxies `/temporal` to a Temporal server like
  Vite does, and can instead answer it from **Petrus observation producers**
  (`--observation http://host:port`, `observation-protocol-v1`:
  `GET /v1/snapshot` and `GET /v1/document`), mapping each observed instance
  to one workflow (`src/Petrus/Viewer/History/Observation.hs`). The
  unchanged UI then replays and watches Petrus instances.
- **`petrus_trace_import`** sends `{source: "temporal", workflowId}` and the
  browser rejects it without a `runtimeState`. With `PETRUS_HISTORY_URL`
  (e.g. `http://localhost:5173/temporal`), `petrus-mcp` fetches `get_state`
  first and attaches it, so the import replays.

Runtime needs and seams for work done elsewhere:

- Observation producers: any server speaking `observation-protocol-v1`:
  a Haskell Engine served by `petrus-observation-http`, or the Python
  reference. Only `/v1/snapshot` and `/v1/document` are used; no producer
  code is linked into the executables. The tests run both producers in the
  same scenario (a chain Net advanced one step at a time) and check that
  the viewer gives the same answers for both: `test/HistorySpec.hs` over
  HTTP, and the `history` browser suite through the UI's Connect dialog,
  Load State, Watch Live, and `petrus_trace_import`.
- `simulation-http-v1` (`POST /v1/simulations`, a Net document per run,
  ported in `petrus-simulation`) is not consumed by the pinned UI, which
  simulates locally: upstream petrus-viewer has no simulation-service
  path to port. (Its consumer upstream is plausibly Arx, the private
  editor and inspector SCOPE.md lists as out of scope.) Its result is a
  Net document with `simulated` Timeline entries, i.e. the same shape
  `documentToRuntimeState` already maps; serving server-side simulations to
  the UI needs only a route that posts the scenario and returns the mapped
  `RuntimeState` (the seam is `Petrus.Viewer.History.Observation`).

## Tests

```bash
cabal test petrus-viewer-server     # hspec: ports of the upstream server tests + properties
node packages/petrus-viewer-server/upstream-tests/run.mjs   # upstream Node + Playwright tests against Haskell
```

`upstream-tests/run.mjs` copies the pinned upstream test files, rewrites
only how they start the backend (the imports of the in-process Node servers
and the spawns of `server/mcp.mjs`, `bin/petrus.mjs`, and `vite`; each
rewrite must match the upstream text exactly), and runs them with
`node --test`: `relay`, `endpoints`, `url-cache`, `cli`, `mcp`,
`mcp-haskell-relay`, `mcp-node-haskell-relay` (the upstream Node MCP
server on the Haskell relay), `collab`, `protocol` (the upstream agent-protocol
tests, TypeScript run through Node's type stripping, with
`parseAgentMessage` answered by the Haskell parser), `differential`
(Haskell JSON/URL ports against V8 on recorded and generated inputs), `wire` (every byte of the
WebSocket handshakes, frames and closes against the `ws` relays),
`playwright` (the upstream browser suite), `live` (every MCP tool through
`petrus-mcp`, `petrus`, and a headless browser, plus observation-backed
replay), and `history` (replay and live watching in the browser from a
Haskell Engine and the Python reference). It needs `pnpm install` and
`pnpm build` in `upstream/petrus-viewer`, `npx playwright install
chromium`, and, for `history`, the pinned Python reference
(`scripts/upstream-python`). `--bin-dir DIR` uses prebuilt executables
(including `petrus-viewer-server-test`, which doubles as the Haskell
producer); `--skip-playwright` skips the browser suites.

The `live` suite raises `PETRUS_MCP_REQUEST_TIMEOUT_MS` to 30 s: the
browser's `canvas.screenshot` (html-to-image) fetches the Monaco
stylesheet from cdn.jsdelivr.net, which can take longer than the default
5 s; the relay forwards the browser's answer as soon as it arrives.

## Benchmarks

`bench/run.mjs` drives the Haskell and Node backends with the same load
client (`petrus-viewer-bench`); results and commands are in
[bench/RESULTS.md](bench/RESULTS.md).

## Module map

| Module | Upstream |
| --- | --- |
| `Petrus.Viewer.Cli` | `bin/petrus.mjs` (argument handling, URL detection, browser opening) |
| `Petrus.Viewer.Server`, `Static`, `Proxy`, `Http` | Vite dev server: listeners, static UI, `/temporal` proxy |
| `Petrus.Viewer.Relay`, `Relay.Frame`, `Relay.Handshake` | `agentRelay` plugin and `server/collab.mjs` on `ws` 8 (handshake, RFC 6455 framing, close codes) |
| `Petrus.Viewer.HttpFront` | Node's `http` server for the two endpoints below (one event loop, Node's response framing); everything else goes to Warp |
| `Petrus.Viewer.Endpoints`, `FileIO` | `server/openFileEndpoint.mjs` |
| `Petrus.Viewer.UrlCache` | `server/urlCache.mjs` |
| `Petrus.Viewer.Mcp.Server`, `Schema`, `Bridge`, `History` | `server/mcp.mjs` |
| `Petrus.Viewer.EventLoop`, `Mcp.Reactor` | Node's event loop: one thread on kqueue/epoll (`cbits/relay_io.c`) for the relays, the HTTP front, and `petrus-mcp`'s stdin and bridge socket |
| `Petrus.Viewer.Agent.Protocol` | `src/agent/protocol.ts` (the typed petrus-agent envelope) |
| `Petrus.Viewer.History.Observation` | none: Temporal history API from observation producers |
| `Petrus.Viewer.Json`, `Json.Number` | V8 `JSON.parse` / `JSON.stringify` / `Number#toString` |
| `Petrus.Viewer.Json.Canonical` | none: recognizes text already in `JSON.stringify` form, so the relays can splice the sender id into the bytes instead of re-serializing |
| `Petrus.Viewer.Url`, `WsUrl` | WHATWG `URL` (Node's ada), `decodeURIComponent`, `ws` URL handling |
| `Petrus.Viewer.Log` | `console.log` timing lines (`toISOString`, `toFixed(1)`) |

## License

Apache-2.0. Portions are derived from petrus-viewer (MIT); see
[NOTICE](NOTICE).
