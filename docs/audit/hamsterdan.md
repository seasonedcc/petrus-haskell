# Audit: hamsterdan slice

This is the audit of record for the Haskell port of
[henriquebastos/hamsterdan](https://github.com/henriquebastos/hamsterdan) at
the pin in [UPSTREAM.md](../../UPSTREAM.md) (`5d382467eaa4ff837cbd6b93012c99081e0153f9`),
against the seven outcomes of the project goal. Paths on the upstream side are
relative to `upstream/hamsterdan/`; Haskell paths are relative to the
repository root. The audit was run on 2026-10-11 against `main` at `3bfb6c9`.

Method: an inventory taken from the pinned checkout (module list, public
names, `argparse` definitions, environment variables, REST and GraphQL calls,
SQLite DDL, and `pytest --collect-only` in the pinned environment), then a
mechanical mapping of every upstream test function onto the Haskell specs
(name matching with a fuzzy fallback, then reading the doubtful ones on both
sides), then judgment. Targeted suites were rebuilt and rerun from this
checkout (see "Runs"). Benchmarks were read from the committed results, not
rerun. No GitHub API or other external service was called.

## Scope covered

| Item | Count | Notes |
| --- | ---: | --- |
| Upstream modules under `src/hamsterdan` | 64 (54 without `__init__.py`) | 25,906 lines; every one is mapped in a PARITY ledger except `host/protocol.py` (HAM-9). |
| Public top-level classes and functions | 400 | |
| Upstream test files (`tests/`, `deployment/tests/`) | 57 | plus `tests/amp_webhook_relay.test.ts` (bun, 6 cases); `tests2/` (43 cases) belongs to `src/hamsterdan2` |
| Upstream test functions | 972 | |
| Collected pytest cases | 1,297 | `pytest --collect-only tests deployment/tests` in `upstream/hamsterdan/.venv` (Python 3.14.6), matching docs/hamsterdan.md §4.1 |
| Host CLI commands | 5 | `serve`, `validate`, `inbox`, `requeue`, `inspect-instance`; flags `--delivery`, `--installation`, `--repository`, `--pr`, `--host`, `--port` |
| Operator CLI commands | 6 | `preflight`, `create`, `prepare-broker`, `inspect`, `inspect-authority`, `qualification-setup` and their 10 flags |
| Export CLI | 1 | `python -m hamsterdan.host.export`, 6 flags |
| HTTP routes | 2 + 4 | `POST /github/webhooks`, `GET /healthz`, plus FastAPI's `/openapi.json`, `/docs`, `/docs/oauth2-redirect`, `/redoc` |
| Environment variables read by `src/hamsterdan` | 28 | 19 live, 9 retired (refused); all 28 are read by the port (`packages/hamsterdan-*/src`, `app`) |
| GitHub REST paths | 20 | App registration (3), token mint, gateway reads (11), effects writes (6) and Git objects (3) |
| GraphQL operations | 3 | `reviewThreads`, `resolveReviewThread`, `repository{id}` + `updateRefs` |
| Persisted stores | 10 | `routes.sqlite3`, `webhooks.sqlite3` (4 tables), `runnable.sqlite3`, `activity-dispatch.sqlite3`, `agent-routes.sqlite3`, `binding.json`, `history.jsonl`, `review-requests.sqlite3`, `timers.sqlite3`, `pi-a2/` |

## Mapping summary

| Upstream tests | Files | Cases | Haskell | State |
| --- | ---: | ---: | --- | --- |
| `tests/unit/github_app/*` | 2 | 163 | `hamsterdan-github` `AppFoundationSpec`, `GitHubSpec` | all mapped; `test_transport_repr_does_not_claim_or_expose_credentials` does not apply (no `Show` on clients, DIVERGENCES 3) |
| `tests/unit/agents/*` | 2 | 66 | `hamsterdan-agents` `PiSpec`, `ProtocolSpec`; `hamsterdan-host` `PiActivitySpec` | all mapped; 4 cases enforced by types |
| `tests/unit/host/*` (non-v5) | 8 | 180 | `hamsterdan-agents`, `hamsterdan-host`, `hamsterdan-export`, `hamsterdan-operator` | all mapped; 6 publication-qualification cases enforced by types |
| `tests/unit/host/test_v5_*` | 6 | 238 | `hamsterdan-host` `GatesSpec`, `IngressSpec`, `IngressApplicationSpec`, `MutationSpec`, `RerunSpec`, `ReviewSpec`, `TimersSpec` | all mapped |
| `tests/unit/readiness/**` | 15 | 305 | `hamsterdan-readiness` (14 specs), `hamsterdan-contracts` `CodecSpec` | all mapped; convergence cases also on the real host gates |
| `tests/unit/testing/test_readiness_model.py` | 1 | 34 | `hamsterdan-testing` `ReadinessModelSpec` | all mapped |
| `tests/unit/test_operator.py` | 1 | 57 | `hamsterdan-operator` `OperatorSpec` | all mapped |
| `tests/integration/host/*` | 6 | 146 | `hamsterdan-host` `ServiceSpec`, `ApiSpec`, `CliSpec`, `GitPublishSpec`; `hamsterdan-agents`; `hamsterdan-operator`; `hamsterdan-testing` `ReadinessScenariosSpec` | all mapped; `test_host_service_requires_agent_route_custody` is enforced by the type of `serviceOptions` |
| `tests/integration/testing/*` | 3 | 30 | `hamsterdan-testing` `ReadinessWorldSpec`, `ReadinessCampaignSpec`, `ReadinessCoverageSpec` | all mapped; Hypothesis campaigns become enumerations (HAM-6) |
| `deployment/tests/test_container_contract.py` | 1 | 4 | `hamsterdan-operator` `ContainerSpec`, CI `container` job | mapped |
| Repository meta: `tests/test_{architecture,check_command,distribution,pytest_policy}.py` | 4 | 20 | none | Python tooling; architecture rules claimed to be enforced by package boundaries (HAM-2) |
| Ops tooling: `tests/unit/test_{orb_setup,secret_tools}.py`, the other 7 `deployment/tests/*` | 9 | 54 | none | out of scope as ops tooling (SCOPE.md, docs/hamsterdan.md §1.10, §4.4); not listed per file in any ledger (HAM-3) |
| `tests/amp_webhook_relay.test.ts` | 1 | 6 | none | development relay (TypeScript); the receipt contract it depends on is checked by `ApiSpec` |

1,223 of the 1,297 collected cases fall in files the port mirrors; every one of
them has a Haskell check (mirrored name, paraphrased name, or a documented
type-level guarantee), except the one `repr` case that does not apply. The
remaining 74 cases are Python repository tooling or ops tooling. The mapping
was confirmed by matching all 972 function names against the Haskell specs
and reading every match below a 0.5 token similarity on both sides; no
mirrored test was found missing. Ledger counts were checked against the
collection: they agree everywhere except `hamsterdan-github/PARITY.md`, which
gave `test_app_foundation.py` 31 functions instead of 34 (corrected in this
audit; the 34 functions were all found ported).

Beyond the upstream tests, the port adds differential evidence the upstream
suites do not have: byte-for-byte corpora (contracts, Python literals, folds,
board, config, webhooks, HTTP, effects, readiness oracle), the net-definition
fingerprint, raw-socket HTTP comparison with uvicorn, CLI differentials for the
host (105 command lines), the operator (124) and export (115), state-directory
cross-resume in all four pairings (with and without the real Pi agent), GitHub
request comparison header for header, the 11 journeys byte-identical whole and
split across languages (tier A), and the journeys plus 3 fault cases recorded
from the reference over real HTTP and replayed into both hosts (tier B).

### `src/hamsterdan2` scope claim

Verified. At the pin, `src/hamsterdan2` has no `__main__`, no
`[project.scripts]` entry, and is not packaged at all
(`pyproject.toml` `[tool.hatch.build.targets.wheel] packages = ["src/hamsterdan"]`).
Nothing under `src/hamsterdan`, `deployment/` or `scripts/` imports it except
`scripts/check`'s lint profile; the Containerfile and the systemd unit run
`python -m hamsterdan.host`. It imports no HTTP client, GitHub client or
subprocess. `git diff 1eef74a 5d38246 -- src` (production release vs pin) is
empty, so the pinned `src/hamsterdan` is what production runs.

### Petrus pin reconciliation claim

Verified locally: the Petrus installed in `upstream/hamsterdan/.venv`
(`direct_url.json`: `89baf78`) differs from `upstream/petrus/src/petrus` at
`3f85fc2` only in `engine/_postgres.py`, `fabric/postgres.py`,
`impetus/history_store/postgres.py`, `motus/dispatch/absurd.py`,
`motus/transport/zeromq.py`, `processes/postgres.py` and `telemetry.py`, none
of which Hamsterdan imports.

## Runs

Rebuilt from this checkout with `cabal -j2`, run under `nice -n 10` with
`+RTS -M2G -RTS`:

| Suite | Examples | Failures | Pending | Wall time | What it exercises against the reference |
| --- | ---: | ---: | ---: | ---: | --- |
| `hamsterdan-host-test` | 382 | 0 | 0 | 49 s | upstream host and v5 tests, raw-socket HTTP against uvicorn, CLI differential, state cross-resume in all pairings, GitHub requests header for header |
| `hamsterdan-testing-test` | 208 | 0 | 0 | 578 s | oracle corpus, World, campaigns, coverage, the 11 journeys and their 44 cross-language interop runs |
| `hamsterdan-e2e-test` | 30 | 0 | 0 | 159 s | tier B (11 journeys and 3 fault cases recorded from the reference and replayed into both hosts) and tier C tooling against fakes |
| `hamsterdan-github-test` | 200 | 0 | 0 | 9 s | upstream `github_app` tests and the 9,010-row corpora |

The other five hamsterdan suites (`contracts`, `readiness`, `agents`,
`export`, `operator`) were audited by reading, not rerun. The `test_github.py`
mapping was also checked example by example against this run: its 82
applicable cases are the 81 examples under the gateway, publisher and broker
groups plus "normalizes network failures without exposing the provider
error" under the client-stack group; the client stack's other 26 examples and
the foundation group's 54 are `test_app_foundation.py`'s 80 cases.

## Findings

No blocker was found. Severity: blocker = an outcome does not hold; major =
an outcome is materially weakened; minor = a gap in evidence, docs or edge
behavior.

| Id | Outcome | Severity | Finding | Evidence (upstream / Haskell) | Suggested fix |
| --- | --- | --- | --- | --- | --- |
| HAM-1 | 6 | major | The host's restart and housekeeping paths and its operator commands have no benchmark. Production restarts the host on every deploy and runs `serve` startup (`preflight_v5_state`, agent-route repair decoding every `history.jsonl`, the startup sweep reloading each Instance's Engine from History) and a periodic sweep every 60 s; `validate`, `inbox`, `requeue` and `inspect-instance` are the operator's runtime surface. The host bench covers ingest, one fresh reconciliation, one agent turn, gate classification and the timer store only, yet PARITY.md cites it for the host CLI row. | `src/hamsterdan/host/binding.py:162`, `host/agenticus.py:398`, `host/service.py:370`, `host/v5/runtime.py:183`, `host/__main__.py:196` / `packages/hamsterdan-host/bench/RESULTS.md:3-30`, `PARITY.md:103` | Add twin rows: `serve` start-to-`/healthz` on a state directory with N PRs and long Histories (route repair included), `sweep("periodic")` over N loaded and unloaded Instances, and fresh-process `validate` / `inbox` / `inspect-instance` against `python -m hamsterdan.host`, as the operator and export benches do. |
| HAM-2 | 2 | minor | `tests/test_architecture.py`'s import rules are said to be enforced by package boundaries, but nothing checks them and one is broken: the `agents` sibling imports the `github_app` sibling. `hamsterdan-agents` depends on `hamsterdan-github`, and `Hamsterdan.Agents.Pi` and `Hamsterdan.Agents.Validate` import `Hamsterdan.GitHub.Python`. | `tests/test_architecture.py:62-73` / `packages/hamsterdan-agents/hamsterdan-agents.cabal:60`, `packages/hamsterdan-agents/src/Hamsterdan/Agents/Pi.hs:60`, `.../Agents/Validate.hs:61`, `packages/hamsterdan-github/PARITY.md:104-105`, `docs/hamsterdan.md:1074` | Move the Python string helpers (`strip`, `utf8Length`) to `hamsterdan-contracts` (or `petrus-json`), and add an import-graph check (in `ArchitectureSpec` or a lint) for the rules that carry over: siblings never import each other, only the host imports concrete siblings, siblings and contracts never import the host, agenticus only in agents and host, engine/dispatch/worker only in the host. |
| HAM-3 | 2, 7 | minor | 13 upstream test files (74 cases) have no Haskell counterpart and are excluded only by prose in docs/hamsterdan.md §4.4; no ledger lists them file by file with the reason, so the repository does not show at a glance that every upstream test is accounted for. | `tests/test_{architecture,check_command,distribution,pytest_policy}.py`, `tests/unit/test_{orb_setup,secret_tools}.py`, `deployment/tests/test_{ci_contract,deploy,exe_access,exe_vm,observation,release,runtime}.py`, `tests/amp_webhook_relay.test.ts` / `docs/hamsterdan.md:1067-1076` | Add an "Upstream tests not ported" table (file, cases, reason, what replaces it if anything) to the hamsterdan section of PARITY.md or to the operator ledger. |
| HAM-4 | 5, 3 | minor | Two documented divergences show on the wire or in persisted state, which the goal says never diverge: a signed webhook whose JSON contains a lone-surrogate escape (`"\ud800"`) is accepted with 202 by the reference and refused with 400 by the port; and non-UTF-8 Git output in a Pi workspace is recorded as `error_class=ValueError` where the reference records `UnicodeDecodeError` (the class name lands in `webhooks.sqlite3` `inbox.error_class`). Both need inputs GitHub or Git do not produce in practice, and both are documented with a rationale. | `github_app/webhooks.py:206`, `:155` / `packages/hamsterdan-github/DIVERGENCES.md:59-69`, `packages/hamsterdan-agents/DIVERGENCES.md:38-45` | Either carry lone surrogates through (keep the escaped JSON string for observation members, which are stored escaped anyway) and name the decode failure `UnicodeDecodeError`, or record them as explicit owner-approved exceptions to "wire formats never diverge". |
| HAM-5 | 6 | minor | Webhook ingest is benchmarked as an in-process call into the WAI application on the Haskell side and a raw ASGI call on the Python side; the HTTP server each host runs in production (warp versus uvicorn and h11) is outside the measurement. The committed ingest row's lowest repetition is 0.97× (median 2.57×). GitHub writes (comment publication, review batches, GraphQL CAS) and `host/git_publish.py` are measured only inside larger rows. | `host/api.py` / `packages/hamsterdan-host/bench/RESULTS.md:3-10, 64`, `packages/hamsterdan-host/bench/bench.py:103-120` | Add a socket-level ingest row (N signed POSTs to a running `serve` on both sides), and an effects row against the fake GitHub. |
| HAM-6 | 2 | minor | The delivery-recovery state machine is explored less deeply than upstream: Hypothesis runs `stateful_step_count=5`, the port enumerates rule sequences of at most 2 rules (56 runs). Sequences of 3 to 5 rules are never run. | `tests/integration/testing/test_readiness_campaign.py:920-922` / `packages/hamsterdan-testing/test/ReadinessCampaignSpec.hs:108-116`, `packages/hamsterdan-testing/DIVERGENCES.md:131-150` | Extend the enumeration to 5 rules (2^5 sequences per branch seed), or add a seeded random walk of up to 5 rules, so the bound is at least upstream's. |
| HAM-7 | 7 | minor | CI and `scripts/check-all` provision the `petrus` and `petrus-engine` references up front "before the suites run in parallel", but not the `hamsterdan` reference that seven hamsterdan suites use; it is provisioned lazily from inside concurrently running suites, and `scripts/upstream-python` takes no lock. | `scripts/check-all:44-50`, `.github/workflows/ci.yml:37-44`, `scripts/upstream-python:73-82` | Add `hamsterdan` to both provisioning lists. |
| HAM-8 | 1, 7 | minor | The "End-to-end against a real GitHub App" row reads `in progress`. The owner's decision that the live tier C run is optional is not recorded anywhere in the repository, so the table cannot show that the offline tiers are the agreed bar. | `PARITY.md:117`, `docs/e2e.md`, `scripts/check-parity:14-16` | Record the decision (date and scope) in PARITY.md and docs/e2e.md, and give the row a status `check-parity` understands (for example `at parity (offline); live run optional`). |
| HAM-9 | 2, 7 | minor | `host/protocol.py` (the `ReadinessApplication` protocol and `DurableActivityResolver`) is the one upstream module no ledger maps. | `src/hamsterdan/host/protocol.py` / `packages/hamsterdan-host/PARITY.md:19-36` | Add a row (its Haskell counterpart is the application record in `Hamsterdan.Host.Service` / `V5.Application`). |
| HAM-10 | 5 | minor | Where Haskell could be clearly better: the engine policy reads its forced ingress target through `unsafePerformIO` because the Petrus selection seam is pure. It is documented and currently safe, but it relies on evaluation order. | `host/v5/runtime.py:56` / `packages/hamsterdan-host/src/Hamsterdan/Host/V5/Runtime.hs:217-221`, `packages/hamsterdan-host/DIVERGENCES.md:76-80` | Pass the target through the selection input (a policy built per drive, or a snapshot field), removing the `unsafePerformIO`. |
| HAM-11 | 7 | minor (fixed) | Documentation drift: `hamsterdan-github/PARITY.md` counted 31 functions for `test_app_foundation.py` (there are 34), and docs/hamsterdan.md §7's interop checklist was all unchecked although every item is evidenced by a row at parity. | `packages/hamsterdan-github/PARITY.md:69`, `docs/hamsterdan.md` §7 | Corrected in this audit's commit. |

## Verdicts

1. **Pinned parity: holds.** The pin is recorded in UPSTREAM.md and is the
   production source (`git diff 1eef74a 5d38246 -- src` is empty); the Petrus
   pin difference was re-verified. HAM-8 is a recording gap, not a pin gap.
2. **Conformance: holds, with minor gaps.** Every behavior the mirrored
   upstream test files check has a Haskell check, and the port adds
   byte-level corpora and differentials upstream lacks. The architecture rules
   are not checked and one is violated (HAM-2), the state-machine campaign is
   shallower than upstream's (HAM-6), and the 74 ops/meta cases left behind
   are not listed per file (HAM-3).
3. **Interoperability: holds.** Both hosts resume each other's state
   directories file by file in all four pairings, with and without the real Pi
   agent; HTTP responses match uvicorn byte for byte; the host, operator and
   export CLIs match the reference on stdout, stderr, exit status, files and
   GitHub requests; tier A and tier B are byte-exact. CEL guards are
   exercised through the `ready.facts` migration lane on petrus-cel. HAM-4's
   two hostile-input differences are the only exceptions found.
4. **Fabric and processes: not applicable to this slice.** Hamsterdan does
   not use `petrus.fabric`, `petrus.processes`, observation HTTP or
   simulation at the pin.
5. **Better the Haskell way: holds, with minor notes.** Every DIVERGENCES
   entry read has a rationale; wire formats and persisted bytes match except
   HAM-4; HAM-10 is one place the port could still be cleaner.
6. **Performance: holds for the measured paths; one major coverage gap.**
   Every committed row is at or above 1.0× (worst 1.04×, median-of-repetitions
   method), with Python twins on equivalent workloads. Restart, sweep and the
   host CLI are not measured (HAM-1); ingest is not measured through the real
   servers (HAM-5).
7. **Verifiability: holds, with minor gaps.** All hamsterdan suites run under
   `cabal test all` in `scripts/check-all`, which CI runs on every push to
   `main` and every pull request; the container job builds and smoke-tests the
   image. No hamsterdan example is pending in the suites rerun; the only
   conditional skips found are four `SecretLaunchSpec` cases that need bash
   4.4 or later, which go pending on macOS's bash 3.2 and run on CI's
   ubuntu-24.04 (bash 5). The audit could not inspect CI run history (no
   GitHub API calls).
   HAM-7, HAM-8 and HAM-9 are bookkeeping gaps.
