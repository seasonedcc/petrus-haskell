# Audit: simulation, observation HTTP, DST, telemetry, agenticus

Slice audited against the goal's outcomes 1–7, at upstream `henriquebastos/petrus`
`3f85fc2094e50ece48bcf6bf9ace19cb0a22a544` (UPSTREAM.md), on local `main` at `3bfb6c9`.
Auditor: independent pass, 2026-10-11. Claims in PARITY/README files were re-checked
against code and tests, not trusted.

## Scope covered

Upstream (pinned checkout `upstream/petrus`):

| Area | Upstream source | Public top-level names | Upstream test files / functions |
| --- | --- | ---: | --- |
| Simulation runner | `simulation.py` | 19 | `tests/petrus/engine/test_simulation.py` 19 (27 items) |
| Simulation HTTP | `simulation_http.py` | 2 | `test_simulation_http.py` 24 (71 items) |
| Observation HTTP | `engine/observation_http.py` | 3 | `test_observation_http.py` 7 (19 items) |
| HTTP core | CPython `http.server`/`urllib.parse` as used by both services | — | (covered through both services) |
| Telemetry | `telemetry.py` + `impetus_*` instrumentation | 15 | `test_telemetry.py` 29, `test_telemetry_instrumentation.py` 22 |
| DST | `testing/dst.py`, `tests/dst/*` support modules (22) | 96 | 23 files, 193 functions |
| Agenticus | 37 modules under `agenticus/` + 3 `.mjs` helpers | 404 | 31 files, 408 functions (9 of them `*_real.py`) |
| Project boundary | `tests/project/test_package_boundaries.py` | — | 1 function touching this slice |

Totals: 42 Python modules and 3 `.mjs` helpers, 539 public top-level names, 59 test files
with 702 test functions (+1 project boundary test). Spec documents: `spec/simulation-http-v1.md`,
`spec/observation-protocol-v1.md`, `spec/observation/*.json` (3 fixtures), and the
`net-document-v1-{simulation,observation}.json` fixtures.

Haskell: `petrus-simulation`, `petrus-observation-http`, `petrus-http-core`, `petrus-dst`
(+ `engine-worlds`, `joined-worlds`), `petrus-telemetry`, `petrus-telemetry-instrumentation`,
`petrus-agenticus`, `petrus-agenticus-core`, `petrus-agenticus-runtime`.

## Method and what was run

- **Test mapping (mechanical).** Every upstream `def test_*` name was searched for in the Haskell
  test sources of the mapped packages; names not found were looked up in the package ledgers.
  Simulation/observation: 50/50 found as `it` labels. Agenticus: 399/408 found as `it` labels;
  the 9 missing are exactly the `*_real.py` live-provider tests. Telemetry: 0/51 by name (examples
  use prose labels), all 51 mapped one-to-one in `packages/petrus-telemetry/PARITY.md` and
  confirmed against `test/Main.hs` and `InstrumentationSpec.hs`. DST: 1/193 by name; the ledger
  maps by kind (`packages/petrus-dst/PARITY.md`), and 28 functions are declared out of scope there
  (SDA-1, SDA-2).
- **Public surface (mechanical).** Every public top-level class/function/constant (and public
  method) of the upstream modules was searched for, case- and underscore-insensitively, in the
  Haskell library sources. Unmatched names were inspected by hand: all are pydantic validators,
  module constants folded into records (`SimulationBounds`), the DST process-failure models (a sum
  type in `Petrus.Testing.Dst.Runner`), or `Protocol` classes documented as records
  (`ClaudeConnectionCustody`/`CodexConnectionCustody` → `PiConnectionCustody`). No public
  behavior was found unported.
- **Pending/skip audit.** `pending`/`pendingWith`/env gates in all slice tests; `scripts/lint-skips`
  passes (415 sources). Remaining pendings: the 3 Pi qualification probes (skipped upstream too),
  the real-Docker workspace run (runs in CI: `PETRUS_TEST_DOCKER=1`, `.github/workflows/ci.yml:27`),
  the 66 joined DST worlds without PostgreSQL (CI sets it), and Pi `node` tests (skipped upstream
  too; Node is on the CI runner image).
- **Runs** (local, `nice -n 10`, `-j2`, `+RTS -M2G`), all green:
  `petrus-simulation` 108/0 (incl. 501+80 raw-request wire identity, 600-scenario corpus, 42
  upstream urllib cases against Haskell), `petrus-observation-http` 28/0 (3×501 raw requests),
  `petrus-http-core` 108/0, `petrus-telemetry` 37/0, `petrus-telemetry-instrumentation` 52/0
  (including live regeneration from the pinned reference), `petrus-agenticus-core` 642/0
  (including custody interop both ways), `petrus-agenticus` 166/0 (1 pending: real Docker),
  `petrus-agenticus-runtime` 403/0 (3 pending as upstream), `petrus-dst` 216/0 under a throwaway
  PostgreSQL (`scripts/with-postgres`), joined worlds included. Benchmarks were not run; committed
  results were read.

## Mapping summary

| Upstream | Haskell | Tests | Interop evidence | Bench |
| --- | --- | --- | --- | --- |
| `simulation.py` | `Petrus.Simulation` | 27/27 items | 600 random scenarios vs upstream `simulate` (live) | 7 rows, 6.0–34× |
| `simulation_http.py` | `Petrus.Simulation.Http` | 71/71 items + 5 spec checks | 581 raw requests byte-identical vs upstream server (live); upstream urllib tests vs Haskell server | 4 + load rows, 1.6–12× |
| `observation_http.py` | `Petrus.Observation.Http` | 19/19 items + 3 profile checks | 1503 raw requests vs upstream server (live); urllib clients vs Haskell; viewer backend vs both | 4 + load rows, 1.6–5.1× |
| `http.server` core | `petrus-http-core` | 108 | raw-request and 3000 generated-line comparisons with CPython (live) | 6 rows ≥1.59× |
| `telemetry.py` | `petrus-telemetry` | 29/29 | routed line bytes vs CPython | per-emit and chain overhead |
| instrumentation | `petrus-telemetry-instrumentation` | 22/22 (1 adapted) | 23 scenarios / 282 events, regenerated live | 2.5–8× |
| `testing/dst.py` + worlds | `petrus-dst` | 165/193 functions mapped; 28 declared out of scope | 51 Python fixtures replayed; 51 builders authored byte for byte; committed vectors | 14 rows, 1.02–2.9× |
| `agenticus/{catalog,effect,thread,hands,program,runtime values}` | `petrus-agenticus-core` | all mapped by name | committed corpora | ≥1.8× |
| `agenticus/connection` | `petrus-agenticus-core` | 21/21 (24 cases) | custody sessions handed over both ways (live) | ≥2.7× |
| `agent_net`, `attachment`, `hands/workspace` | `petrus-agenticus` | all mapped by name | committed corpora; retention ledger Python→Haskell only | 1.23–5.5× |
| `agent_net_runner.py` | `Petrus.Agenticus.Runtime.AgentNetRunner` | 10/10 | `thread.json`/`history.jsonl` bytes over 12 runs (committed) | 1.86–2.6× |
| `pi*.py`, `.mjs` | `Petrus.Agenticus.Runtime.Pi*` | all non-real mapped; 3 pending as upstream | Pi ledger written/read identically (committed fixture) | 7 rows, 1.08–5.0× |
| `codex.py`, `_codex_gondolin_service.py` | `…Runtime.Codex`, `…CodexGondolin` | 41/41 (54 cases) | ledger and Worker interop both ways (live) | rows + whole turn 1.33× |
| `claude.py` | `…Runtime.Claude` (+ `claude_sidecar.py`) | 32/32 (46 cases) | hosts corpus (committed) | rows + whole turn 1.32× |
| `amp.py` | `…Runtime.Amp` (+ `amp_sidecar.py`) | 15/15 (19 cases) | hosts corpus; 22 raising-event streams vs reference adapter (live) | rows + whole turn 1.22× |

## Findings

| ID | Outcome | Severity | Evidence | Suggested fix |
| --- | --- | --- | --- | --- |
| SDA-1 | 2 | blocker | Upstream checks the Engine under generated schedules: `upstream/petrus/tests/dst/test_generated_delivery_world.py` (2: delivery idempotence/conflict under generated crash/reload, invariant against an external authority model, replay of every generated artifact), `test_generated_runtime_qualification.py` (5: fair-phase convergence, external wait vs inadequate fair declaration, fair-budget exhaustion vs livelock, Hypothesis shrinking of a livelock mutant, semantic coverage report), `test_generated_runtime_world.py` focused/broad schedules (2). Haskell: `packages/petrus-dst/PARITY.md:260-286` declares them out of scope ("the hypothesis drivers are not" ported; `LivelockMutationProfile` not ported). The Haskell Engine is never exercised by generated DST schedules; `test/Spec/Properties.hs` only generates toy-profile scripts. | Port the three campaigns as QuickCheck/Hedgehog state machines over the already-ported `Petrus.Testing.Dst.Engine.Delivery` and `…GeneratedRuntime` profiles and checkers (port `LivelockMutationProfile`), with the reference's budgets, coverage labels and replay-of-every-case assertion; record the generated reach. |
| SDA-2 | 2, 7 | major | 19 more upstream DST functions are excluded by a package-level decision (`packages/petrus-dst/PARITY.md:260-284`): `test_failure.py` 5 (failure-bundle retention refusing credential-shaped data, tamper and extra-file detection, manifest checks), `test_replay.py` 5 (legacy replay format), `test_campaign.py` 6 and `test_dst_boundaries.py` 3 (campaign/boundary runners). The 15 `*_manual_replay_route_is_deterministic` tests are mapped to "Python CLI tooling"; Haskell has no replay command at all. `SCOPE.md` excludes none of this, and the top-level row (`PARITY.md:52`) says "at parity" mentioning only `LivelockMutationProfile`. | Either port (a `petrus-dst-replay` executable mirroring `python -m tests.dst.replay_world`, failure bundles, the campaign runner) or record the exclusion with its reason in `SCOPE.md` and in the top-level DST row so the repo shows it. |
| SDA-3 | 2 | major | The 9 `*_real.py` functions (`test_codex_real.py` 2, `test_claude_real.py` 2, `test_amp_real.py` 1, `test_pi_real.py` 2, `test_agent_net_real.py` 2) have no Haskell counterpart, not even opt-in (`packages/petrus-agenticus-runtime/PARITY.md:102-125`). Upstream they are opt-in acceptance runs against the real Codex CLI/Gondolin, Claude Agent SDK, Amp, Pi SDK and model APIs. The Haskell hosts (in particular the new sidecar path, SDA-6) have therefore only ever met fakes. `petrus-execution` did port its opt-in real-Gondolin acceptance (commit `3bfb6c9`), so the precedent exists. | Port each as an opt-in example behind the same environment gates (failing, not skipping, when the gate is set and the prerequisite is missing), run them once with credentials, and record the run in the parity files. |
| SDA-4 | 3, 5 | major | Telemetry output differs from Python on failures: `error_type` is the Haskell `Typeable` name (`packages/petrus-telemetry/DIVERGENCES.md:27`), a failed Engine drive reports `EngineError` where Python reports `RuntimeError` (`:57`), and `firing_failed.error` is Haskell failure text (`:68`). The differential hides this by mapping `EngineError`→`RuntimeError` before comparing (`packages/petrus-telemetry-instrumentation/test/Petrus/Telemetry/DifferentialSpec.hs`). A mixed Python/Haskell deployment's dashboards and alerts keyed on these fields see different values. | Emit the reference's vocabulary for runtime-originated failures (map Engine/handler failures to the Python class names the reference emits, as the differential already does), keep the Haskell type name in a separate field if useful; or specify `error_type`/`error` as implementation-defined in a spec document and say so in PARITY. |
| SDA-5 | 3 | major | Retention custody ledger interop is one direction only. `packages/petrus-agenticus/test/Petrus/Agenticus/RetentionDifferentialSpec.hs:164-202`: Haskell opens a Python-written ledger, and only the `capabilities` column of a Haskell-written row is compared. No test has Python open or `_decode` a Haskell-written `territory_custody` ledger, although upstream `_decode` is strict about storage classes (the corpus's own "wrong storage class" mutations). | Add a live interop example: Haskell writes rows in every phase, the pinned reference opens the file, `records()`/`recover()` decode them identically; and the reverse with a fresh Python-written ledger (not only the committed fixture). |
| SDA-6 | 5 | major | The Claude and Amp hosts multiplex every client of a Haskell process over one long-lived Python sidecar (`packages/petrus-agenticus-runtime/src/Petrus/Agenticus/Runtime/HostSupport.hs:337-400`, `divergences/claude-a2.md` item 1, `divergences/amp.md` item 1). This is new code with no upstream counterpart, and its sidecar tests (`test/…/ClaudeSpec.hs:999-1060`, `AmpSpec.hs:516-570`) run one client at a time. Nothing checks concurrent Turns on one sidecar (channel isolation, interleaved cancel/release), a sidecar that dies mid-Turn (other channels must settle like a failed client and the next open must respawn, `openSidecarChannel`'s retry), or a client stuck past the release grace while others proceed. The design itself is acceptable: per-SDK import once matches upstream's once-per-interpreter import, persisted bytes are pinned, and the remaining observable differences (environment captured at sidecar start; side-effecting Amp event properties read eagerly) are documented and niche. | Add tests: N concurrent Claude and Amp Turns over the shared sidecar with interleaved cancel and release, asserting per-channel outcomes; kill the sidecar mid-Turn and assert the affected Turns settle as upstream settles a failed client and the next Turn respawns it. |
| SDA-7 | 6 | major | Real-use paths without a benchmark: a whole Pi native Turn (`pi.py` through `pi_helper.mjs` with a fake SDK), a Pi A5 application Turn and a Pi model-phase run (only `pi-a2-scripted-turn`, which uses a script interpreter, is timed: `bench/results-pi.md:58-66`), and the Codex A3 runtime-service round trip (`bench/results-hosts.md:56`, "Not benchmarked"). The evidence for `pi-ledger-cycle` is thin: 1.08× median with rounds of 1.00, 1.09/1.00, 1.14, 1.10 and 0.47× (`results-pi.md:64` and the text after it). | Add whole-Turn twins for Pi native, Pi A5 and the model phase over the committed fake SDKs (as `TurnsBench.hs` does for Codex/Claude/Amp), and the A3 service round trip; rerun `pi-ledger-cycle` with more interleaved rounds on a quiet machine. |
| SDA-8 | 1, 7 | major | Most cross-language evidence in this slice is committed vectors with no freshness check: `petrus-dst` (10 vector files under `test/data/` plus generated `joined/…/Identities.hs`), `petrus-agenticus` (3 corpora + `retention_fixture.db`), `petrus-agenticus-core` (5 corpora), `petrus-agenticus-runtime` (`runner_corpus.json`, `pi_corpus.json`, `pi_reference_ledger.sqlite3`, `hosts_corpus.json`). Only `petrus-telemetry-instrumentation` regenerates its fixture from the pinned reference in a test. `UPSTREAM.md:20-31` ("Moving a pin") does not list regenerating them, so after a pin move stale vectors keep passing and hide gaps. | Add a `scripts/check-corpora` step to `scripts/check-all` that reruns each committed generator against the pinned reference into a temp dir and diffs (all generators are documented as deterministic), or at least add a regeneration step to "Moving a pin". |
| SDA-9 | 5 | major | The DST divergence "Checkers are pure … A Haskell checker cannot [hold state]" (`packages/petrus-dst/DIVERGENCES.md:51`) is contradicted by the port itself: the generated-runtime checker keeps `_frozen_execution_counts` across checks through `unsafePerformIO` (`packages/petrus-dst/engine/Petrus/Testing/Dst/Engine/GeneratedRuntime.hs:266-267, 874`), and the same escape hatch backs profile hooks in `Projection.hs`, `Lifecycle.hs`, `Retry.hs` and `joined/…/Joined/World.hs:308`. Upstream checkers may hold state; Haskell DST users can only reproduce one with `unsafePerformIO`, whose effect depends on the interpreter forcing every verdict exactly once. | Make the checker effectful like `Profile m g` (`check :: Observation -> m (Either ProfileError CheckResult)`, or a `Checker m` with explicit state) and drop `effectful`; correct the DIVERGENCES entry. |
| SDA-10 | 2 | minor | `tests/project/test_package_boundaries.py:157` `test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle` (the Codex Gondolin Activity adapter and runtime service never call retention lifecycle operations; the Worker never imports retention) has no Haskell counterpart in any package. | Port it as a structural check over `Petrus.Agenticus.Runtime.Codex`/`CodexGondolin` and `Petrus.Motus.Worker` imports, next to `BoundariesSpec`. |
| SDA-11 | 3 | minor | DST exchange is checked through byte identity and committed fixtures only: no live run has the pinned Python replay a Haskell-authored artifact, and no run has a Haskell process-runner parent drive a Python child, or the reverse (`packages/petrus-dst/DIVERGENCES.md`, "Process entrypoints are a static table"). The hamsterdan World does replay each language's artifacts in the other (`PARITY.md:112`), so the pattern exists. | Add a live example: Haskell authors every Engine-world story, the pinned `replay_world` replays it; optionally one process-runner run across languages. |
| SDA-12 | 5 | minor | Lone-surrogate handling diverges, and differently per host: Pi sessions decode `\ud800` to U+FFFD, Pi helper frames refuse (`malformed-frame`) where Python forwards the string (`packages/petrus-agenticus-runtime/divergences/pi.md:56-71`), Codex refuses (`divergences/codex.md:48-60`), custody refuses (`petrus-agenticus-core/divergences/custody.md`). A Pi Turn whose model output carries a lone surrogate escape fails in Haskell and can succeed upstream. Documented, and inherent to `Text`. | Pick one policy for model/tool payloads (refuse consistently, or carry raw bytes where the reference forwards) and note the user-visible effect in the top-level PARITY row. |
| SDA-13 | 5 | minor | Simulation request bodies nested 61,600–100,000 objects deep are refused by Python (400, CPython stack) but accepted here (then usually 409); arrays 100,001–~104,700 the reverse (`packages/petrus-simulation/DIVERGENCES.md`, "JSON nesting"). Upstream's limit is stack-dependent and unspecified, so the divergence is justified. | None needed; optionally propose a fixed bound for `spec/simulation-http-v1.md` upstream. |
| SDA-14 | 7 | minor (fixed here) | Stale ledger text: `packages/petrus-telemetry/PARITY.md` said the regeneration example "is pending without `upstream/petrus/.venv`" (it fails, via `pythonExecutable`) and listed workers, dispatch, Postgres stores, fabric and processes as "components that have no Haskell port yet"; the top-level Telemetry row said "unported components"; the top-level hosts row quoted the superseded whole-Turn run (1.20×/1.34×/1.31×, lowest 1.10×) instead of the current one (1.33×/1.32×/1.22×, lowest 1.21×, `bench/results-hosts.md`). | Corrected in this commit. |
| SDA-15 | 6 | minor | Telemetry overhead at the `profile` level (gauges every firing) and of a span-heavy Worker path is not benchmarked; only `off`/`facts` per-emit and two 1 000-firing chains are (`packages/petrus-telemetry-instrumentation/bench/RESULTS.md`). | Add a `profile`-level row to the chain benchmark. |

## Verdicts per outcome (this slice)

1. **Pinned parity — holds, weakened.** Every suite reads the pinned checkout, `scripts/check-pins`
   runs first in CI, and the live differential suites (simulation, observation, http-core,
   telemetry, custody, Codex) follow the pin automatically. Committed vectors elsewhere would not
   notice a pin move (SDA-8).
2. **Conformance — does not hold.** Simulation, observation HTTP, HTTP core, telemetry and agenticus
   map every non-live upstream test, and the spec documents' requirements have executable checks.
   But 28 upstream DST functions are not checked in Haskell, including the generated Engine
   campaigns (SDA-1, blocker; SDA-2), and the opt-in live-provider acceptance tests have no
   Haskell equivalent (SDA-3).
3. **Interoperability — holds for the HTTP protocols, with gaps elsewhere.** Both services are
   byte-identical to upstream in both directions (raw Haskell client vs Python server, upstream
   urllib tests vs Haskell server, viewer backend against both). Custody, Codex ledgers, the Pi
   ledger and runner state match both ways. Gaps: telemetry failure fields differ (SDA-4), the
   retention ledger is checked Python→Haskell only (SDA-5), and DST exchange is not exercised live
   (SDA-11).
4. **Fabric/processes contract — not applicable to this slice.**
5. **Better the Haskell way — mostly holds.** Divergences are documented with rationales, and none
   changes an HTTP response, schema or persisted byte except SDA-4 (telemetry fields) and the
   documented, justified edge cases (SDA-12, SDA-13). The shared SDK sidecar is an acceptable
   design but its multi-client behavior is untested (SDA-6). The DST checker rationale is
   inaccurate and forces `unsafePerformIO` (SDA-9).
6. **Performance — holds where measured.** Every committed row in this slice is ≥1.0× (from 1.02× to
   34×), on equivalent twins with interleaved rounds. Uncovered real-use paths: Pi native, Pi A5
   and model-phase Turns, the Codex A3 service round trip, and the profile-level telemetry
   overhead. The Pi ledger cycle margin rests on thin evidence (SDA-7, SDA-15).
7. **Verifiability — holds.** CI runs `scripts/check-all` on every push and pull request, with
   PostgreSQL and Docker, and `lint-skips` forbids silent skips on a missing reference. Every suite
   here passed locally from a clean worktree. PARITY rows were accurate except the stale text
   fixed under SDA-14 and the DST row's silence on its exclusions (SDA-2).
