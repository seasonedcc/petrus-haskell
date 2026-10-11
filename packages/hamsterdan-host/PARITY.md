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
| `host/api.py` (FastAPI, served by uvicorn) | `Hamsterdan.Host.Api` (WAI, served by warp), `Hamsterdan.Host.Api.Documents` | `ApiSpec`. The surface test compares every response with the reference served by uvicorn, byte for byte except the `date` value. |
| `host/binding.py` | `Hamsterdan.Host.Binding` (in hamsterdan-agents, which the Pi A2 installation binding needs) | `BindingSpec`, plus the interop tests (`binding.json`). |
| `host/runnable.py` | `Hamsterdan.Host.Runnable` | `RunnableSpec`, plus the interop tests (`runnable.sqlite3`). |
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
| `tests/unit/host/test_v5_timers.py` | 18 | 21 | `TimersSpec` | 21 |
| `tests/integration/host/test_git_publish.py` | 18 | 30 | `GitPublishSpec` | 30 |
| `tests/integration/host/test_service.py` | 64 | 70 | `ServiceSpec` (59), `ApiSpec` (FastAPI, 6), `CliSpec` (4) | 69 |
| **Total ported** | **268** | **358** | | **357** (+3) |

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
| `ApiSpec`: "the HTTP surface against the reference (uvicorn)" | 1 | 43 requests, sent over a raw socket to the reference under uvicorn and to the port under warp. They cover health, the FastAPI pages, routing fallbacks (405 with `allow`, 307, 404), percent-encoding, HTTP/1.0, pipelining, and webhook accept, duplicate and refusals. The status line (h11's `HTTP/1.1`, also for HTTP/1.0), every header in order (only the `date` value is blanked), and the body bytes must match. |
| `CliSpec`: "serve (uvicorn.run)" | 1 | `serve` on a free port, with the composed agent: an HTTP/1.0 health check gets `HTTP/1.1 200 OK` and `Connection: close`, `SIGTERM` stops it with exit status 0, and `agent-routes.sqlite3` and `pi-a2/installation` exist. |
| `CliSpec`: "the command line against the reference" | 1 | 105 cases through `python -m hamsterdan.host`'s `main()` and through the port. They cover argparse parsing, usage and help at nine `COLUMNS` widths, configuration failures, `inspect-instance` over hostile histories, startup refusals, `inbox`/`requeue` against a parked delivery, the Pi configuration refusals of the agent composition, and `validate` against a recording fake GitHub. Both sides compose the real agent over an installed-package fixture. Each case must give the same stdout, stderr, exit status, state effects and GitHub requests. |
| `InlineRecoverySpec` | 5 | The five restart-convergence cases of `tests/unit/readiness/net_v5/test_inline_recovery.py`, against the real host gates. This closes the gap that hamsterdan-readiness's PARITY.md recorded. |
| `MutationSpec`: `reference_bytes` | 3 | The mutation ref and payload digest match Python for `change`, `repair` and `update_base`. |

The full suite has 380 examples:

- 357 port upstream cases of this package's scope;
- 9 port the coding-activity cases of `test_pi.py` (`PiActivitySpec`);
- 3 are `reference_bytes`;
- 5 are inline recovery;
- 6 are differential and interop tests.

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
| `tests/integration/host/test_readiness_scenarios.py` | 11 | `hamsterdan-testing` (6): the 11 journeys over `host/testing` (the World) |

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

[bench/RESULTS.md](bench/RESULTS.md), in wall-clock time on both sides.
Haskell is faster on every row but the fresh timer-store open:

| Row | Haskell | Python | Speedup |
| --- | ---: | ---: | ---: |
| webhook ingest (100 deliveries) | 5.31 ms | 18.1 ms | 3.4× |
| reconciliation step | 36.1 ms | 184 ms | 5.1× |
| agent turn (one webhook through the scripted Pi agent) | 175 ms | 348 ms | 2.0× |
| gate classification | 2.92 µs | 56 µs | 19× |
| timer rebuild | 4.58 ms | 8.54 ms | 1.86× |
| fresh timer-store open | 1.51 ms | 1.63 ms | 1.08× |

The fresh open is not reliably faster: 1.08× and 0.97× in these rounds,
0.81× and 0.94× in the rounds of 2026-10-10 (SQLite file creation, WAL
and schema; see RESULTS.md). It belongs to the "V5 timers" component.

## Divergences

See [DIVERGENCES.md](DIVERGENCES.md). One divergence is observable on
the HTTP side: uvicorn's own log lines, which the port does not write.

The CLI also differs in two ways: the one-line uncaught traceback, and no
color in help.
