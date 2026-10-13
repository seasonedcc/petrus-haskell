# Scope

This repository ports the Petrus ecosystem by Henrique Bastos to Haskell. This
file records which upstream projects are in scope, which are not, and why.
Exact upstream commits are pinned in [UPSTREAM.md](UPSTREAM.md); per-component
status lives in [PARITY.md](PARITY.md).

## In scope

| Upstream | What the port covers | Why |
| --- | --- | --- |
| [henriquebastos/petrus](https://github.com/henriquebastos/petrus) | The whole runtime: `impetus` (Petri net kernel, history, stores, instance, net definition and net document formats, observation, DSL), engine backends (SQLite, Postgres, Absurd), `motus` (Activities, dispatch, execution, Workers, transports), simulation and its HTTP service, observation HTTP, `testing` (deterministic simulation testing), `agenticus`, telemetry, `fabric`, and `processes`. | It is Petrus. |
| [henriquebastos/hamsterdan](https://github.com/henriquebastos/hamsterdan) | The application: GitHub App ingress, readiness nets, host, agents, operator surfaces. Deployment tooling (Ansible, Orb setup) is ported only where Hamsterdan's runtime behavior depends on it. | The production Petrus application; the end-to-end acceptance target. |
| [henriquebastos/petrus-viewer](https://github.com/henriquebastos/petrus-viewer) | Every non-UI capability, served by Haskell: the `petrus` CLI, the MCP server, the agent WebSocket protocol, the collaboration relay, file/URL endpoints, simulation, and history replay. | Petrus's visual editor and agent interface. The browser UI (React/TypeScript) stays as is: it is presentation, and a Haskell rewrite of it would add risk without improving Petrus. |
| [henriquebastos/petrus-engine](https://github.com/henriquebastos/petrus-engine) | Loading net files in its `fileVersion: "2"` format (the viewer's file format). | Existing nets authored in the viewer must keep loading. The rest of petrus-engine is the predecessor of the `petrus` runtime and is superseded by it. |

## Beyond the port

Tools with no upstream twin, built on the port and run against any Petrus net, from Haskell or
Python, through its Net-definition v3 or Net document v1:

| Package | What it does | Why |
| --- | --- | --- |
| `petrus-net-lint` | Finds the signs of a net whose marking collapsed into one token, in a net's structure and its author's declared outcomes ([README](packages/petrus-net-lint/README.md)). | A net whose state hides inside one token shows nothing a tool can check: what runs at the same time, what waits on what, what is scarce. |

## Out of scope

| Upstream | Why |
| --- | --- |
| `petrus-site`, `hamsterdan-site`, `henriquebastos.net` | Websites; explicitly excluded. |
| `beans` | A graph issue tracker for agent coordination; not part of Petrus. |
| `orbital` | Remote workspaces for the Pi coding agent; not a Petrus dependency. |
| `ariad` (a fork of `mirror-mind-ai/ariad`) | A development method, not software Petrus runs. Upstream Petrus vendors its `using-ariad` agent skill as development tooling only (`upstream/petrus/THIRD_PARTY_NOTICES.md`). |
| `CarlAdam` (a fork of `matthewryanscott/CarlAdam`) | An earlier, unrelated Petri net library (2024); Petrus does not depend on it. |
| `petrus-arx` (Arx) | Petrus's separately maintained editor and inspector (upstream `README.md`: "Arx is a separately maintained editor and inspector that consumes Petrus protocols"; `spec/net-definition-v3.md` names it the other side of the v3 conformance seam). The repository is private and inaccessible (`henriquebastos/petrus-arx` answers 404), so it can be neither pinned nor ported. It consumes Petrus protocols (net definition v3, observation-protocol-v1 and, plausibly, simulation-http-v1), which the Haskell producers implement and test against the pinned Python and the shared spec fixtures; interop with Arx itself is untested. |
| Every other `henriquebastos` repository | Not Petri-net or Petrus related. |
| `petrus-viewer`'s ngrok tunnel (`NGROK=1`, `pnpm dev:ngrok`) | A developer convenience in `vite.config.ts` that spawns the external `ngrok` CLI against the dev server; it is not part of the viewer's backend contract. `ngrok http <port>` against `petrus` does the same. |
| `hamsterdan`'s `src/hamsterdan2` at the pinned commit | An in-progress rebuild of the outer system (CV21) that production does not run: it has no entry point and no effects (see [docs/hamsterdan.md](docs/hamsterdan.md) §1.11). The goal is to behave like production Hamsterdan. When upstream cuts over to it (CV22), moving the `hamsterdan` pin brings it into scope. |

## External systems

The port interoperates with, but does not reimplement, external systems the
upstream relies on: PostgreSQL, SQLite, the Absurd durable-execution schema,
ZeroMQ, GitHub's APIs, and the third-party agent
runtimes `agenticus` drives (Claude, Codex, Pi, Amp). Where upstream embeds a
non-Python helper (for example the Gondolin sidecar), the port keeps using it
over the same protocol.
