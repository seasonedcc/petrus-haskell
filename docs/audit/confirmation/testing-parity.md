<!-- Dated record: confirmation audit at d869f62 (2026-10-12). Every finding is resolved or decided; see ../final.md. -->

# Confirmation audit: testing parity

Area: do the Haskell suites check every behavior that the upstream suites check? This covers petrus, hamsterdan, petrus-viewer and petrus-engine at their pins. It also covers the Hypothesis ports, skip and pending hygiene, PARITY.md test counts, a deep sample of upstream tests, and the earlier findings FA-T-1 to FA-T-6.

Method: everything was read-only. No cabal build was run. Upstream suites were collected with `pytest --collect-only` in the upstream venvs, using `python -I`. The results are in `testing-parity/{petrus,ham,eng}-collect.txt`. The reference CI run is 38232074972: main, success, log at `testing-parity/ci-38232074972.log`. The repository scripts were run as they are.

**Summary: BLOCKER 0, MAJOR 3, MINOR 4.**

---

## 1. Earlier findings (final-audit/testing-parity.md)

| ID | Status | Evidence |
|---|---|---|
| FA-T-1: agenticus-core Hypothesis ports used a fixed seed, but upstream does not derandomize | **Resolved in code; docs stale (see MAJOR-1)** | Commit 244295a. `packages/petrus-agenticus-core/test/Petrus/Agenticus/Support.hs` now has `hypothesisSettings maxExamples = modifyMaxSuccess (const maxExamples)`, with no `mkQCGen`. The code comment is corrected. I also checked that the seed is random upstream: Hypothesis 6.164.0 `core.py:712-729` seeds non-derandomized tests from `Random()`. pytest-randomly 4.1.0's `_reseed` seeds random, factory_boy, faker, model_bakery, numpy and entry points, and never Hypothesis. |
| FA-T-2: the delivery machine ran "up to" N steps; upstream runs exactly N | **Resolved in code; header comment stale (MAJOR-1)** | Commit 83ca23e. `packages/hamsterdan-testing/test/ReadinessCampaignSpec.hs:180` and `Gen.sequential (Range.singleton (steps - 1))` (the initialize rule counts as a step). The test title now says "exactly stateful_step_count=5 steps, start and 4 rules". |
| FA-T-3: the Git enumeration silently skipped the cases upstream's World refuses | **Resolved** | Commit 83ca23e. The Hedgehog property uses `when (unrecoveredAfterAcceptance lost cut) H.discard` (upstream uses `assume`). The enumeration has 14 cases. A separate test (`ReadinessCampaignSpec.hs:175`) pins the refused schedule as a test-oracle divergence. `packages/hamsterdan-testing/PARITY.md:117` and `DIVERGENCES.md:136-160` are updated. |
| FA-T-4: petrus-dst PARITY misdescribed upstream's postgres_dsn fixture | **Resolved** | `packages/petrus-dst/PARITY.md:252-254` now says the fixture fails loudly. That matches upstream `tests/conftest.py`. |
| FA-T-5: wrong count of petrus tests/project cases in the not-ported table | **Resolved** | Root `PARITY.md` "Upstream tests not ported" table, about lines 82-96: 3+4+1+1+14 = 23 cases. I checked this against `petrus-collect.txt`. |
| FA-T-6: EffectSpec `genText` did not draw the full code-point range | **Resolved** | Commit 0312854. `genText` now uses `choose ('\0','\x10FFFF') \`suchThat\` (not . surrogate)`. That matches `st.text()`, which excludes surrogates by default. |

---

## 2. Findings

### MAJOR-1: the FA-T-1 and FA-T-2 fixes changed the code but left docs that describe the old behavior

- `packages/petrus-agenticus-core/PARITY.md:28-34`: "pytest-randomly seeds Hypothesis from it, so the reference draws the same examples on every run. `hypothesisSettings n` … fixes QuickCheck's generator at `mkQCGen 1729`". Both claims are now false. Upstream is not derandomized, and `hypothesisSettings` no longer fixes a seed.
- `packages/petrus-agenticus-core/parity/effect.md:22` and `parity/catalog.md:45`: "with the generator fixed at seed 1729". False.
- `docs/runtime.md:5976-5977`: "Hypothesis is seeded from it". This is the false premise FA-T-1 was about, and it is still stated as reference fact.
- `packages/hamsterdan-testing/test/ReadinessCampaignSpec.hs:10-13`: the module header still says the delivery machine runs "of up to @stateful_step_count@ rules". The code now runs exactly `stateful_step_count` steps, as FA-T-2 asked.
- Root `PARITY.md:136`: "`test_readiness_campaign.py` (6, as 11 examples …". The spec now has 12 examples, not counting the command round-trip property: the FA-T-3 refusal test at `:175` is new.

**Why it matters.** Outcome 2 requires the same Hypothesis settings and seeding, and the parity docs are where a reader confirms that. Outcome 7 requires the repo to show what is at parity. Today the docs claim the opposite of what the code does on the exact point the earlier audit fixed. The runtime.md sentence would also lead the next porter to reintroduce the fixed seed.

**Fix.** Rewrite these places to say:
- Upstream draws fresh examples each run, because Hypothesis seeds from OS entropy and pytest-randomly does not reseed it.
- The ports therefore use QuickCheck's per-run seed, with only `maxSuccess` matching upstream.
- Upstream derandomizes only where it sets `derandomize=True`, and those ports keep a fixed seed: `InstanceReplayPropertiesSpec` and the hamsterdan campaigns.

Fix the "up to" in the header and the 11 → 12 count.

### MAJOR-2: two upstream Pi application tests have no Haskell body, and their ledger row says they do

- `packages/petrus-agenticus-runtime/test/Petrus/Agenticus/Runtime/PiApplicationSpec.hs:1074-1078`: `test_exact_helper_core_loop_fake_stream_is_one_turn_delta_only_and_authority_free` and `test_exact_installed_application_package_probe` are unconditional `pendingWith` stubs. They pend on every machine, with or without the packages or the opt-in variable.
- Upstream (`tests/agenticus/runtime/test_pi_application.py`, about lines 1040-1100) runs the first whenever `/tmp/petrus-pi-a2-probe` holds the exact packages. It runs the second when `PETRUS_CV16_PI_APPLICATION_QUALIFY=1` is also set. Each has a real body that drives the helper's core loop over a fake stream, or probes the installed application package.
- `packages/petrus-agenticus-runtime/parity/pi.md:297-298` says "Pending unless the qualification packages are installed" and "Pending, as upstream, unless the packages and the opt-in variable are present". Neither is true: there is no code path that runs them.
- As a result, `probeApplication` (`src/.../PiApplication.hs:90`) is not exercised by any test.
- The sibling port shows the right pattern. `PiModelPhaseSpec.hs:763-790` gates on the probe directory and runs the real body when it is present.
- `scripts/check-pending` OPT_INS lists both messages as legitimate opt-ins. So the gate, if it worked (see MAJOR-3), would accept stubs that can never run.

**Why it matters.** Outcome 2 requires every behavior upstream checks to be checked in Haskell. These two are checked upstream whenever the qualification install is present. In Haskell they cannot be checked under any conditions, and the ledger hides that.

**Fix.** Port both bodies behind the same gates upstream uses, the probe directory plus the env var, following `PiModelPhaseSpec`. Keep the pending messages identical to the OPT_INS entries, and correct `pi.md:297-298`.

### MAJOR-3: `scripts/check-pending` sees nothing in CI, so the "no pending example" gate is a no-op on main

**Evidence** (CI run 38232074972, main, success):
- Job `test (2)` printed `petrus-agenticus-runtime-test: passed (445 examples, 12 pending)`, at log line 43796.
- Job `test (9)` printed `petrus-execution-test: passed (881 examples, 2 pending)`, at line 25324.
- Yet all 63 `check-pending` invocations in the run, both the per-suite calls from `ci-tests run-shard` and the workflow step `scripts/check-pending "$RUNNER_TEMP/test-logs"` (`.github/workflows/*.yml:230-231`), printed `no pending example except 0 declared opt-ins`. None of the 14 pending examples in the run was seen.

**Cause.**
- In CI, hspec writes colored output. The log lines are `ESC[33m    # PENDING: …ESC[0m`, and the summary line is colored too.
- `scripts/ci-tests` `wrap` (`scripts/ci-tests:691-702`) tees the binary's raw stdout into `SUITE.log`, escapes included.
- `scripts/check-pending:85-86` anchors `PENDING = ^\s*# PENDING: (.*)$` and `SUMMARY = ^\d+ examples?, …$`. Neither matches a line that starts with `ESC[33m`.
- So `scan` finds no pending lines and no summary. The safety net in the docstring ("A suite whose log has neither cannot hide one") is skipped, because `summarised` is false.

**Reproduction** (scratch only, `testing-parity/simlog/`):
- A log with a colored, *undeclared* `# PENDING: some brand new undeclared reason` and a colored summary makes `scripts/check-pending` exit 0 with "no pending example".
- The same log without the escapes exits 1 and names the pending example.

Locally, `scripts/check-all` writes `--test-log` files without a tty, so the gate probably works there. Only CI, which checks every main change, is blind.

All 14 pending messages in this run are currently declared opt-ins. I checked every `# PENDING:` line in the log against OPT_INS. So nothing is hidden today. But a missing `node`, `dot` or PostgreSQL server in a CI image, or a new `pendingWith`, would pass CI green. Those are exactly the cases the script was written to catch. The PostgreSQL case is partly covered by `ci-tests` refusing to run without `PETRUS_TEST_POSTGRES`. The `node` case (for example `CustodyInteropSpec.hs:261`) is not covered.

**Why it matters.** Outcome 7 says "every main change checked by CI", and the "pending tests are justified" part of outcome 2 depends on this gate. As it stands, the gate gives false assurance.

**Fix.**
- Strip ANSI SGR sequences in `scan` (`re.sub(r"\x1b\[[0-9;]*m", "", line)`), or run the suites with `--no-color` in `ci-test-wrapper`. Doing both is better.
- Make check-pending fail when a log has no recognizable hspec summary, so that a future format change cannot blind it again.
- Add a fixture test with a colored log.

### MINOR-1: some per-package ledger counts are wrong

- `packages/petrus-agenticus-core/parity/catalog.md:32` says 37 cases; the collection has 35.
- `packages/petrus-agenticus-core/parity/catalog.md:50` says 42; the collection has 44.
- `packages/petrus-agenticus/PARITY.md:11` gives `test_agent_net.py` 35; the collection has 34.

The root counts are right. These package-level numbers are not checked by any script (see MINOR-2). Fix: correct them.

### MINOR-2: `scripts/upstream-test-counts --check` covers only some of the count claims

The script checks 27 phrasings, and all of them match. The following claims are not parsed:
- the not-ported tables' Cases columns;
- root `PARITY.md` lines 45, 46, 54, 55, 62 and 88;
- the hamsterdan per-file counts in the operator and readiness rows;
- the per-package `parity/*.md` tables. MINOR-1 shows these drift.

I checked every root claim by hand (section 4), and all are right today. Fix: extend the script to the package ledgers' count columns, or derive those columns from `docs/upstream-test-counts.json`.

### MINOR-3: the same upstream test is ported twice, so ledgers count it twice

- The test-local `AttemptModel` heartbeat test is ported in `packages/petrus-activity/test/.../HeartbeatSpec.hs:57` and again in `packages/petrus-motus-absurd/test/.../HeartbeatSpec.hs:21-22`.
- The backend-contract suite is duplicated in `packages/petrus-impetus/test/Petrus/Impetus/HistoryStoreSpec.hs` (287 lines) and `packages/petrus-history-store/test/.../BackendContractSpec.hs` (273 lines). About 110 of those lines differ, so the copies already drift.

Fix: keep one copy of the contract suite in a shared test-support library, parameterized by backend, and ledger each upstream test once.

### MINOR-4: some renamed tests cannot be traced mechanically

Most suites keep upstream names as `it` labels, but some packages rename them, for example `hamsterdan-github` `GitHubSpec.hs:395` "exact head selection". So name-based coverage checks have to be done by hand there. Fix: keep the upstream test name as the label, or as a prefix of it, as most packages already do.

---

## 3. Hypothesis inventory (all upstream uses; every row now matches)

| Upstream | Settings / strategy | Haskell port | Seed |
|---|---|---|---|
| petrus `test_instance_replay_properties.py:63` | max_examples=300, derandomize=True | `InstanceReplayPropertiesSpec.hs`: maxSuccess 300, same `genScenario`, `QCM.pick` | fixed (300), correct because upstream derandomizes |
| agenticus `test_contract.py:120` | recursive JSON, max_leaves=20, max_examples=60 | `EffectSpec.hs`: `hypothesisSettings 60`, `genObject 8` / `genJson 20`, full-range `genText` | per run, correct |
| agenticus `test_resolution.py:276` | permutations ×2, max_examples=40 | `CatalogSpec.hs:294`: `hypothesisSettings 40`, shuffle `[0..6]` twice | per run, correct |
| petrus dst `campaign.py` profiles | profile max_examples / step counts | `petrus-dst/campaigns/Petrus/Testing/Dst/Campaign.hs:108-210` | as upstream profiles |
| petrus delivery and runtime state machines | stateful_step_count, initialize rules | `Machines.hs:258,261,531,626`: `Range.singleton steps` (or `steps-1` after an initialize rule) | fixed where upstream derandomizes |
| petrus `failure.py` / generated-runtime-qualification `find` | `find` minimum | `Failure.hs:506-525` `findLivelockMinimum` (withTests 20, Seed 19003) | fixed, as upstream |
| hamsterdan readiness authority | 3 @example + max_examples=6 | `ReadinessCampaignSpec.hs:93-97` | fixed (derandomize=True) |
| hamsterdan readiness timer | 4 @example + 5, `assume` | `:108-130` (discard) + 40-case enumeration | fixed |
| hamsterdan readiness git | 4 @example + 5, `assume` | `:142-175` (discard) + 14-case enumeration + refusal test | fixed |
| hamsterdan delivery machine | max_examples=12, stateful_step_count=5 | `:180`: 12 runs × exactly 5 steps | fixed |
| hamsterdan forced machine | 2 × 2 | ported | fixed |

petrus-viewer uses no fast-check, and petrus-engine has no Hypothesis. The upstream `docs/`, `project/` and `exploration/` directories are outside `testpaths`.

## 4. Counts: what I verified holds

- Collection: petrus 2626 items, 2057 test functions, 125 files. hamsterdan 1297 items, 972 tests, 57 files. petrus-engine 282 items, 281 tests, 15 files.
- All 23 entries of `docs/upstream-test-counts.json` match the collection (script `testing-parity/cmp.py`).
- `scripts/upstream-test-counts --check`: 27 claims, all matching.
- I checked by hand the root `PARITY.md` claims that the script does not parse. All are correct:
  - line 45: local dispatch, 36;
  - line 46: heartbeats Absurd part, 3 tests and 9 cases;
  - line 54: simulation, 19+24 tests and 27+71 items;
  - line 55: telemetry, 29+22;
  - line 62: 119 codex/claude/amp cases;
  - line 88: 23 project cases;
  - hamsterdan: test_pi 42+4 = 46, test_protocol 20, agenticus 33, pi_a2 24, pi_workspace 20, factory 8, operator group 126, container contract 4, readiness world/campaign/coverage 19/6/5, scenarios 11;
  - the not-ported table: 74 cases in 13 files.
- Every upstream test file in all three Python projects appears in some ledger (checked in Python, `testing-parity/pkgcounts.py`).

## 5. Skips and pending: what I verified holds

- `scripts/lint-skips`: 482 sources, clean. Its only allow-comments are in `ContainerSpec.hs`, for the image-interpreter paths, and they are justified.
- The `scripts/check-pending` OPT_INS covers the Docker, E2B, Gondolin, Pi qualification and live-provider gates, each tied to an upstream marker (`real_provider_acceptance`, `real_gondolin_acceptance`, `qualification_installation`).
- Conditional pending sites:
  - `CustodyInteropSpec.hs:261` (`node` missing) and the PostgreSQL `skipMessage` sites are deliberately not opt-ins, so they would fail the gate. That is correct, if the gate worked in CI (MAJOR-3).
  - `Live/Support.hs:131` gates live cells whose bodies are ported (about 2000 lines in `Live/*.hs`).
  - `PiModelPhaseSpec.hs:769` gates on the probe directory and has a real body.
- The only unconditional stubs are the two in MAJOR-2.

## 6. Deep sample (35 upstream tests, pick.py seed 20261012, weighted toward properties, interop and failure paths)

petrus:

| Upstream test | Haskell counterpart | Verdict |
|---|---|---|
| sqlite fenced engines | `SqliteSpec.hs:67` | match |
| dst test_world v4 resource exhaustion | `Spec/Stories.hs:75`, Python-authored vectors | match |
| HTTP content-length lexemes | `HttpSpec.hs:352` | match |
| ingress raising handler | `IngressSpec.hs:281` | match |
| async worker partial thread start | `AsyncWorkerSpec.hs:332` | match |
| codex rollout continue | `CodexSpec.hs:1127` | match |
| postgres activity terminal index | `PostgresSpec.hs` | match |
| delivery float instant | `DeliveryPhasesASpec.hs:221` | match |
| catalog snapshot decoder | `CatalogSpec.hs:282` | match |
| heartbeat details | petrus-activity `HeartbeatSpec.hs:84` | match |
| construction over recorded history | `BackendContractSpec.hs:178`, also impetus `HistoryStoreSpec.hs:185` (MINOR-3) | match |
| local dispatch tampering | `LocalSpec.hs:285` | match |
| instance identity | `InstanceIdentitySpec.hs:98` | match |
| every appending door | `HistoryCodecSpec.hs:557`, over the mirrored store (documented) | match |
| joined registration ack loss | `JoinedWorlds.hs:177` | match |
| pi a4 cancellation | `PiSpec.hs:703` | match |
| delayed terminal | `EngineWorlds.hs:101` (author cases) | match |
| postgres concurrent race | `PostgresSpec.hs:260` | match |
| DSL nested stamps | DSL spec; the cycle half is documented as unrepresentable (`petrus-dsl/DIVERGENCES.md:99-102`) | partial, justified |
| exploration identity | not ported, ledgered (outside testpaths) | justified |
| test_exact_helper_core_loop… / test_exact_installed_application_package_probe | stubs | **gap (MAJOR-2)** |
| instance replay properties | `InstanceReplayPropertiesSpec.hs` | match |
| payload digest property | `EffectSpec.hs` | match |
| registration order property | `CatalogSpec.hs:294` | match |

hamsterdan:

| Upstream test | Haskell counterpart | Verdict |
|---|---|---|
| config credentials without disclosure | `AppFoundationSpec.hs:211` | match |
| readiness close deferred announcement | `ReadinessSpec.hs:614` | match |
| escalation moved repair | `EscalationSpec.hs:181` | match |
| github exact head selection | `GitHubSpec.hs:395` (renamed, MINOR-4) | match |
| removed agent route settings | `AgenticusSpec.hs:248` | match |
| v5 gates retryable exhaustion | `GatesSpec.hs:356` (`shouldBeVariant` is full equality) | match |
| timers exact arm | `TimersSpec.hs:88` | match |
| lifecycle close | lifecycle spec | match |
| readiness campaigns (4 properties + machine) | `ReadinessCampaignSpec.hs` | match |

petrus-engine and petrus-viewer:
- net_path, restore_state (skipped upstream), dsl_builder and tokens are out of scope (`SCOPE.md:15`, `petrus-engine-file/PARITY.md` §5).
- In-scope loader cases such as duplicate_net_names and duplicate_resolved_mount are in the 923-case corpus.
- For the viewer, `packages/petrus-viewer-server/upstream-tests/run.mjs` runs every server-side upstream test file, and the groups in `scripts/ci-tests:717-721` cover every suite it knows.

## 7. CI

Run 38232074972 (main) is green. The Hypothesis-port tests ran and passed. The lint job ran `lint-skips`, `upstream-test-counts --check`, and check-parity ("76 of 76 components at parity"). The pending gate ran but was blind (MAJOR-3).
