# hamsterdan-host parity

This file lists what this package ports from `upstream/hamsterdan` (pinned in
[UPSTREAM.md](../../UPSTREAM.md) at `5d382467`) and the evidence for each
piece.

The reference is:

- `upstream/hamsterdan/.venv`
- Python 3.14.6
- pydantic 2.13.4

Tests find it through `upstreamPythonExecutable "hamsterdan"` from
petrus-test-support, and run it with `python -I -B`. A test that needs the
reference fails when the reference is missing. It is never skipped.

## Upstream source → Haskell

| Upstream | Haskell | Evidence |
| --- | --- | --- |
| `host/service.py` (custody, pump, sweep, scheduler, lifecycle) | `Hamsterdan.Host.Service` | `ServiceSpec` and the interop tests below. |
| `host/api.py` (FastAPI, served by uvicorn) | `Hamsterdan.Host.Api` (WAI, served by warp), `Hamsterdan.Host.Api.Documents`; uvicorn's logging, proxy headers middleware and binding in `Hamsterdan.Host.Uvicorn` (`Hamsterdan.Host.Uvicorn.IpAddress`: CPython's `ipaddress`) | `ApiSpec`. The surface test compares every response with the reference served by uvicorn, byte for byte except the `date` value. `UvicornSpec`, and `CliSpec`'s serve comparisons for the log. |
| `host/binding.py` | `Hamsterdan.Host.Binding` (in hamsterdan-agents, which the Pi A2 installation binding needs) | `BindingSpec`, plus the interop tests (`binding.json`). |
| `host/runnable.py` | `Hamsterdan.Host.Runnable` | `RunnableSpec`, plus the interop tests (`runnable.sqlite3`). |
| `host/protocol.py` (`ReadinessApplication`, `DurableActivityResolver`) | `Hamsterdan.Host.Service.HostApplication` (the protocol as a record of operations; `hostApplication` wraps the V5 application in it), `Hamsterdan.Host.V5.Runtime.DurableActivityResolver` | Every `ServiceSpec` case runs the host through this record, over the real V5 application and over the test doubles upstream's `test_service.py` passes as `ReadinessApplication`s; the resolver by `ServiceSpec`'s `test_scoped_resolver_*` and `test_durable_activity_resolver_*` cases. |
| `host/v5/runtime.py` | `Hamsterdan.Host.V5.Runtime` | `IngressApplicationSpec`, `ServiceSpec`, interop. |
| `host/v5/application.py` | `Hamsterdan.Host.V5.Application` | `IngressApplicationSpec`, `ServiceSpec`, interop. |
| `host/v5/ingress.py` | `Hamsterdan.Host.V5.Ingress` | `IngressSpec`, `IngressApplicationSpec`, interop. |
| `host/v5/claim.py` | `Hamsterdan.Host.V5.Claim` | `GatesSpec`, `ReviewSpec`, `MutationSpec`. |
| `host/v5/gates.py` | `Hamsterdan.Host.V5.Gates` | `GatesSpec`, `InlineRecoverySpec`. |
| `host/v5/rerun.py` | `Hamsterdan.Host.V5.Rerun` | `RerunSpec`, `InlineRecoverySpec`. |
| `host/v5/review.py` | `Hamsterdan.Host.V5.Review` | `ReviewSpec`, `InlineRecoverySpec`, interop (review requests). |
| `host/v5/mutation.py` | `Hamsterdan.Host.V5.Mutation` | `MutationSpec`. Its `reference_bytes` cases check the ref and payload digests against Python. |
| `host/v5/timers.py` | `Hamsterdan.Host.V5.Timers` | `TimersSpec`, plus the interop tests (`timers.sqlite3`). |
| `host/git_publish.py` | `Hamsterdan.Host.GitPublish` | `GitPublishSpec`, over real Git and local remotes. |
| `host/__main__.py` (`serve`, `validate`, `inbox`, `requeue`, `inspect-instance`) | `Hamsterdan.Host.Cli`, `app/Main.hs` (`hamsterdan-host`) | `CliSpec`, including a 105-case differential run against the reference. |
| `host/__main__.py` (the agent half of `main()`) | `Hamsterdan.Host.Agents` (`composeHostAgent`), over hamsterdan-agents | `CliSpec` (Pi configuration refusals; `serve` end to end), `InteropSpec` (agent state), `PiActivitySpec`. |

The package reuses hamsterdan-contracts, hamsterdan-github, hamsterdan-readiness
(the net, `wireGates`, `encodeVariant`), petrus-impetus (Engine, JSONL
History, Inline and Local Dispatch, the Worker), petrus-json and
petrus-posix, and hamsterdan-agents for the agent. `serve` composes the
agent as `main()` does: the Pi A2 installation from the environment,
`agent-routes.sqlite3` and its repair, the workspace receiver, the owned Pi
A2 runtime, and the Pi runner after an exact READY probe.

## Upstream tests

- **Cases:** collected pytest items, so each parametrization counts.
- **Examples:** hspec examples. A parametrized test is one `describe`
  named after the test, with one example per parameter, so the two counts
  line up.

| Upstream file | Functions | Cases | Haskell spec | Examples |
| --- | ---: | ---: | --- | ---: |
| `tests/unit/host/test_host_architecture.py` | 1 | 1 | `ArchitectureSpec` | 1 |
| `tests/unit/host/test_binding.py` | 5 | 8 | `BindingSpec` | 8 |
| `tests/unit/host/test_runnable.py` | 7 | 11 | `RunnableSpec` | 11 |
| `tests/unit/host/test_v5_gates.py` | 50 | 55 | `GatesSpec` | 55 |
| `tests/unit/host/test_v5_ingress.py` | 63 | 82 | `IngressSpec` (store and normalizer, 29), `IngressApplicationSpec` (application, 53) | 82 |
| `tests/unit/host/test_v5_mutation.py` | 15 | 41 | `MutationSpec` | 41 (+3 `reference_bytes`) |
| `tests/unit/host/test_v5_rerun.py` | 13 | 17 | `RerunSpec` | 17 |
| `tests/unit/host/test_v5_review.py` | 14 | 22 | `ReviewSpec` | 22 |
| `tests/unit/host/test_v5_timers.py` | 18 | 21 | `TimersSpec` | 21 (+1 fresh-store bytes) |
| `tests/integration/host/test_git_publish.py` | 18 | 30 | `GitPublishSpec` | 30 |
| `tests/integration/host/test_service.py` | 64 | 70 | `ServiceSpec` (59), `ApiSpec` (FastAPI, 6), `CliSpec` (4) | 69 |
| **Total ported** | **268** | **358** | | **357** (+4) |

`PiActivitySpec` runs the nine coding-activity cases of
`tests/unit/agents/test_pi.py`, because they drive the V5 mutation gate.
hamsterdan-agents' [PARITY.md](../hamsterdan-agents/PARITY.md) counts them
with the rest of that file.

The one `test_service.py` case not ported is
`test_host_service_requires_agent_route_custody`. It checks that
`HostService(config, runner=...)` without `agent_composition` raises
`TypeError`. In Haskell, `serviceOptions` takes the agent custody as an
argument, so that call does not compile.

### Differential and interop suites (no upstream counterpart)

| Spec | Examples | What it checks |
| --- | ---: | --- |
| `InteropSpec`: "resumes each other's state" | 1 | Phase one is a webhook to quiescence. Phase two is a new head, a second synchronize, a `workflow_run`, then startup and periodic sweeps, each to quiescence. The test runs phase one on one host and phase two on the other, in all three pairings: Haskell/Haskell, Python/Haskell and Haskell/Python. Each pairing must match the Python-only run file by file. That covers every file under the state root (`differential/state_reference.py` dumps them): `webhooks.sqlite3` (the inbox and the V5 ingress tables), `routes.sqlite3`, `runnable.sqlite3` and `activity-dispatch.sqlite3`; and, for each Instance, `binding.json`, `history.jsonl`, `review-requests.sqlite3` and `timers.sqlite3`. For each SQLite file it compares the schema text and every row. It also compares the command outputs (`inspect-instance`, status, counts) and the provider calls. Run identifiers, instants and epochs are normalized. |
| `InteropSpec`: "makes the same GitHub requests as the reference" | 1 | The same two phases, with both hosts' real client stacks (JWT, installation token, REST, GraphQL) pointed at one recording fake GitHub. The tests compare the request line, the headers in order, and the body bytes of every request, plus the outputs, the state dump and the resulting PR comments. |
| `InteropSpec`: "resumes each other's agent state" | 1 | A journey through `serve`'s composed agent on both hosts, over Petrus's scripted Pi runtime and a repository with fixed commits. Phase one reviews the first head (epoch 1); phase two moves the head and reviews again (epoch 2). The test runs phase one on one host and phase two on the other, in all four pairings, and each must match the Python-only run file by file. That includes `agent-routes.sqlite3`, `pi-a2/installation`, and the runtime host's `operations.sqlite3` and `bodies.sqlite3`. It also compares the provider calls, the reviews and the dashboard. |
| `ApiSpec`: "the HTTP surface against the reference (uvicorn)" | 1 | 47 requests, sent over a raw socket to the reference under uvicorn and to the port under warp. They cover health, the FastAPI pages, routing fallbacks (405 with `allow`, 307, 404, the 307's scheme from a trusted `X-Forwarded-Proto`), percent-encoding, HTTP/1.0, pipelining, and webhook accept, duplicate and refusals. The status line (h11's `HTTP/1.1`, also for HTTP/1.0), every header in order (only the `date` value is blanked), and the body bytes must match. |
| `CliSpec`: "serve (uvicorn.run)" | 2 | `serve` on a free port, with the composed agent: an HTTP/1.0 health check gets `HTTP/1.1 200 OK` and `Connection: close`, and `agent-routes.sqlite3` and `pi-a2/installation` exist. Stopped by `SIGTERM`, the command raises it again after the graceful shutdown (uvicorn's `capture_signals`; the reference process ends by SIGTERM, status -15, without its `finally`). As PID 1 of a container, which the kernel exempts from a signal's default action, the process survives that SIGTERM: `uvicorn.run` returns, the `finally` runs, and both end with status 0 ([scripts/container-smoke](../../scripts/container-smoke) checks it under `docker stop`). Stopped by `SIGINT`, it ends with status 0 (the re-raised SIGINT meets `asyncio.run`'s handler). Found by the tier C host rehearsal (`packages/hamsterdan-e2e`, `rehearse_hosts.py`), which checks both statuses against the reference process. |
| `CliSpec`: "serve against the reference (uvicorn's log lines)" | 4 | `python -m hamsterdan.host serve` (`differential/serve_reference.py`, the real uvicorn) and the port's `serve`, each with stdout and stderr to files and the same `FORWARDED_ALLOW_IPS`. Fourteen requests (methods, HTTP/1.0, redirects, a refused webhook, quoting of the logged path, trusted `X-Forwarded-For` / `X-Forwarded-Proto`) then SIGTERM; an occupied port; a route that raises (the inbox table renamed away under `/healthz`); a GitHub that knows no App, so the lifespan's startup fails. Both logs must match line for line, with the pid and ports blanked and each traceback cut to its header and last line, and so must the exit status. |
| `UvicornSpec` | 1 | One live run of the pinned uvicorn and CPython: `ipaddress` parsing of 600 generated and curated strings, `_parse_host_port`, `_TrustedHosts` membership, `get_trusted_client_address`, `HTTPStatus` phrases 0–999, the default and access formatters with and without color, the server messages, and `get_path_with_query_string`. |
| `CliSpec`: "the command line against the reference" | 1 | 114 cases through `python -m hamsterdan.host`'s `main()` and through the port. They cover argparse parsing, usage and help at nine `COLUMNS` widths and under `FORCE_COLOR` / `NO_COLOR` / `TERM=dumb`, configuration failures, `inspect-instance` over hostile histories, startup refusals, `inbox`/`requeue` against a parked delivery, the Pi configuration refusals of the agent composition, and `validate` against a recording fake GitHub. Both sides compose the real agent over an installed-package fixture. Each case must give the same stdout, stderr, exit status, state effects and GitHub requests. |
| `InlineRecoverySpec` | 5 | The five restart-convergence cases of `tests/unit/readiness/net_v5/test_inline_recovery.py`, against the real host gates. This closes the gap that hamsterdan-readiness's PARITY.md recorded. |
| `MutationSpec`: `reference_bytes` | 3 | The mutation ref and payload digest match Python for `change`, `repair` and `update_base`. |

The full suite has 392 examples:

- 357 port upstream cases of this package's scope;
- 9 port the coding-activity cases of `test_pi.py` (`PiActivitySpec`);
- 3 are `reference_bytes`;
- 5 are inline recovery;
- 10 are differential and interop tests (the table above);
- 1 is the architecture test, 2 run `serve` end to end, 3 check
  `exceptionClass` against the reference's classes, and 2 check lone
  surrogate escapes in a webhook payload.

## Not ported here

These upstream host tests exercise code that belongs to other packages of
`docs/hamsterdan.md` §6. That code is not part of this package's upstream
scope.

| Upstream file | Cases | Belongs to |
| --- | ---: | --- |
| `tests/unit/host/test_agenticus.py` | 33 | `hamsterdan-agents` (5): `host/agenticus.py`, ported there |
| `tests/unit/host/test_pi_a2.py` | 24 | `hamsterdan-agents` (5): `host/pi_a2.py`, ported there |
| `tests/integration/host/test_pi_a2_factory.py` | 8 | `hamsterdan-agents` (5), ported there |
| `tests/integration/host/test_pi_workspace.py` | 20 | `hamsterdan-agents` (5): `host/pi_workspace.py`, ported there |
| `tests/unit/host/test_export.py` | 41 | `hamsterdan-export` (7): `host/export.py` |
| `tests/unit/host/test_publication_qualification.py` | 52 | `hamsterdan-operator` (8): `host/publication_qualification.py` |
| `tests/unit/host/test_secret_launch.py` | 10 | `hamsterdan-operator` (8): `operator.py` |
| `tests/integration/host/test_qualification_setup_local.py` | 7 | `hamsterdan-operator` (8) |
| `tests/integration/host/test_readiness_scenarios.py` | 11 | `hamsterdan-testing` (6): the 11 journeys, ported there over this host |

The upstream counts are:

- 180 cases in the non-V5 files of `tests/unit/host`;
- 238 cases in its `test_v5_*` files;
- 146 cases in `tests/integration/host`.

Of these 564 cases, 358 belong to this package's scope and 357 are ported.
The other 206 are listed above.

## On-disk interop

Every file under the state root is byte-compatible in both directions.
`InteropSpec` proves it by resuming in both directions.

- **Fixes the interop tests found.** Eleven tables were created with DDL
  text that differed from upstream. SQLite stores that text in
  `sqlite_master`. The DDL is now the reference's, byte for byte, in
  `Runnable.hs`, `V5/Ingress.hs`, `V5/Timers.hs`, and hamsterdan-github's
  `Routing.hs` and `Webhooks.hs`.
- **What is normalized.** Only values the reference itself draws fresh on
  every run: the Worker id (a uuid4), ISO instants, and epoch seconds,
  milliseconds and microseconds.

## Benchmarks

[bench/RESULTS.md](bench/RESULTS.md), in wall-clock time on both sides,
seven interleaved repetitions against the twin protocol (median of
batches), 2026-10-11, load average 1.96–3.91. Haskell is faster on every
row:

| Row | Haskell | Python | Speedup |
| --- | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 4.20 ms | 10.8 ms | 2.57× |
| reconciliation step | 28.3 ms | 176 ms | 6.23× |
| agent turn (one webhook through the scripted Pi agent) | 147 ms | 317 ms | 2.15× |
| gate classification | 2.69 µs | 55.4 µs | 20.6× |
| timer rebuild | 3.73 ms | 7.52 ms | 2.01× |
| fresh timer-store open | 943 µs | 1.40 ms | 1.49× |

The fresh open was level before (1.00× in the previous seven repetitions,
0.95–0.99× in earlier rounds): the same system calls on both sides, and
fifteen fsyncs per open, seven of them from the schema's statements
committing one by one. The port now creates the schema in one transaction
(DIVERGENCES.md); the file's bytes do not change, and `TimersSpec` checks
them against the reference's. Haskell was ahead in all seven repetitions,
by 1.01× at the least, when the load rose to 3.9.

The process-level rows of the same file (`bench/Process.hs`, eleven
interleaved runs, 2026-10-11, load average 4.0–5.8) measure restart,
housekeeping, the operator's commands and the effects against the
reference's processes, with a 20-PR state directory of 1,228-record
Histories and one fake GitHub for both sides (the two `serve` rows are from
the later round under load 6.5–7.2 that RESULTS.md describes, after the
port began writing uvicorn's log lines):

| Row | Haskell | Python | Speedup |
| --- | ---: | ---: | ---: |
| `validate` (fresh process) | 140 ms | 1.07 s | 7.65× |
| `inbox` (fresh process) | 129 ms | 786 ms | 6.09× |
| `inspect-instance` (fresh process, 2,001 records) | 42.0 ms | 593 ms | 14.1× |
| `serve` start to the first `200` on `/healthz` | 346 ms | 1.08 s | 3.12× |
| 100 signed POSTs to a running `serve` (warp against uvicorn) | 24.4 ms | 72.9 ms | 2.99× |
| `sweep("periodic")`, 20 loaded Instances | 17.0 ms | 1.70 s | 100× |
| `sweep("periodic")`, 20 unloaded Instances | 232 ms | 3.25 s | 14.0× |
| immutable comment publication | 12.1 µs | 25.1 µs | 2.08× |
| native review batch (8 findings) | 189 µs | 389 µs | 2.06× |
| GraphQL ref compare-and-swap | 2.3 µs | 3.9 µs | 1.68× |
| Git publication (local authority) | 307 ms | 355 ms | 1.16× |

`validate`, `inbox` and `serve` were behind (0.65–0.69×) until
agent-route repair stopped decoding each History to text to split its
lines (hamsterdan-agents' `terminalOperations`, 988 ms to 105 ms over the
20 Histories). The Git publication row is mostly Git's own processes on
both sides; it read 1.03× in one three-run round.

## Divergences

See [DIVERGENCES.md](DIVERGENCES.md). `serve` writes uvicorn's log lines
(`CliSpec`'s serve comparisons, `UvicornSpec`). What it does not write is
h11's `Invalid HTTP request received.` warning: warp refuses a malformed
request itself.

The CLI also differs in one way: tracebacks have only their last line.
