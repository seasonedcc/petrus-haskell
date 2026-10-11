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

## Out of scope

| Upstream | Why |
| --- | --- |
| `petrus-site`, `hamsterdan-site`, `henriquebastos.net` | Websites; explicitly excluded. |
| `beans` | A graph issue tracker for agent coordination; not part of Petrus. |
| `orbital` | Remote workspaces for the Pi coding agent; not a Petrus dependency. |
| `ariad` | A development method, not software Petrus runs. |
| `CarlAdam` | An earlier, unrelated Petri net library (2024); Petrus does not depend on it. |
| Every other `henriquebastos` repository | Not Petri-net or Petrus related. |
| `hamsterdan`'s `src/hamsterdan2` at the pinned commit | An in-progress rebuild of the outer system (CV21) that production does not run: it has no entry point and no effects (see [docs/hamsterdan.md](docs/hamsterdan.md) §1.11). The goal is to behave like production Hamsterdan. When upstream cuts over to it (CV22), moving the `hamsterdan` pin brings it into scope. |

## External systems

The port interoperates with, but does not reimplement, external systems the
upstream relies on: PostgreSQL, SQLite, the Absurd durable-execution schema,
ZeroMQ, GitHub's APIs, and the third-party agent
runtimes `agenticus` drives (Claude, Codex, Pi, Amp). Where upstream embeds a
non-Python helper (for example the Gondolin sidecar), the port keeps using it
over the same protocol.
