# Divergences from upstream petrus-viewer

Every place where `petrus-viewer-server` behaves differently from the Node
backend of [petrus-viewer](https://github.com/henriquebastos/petrus-viewer)
at the pin in [UPSTREAM.md](../../UPSTREAM.md). Wire formats are unchanged:
the same paths, the same JSON bytes (re-serialized with `JSON.stringify`
semantics), and the same status codes and error messages, except where
listed here.

## Where things run

| Upstream | Haskell | Why |
| --- | --- | --- |
| `bin/petrus.mjs` starts the Vite dev server, which serves the UI from source and adds the backend through Vite plugins. | `petrus` is one server: it serves the **built** UI (`pnpm build` output) from `--ui-dir` / `PETRUS_UI_DIR` (default `./dist` when it holds a build), plus every backend route. | The UI stays TypeScript; there is no reason to run a bundler in production. Without a UI directory, non-API paths answer `404 Petrus UI not configured: …`. |
| The collaboration relay is a separate process (`node server/collab.mjs`, port 4567), proxied by Vite at `/collab-ws` only when Vite runs with `--host`. | The relay runs inside `petrus` at `/collab-ws` (any query string), always on. `petrus-collab [port]` is the standalone equivalent of `server/collab.mjs`. | One process, no port 4567 to collide on. The browser build decides whether to use collaboration (`VITE_COLLAB_ENABLED`), as before. |
| The MCP server's auto-start runs `pnpm run dev` in the viewer checkout. | It runs `petrus --no-open` (the executable next to `petrus-mcp`, else on `PATH`), or `PETRUS_MCP_DEV_COMMAND` through `sh -c`. | There is no viewer checkout to run `pnpm` in. |
| The Vite `ngrokTunnel` plugin (`NGROK=1`). | Not provided. | Tunnelling is an operator concern; run `ngrok http <port>` against `petrus`. |

## Extensions (absent upstream; defaults keep upstream behavior)

- `petrus` flags: `--port <n>` (default 5173, next free port like Vite;
  `0` picks any free port), `--strict-port`, `--host <addr>` (default
  `localhost`: both 127.0.0.1 and ::1), `--ui-dir <dir>`,
  `--temporal-target <url>` (default `http://localhost:7243`, Vite's proxy
  target), `--observation <url>` (repeatable). The upstream `--no-open`,
  `-h/--help`, file and URL arguments are unchanged; unknown dashed
  arguments are still ignored. `--help` prints the upstream text first,
  then the server options.
- Environment: `PETRUS_UI_DIR`, `PETRUS_TEMPORAL_TARGET`,
  `PETRUS_OBSERVATION_URLS` (comma separated), `PETRUS_MCP_DEV_COMMAND`,
  `PETRUS_HISTORY_URL` / `PETRUS_HISTORY_NAMESPACE` (see below), and
  `PETRUS_RELAY_PERF=0`, which turns off the `[petrus-relay-perf]` lines
  the agent relay prints for every petrus-agent request and response
  (always on in Vite).
- GHC runtime options: the executables accept `+RTS … -RTS`. `petrus` and
  `petrus-collab` default to `-N1 -qg -A16m` (one capability, like Node's
  one event loop; the relays run their own event-loop OS threads); see
  [bench/RESULTS.md](bench/RESULTS.md) for why.
- **History from Petrus observation producers.** With `--observation`,
  `/temporal/api/v1/namespaces/{ns}/workflows` and
  `…/workflows/{id}/query/get_state|get_schema` are answered from Petrus
  engines speaking `observation-protocol-v1` (`/v1/snapshot`,
  `/v1/document`) instead of being proxied to Temporal; everything else
  under `/temporal` is still proxied. The unchanged UI then lists, replays,
  and live-watches Petrus instances. See
  `src/Petrus/Viewer/History/Observation.hs` for the mapping.
- **`petrus_trace_import` with server-side history (opt-in).** Upstream the
  tool sends `{source: "temporal", workflowId, runId}` and the browser
  rejects it (`trace.import requires runtimeState payload`) unless a caller
  supplies `runtimeState`. When `PETRUS_HISTORY_URL` is set (for example
  `http://localhost:5173/temporal`, namespace `PETRUS_HISTORY_NAMESPACE`,
  default `default`), `petrus-mcp` first runs the `get_state` query there
  and attaches the decoded `runtimeState`, so the import actually replays.
  If the fetch fails the upstream request is sent unchanged (and the
  failure is logged as `mcp-history-error`). Unset, behavior is upstream's.

## Robustness differences

- **Collaboration relay, non-object JSON.** `server/collab.mjs` assigns
  `msg.peerId` on whatever `JSON.parse` returned; in an ES module that
  throws for `null`, numbers, strings, and booleans, and the uncaught
  exception kills the relay process. The Haskell relay drops such messages
  (arrays are relayed unchanged, as in Node, where the property assignment
  succeeds but is not serialized).
- **Collaboration relay, WebSocket protocol errors.** `server/collab.mjs`
  registers no `error` listener on its sockets, so when `ws` rejects a
  client's frame (an unmasked frame, a reserved bit or opcode, a bad close
  code or reason, invalid UTF-8) the unhandled `error` event kills the
  relay process and every peer loses its connection. The Haskell relays
  answer such a frame as `ws` does (the same close frame, the same close
  code, then the connection is closed) and keep serving the other peers.
  The agent relay's upstream code has the listener, and there the bytes
  are identical (`upstream-tests/ws-wire.test.mjs`).
- **MCP bridge, `null` from the relay.** `server/mcp.mjs` reads `msg.type`
  on the parsed message and crashes on a JSON `null`; `petrus-mcp` ignores
  it.
- **Join ordering.** Node writes a newcomer's `welcome` and count before
  anyone else's count in one event-loop turn. The Haskell relays route each
  event in one STM transaction and keep that order on the wire by holding
  the others' count until the newcomer's greeting is written (bounded at
  250 ms, so a stalled newcomer cannot stall the room).
- **Unknown WebSocket paths.** Upgrades on paths other than `/ws/agent`
  and `/collab-ws…` get `404 Not Found` (Vite would hand them to its HMR
  socket or drop them). Plain HTTP requests to `/collab-ws` get
  `426 Upgrade Required`, like `server/collab.mjs` answers plain HTTP.
- **Static files.** Unknown paths fall back to `index.html` for requests
  that accept HTML (`text/html`, `*/*`, or no `Accept`), like Vite; other
  misses and `..` segments are `404 Not Found`. Files are sent with
  `Cache-Control: no-cache`.
- **`wss://` bridge URLs.** `petrus-mcp` connects to `ws://` relays only;
  a `wss://` `PETRUS_AGENT_URL` fails like an unreachable bridge.
- **Relay timing log.** Vite's relay calls `console.log` inline, before
  forwarding the message. `petrus` measures at the same point and writes
  the line right after the frame is queued, before the relay writes the
  turn's frames to the sockets. Like `console.log`, the write is
  synchronous when standard output is a file or a terminal; when it is a
  pipe or a socket, a background thread writes the lines in batches, in
  order, so a slow reader never stalls the relay (Node writes to pipes
  asynchronously on macOS, synchronously on Linux). There, lines can reach
  stdout a moment after the message was forwarded, and lines still queued
  when the process is killed are lost. The lines are the same (their
  `toISOString` timestamps can differ by microseconds).
- **Response framing.** `/__petrus/open-file` and `/__petrus/resolve-ref`
  answer with Node's bytes: status line, headers in Node's order (the
  handler's, `Date`, `Connection: keep-alive` + `Keep-Alive: timeout=5` or
  `Connection: close`, `Content-Length`), body, `100 Continue` for
  `Expect: 100-continue`, and Node's 5 s idle keep-alive close
  (`upstream-tests/http-wire.test.mjs` compares them byte for byte). The
  exceptions are requests the HTTP front leaves to Warp: chunked bodies,
  malformed or unusual requests, and resolve-ref requests that must fetch
  an `http(s)` URL. Those, and every other route, carry `Content-Length`
  (as Node's `res.end(body)` does) but not Node's `Connection: keep-alive`
  / `Keep-Alive: timeout=5` headers; HTTP/1.1 keep-alive is the default
  either way.
- **Pipelined requests.** `petrus` answers pipelined requests strictly in
  order, each after the previous one's body has been read. Node runs a
  pipelined request's handler as soon as its head is parsed and delivers
  a POST body asynchronously, so a `GET /__petrus/open-file` pipelined
  right behind the `POST` that sets a file may or may not see that file
  under Node; under `petrus` it always does. Answers that do not depend
  on that race are identical.

## Faithfulness limits of the JavaScript emulation

The backend re-implements the parts of V8 and Node it must match byte for
byte (`JSON.parse` error messages, `JSON.stringify`, `Number#toString`,
`new URL(ref, base)`, `decodeURIComponent`). Differential tests run them
against Node on recorded corpora and on thousands of generated inputs
(`upstream-tests/differential.test.mjs`, `test/JsonSpec.hs`,
`test/UrlSpec.hs`). Known, documented gaps:

- **Lone surrogates in `JSON.parse` error messages.** V8 quotes the source
  text in its messages, lone surrogates included; Haskell messages are
  `Text`, so a lone surrogate there becomes U+FFFD. JSON *values* keep lone
  surrogates exactly (strings are held in canonical escaped form).
- **IDNA.** Hosts are lowercased and punycoded but not NFKC-normalized or
  fully UTS #46 mapped: `ß` and `ﬀ` stay as code points and are punycoded
  (Node maps `ﬀ` to `ff`). Only exotic hosts in `$ref`s are affected.
- **ada quirks.** Node 22's URL parser (ada 2.9) differs from the WHATWG
  standard in two places found by the differential tests. A final `..` that
  finds nothing to remove in a non-special empty path leaves the path empty
  — reproduced. A ref containing `#` resolved against an opaque-path base
  (e.g. `mailto:x`) yields odd results where the standard fails — not
  reproduced (the standard's result is used) and excluded from the
  differential test.
