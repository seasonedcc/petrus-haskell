# hamsterdan-testing parity

This file lists what this package ports from `upstream/hamsterdan` (pinned in
[UPSTREAM.md](../../UPSTREAM.md) at `5d382467`) and the evidence for each
piece.

Every expectation in the corpus was produced by the pinned Python running
`scripts/gen_oracle_corpus.py`:

- `upstream/hamsterdan/.venv`
- Python 3.14.6
- pydantic 2.13.4

The Haskell suite compares bytes.

## Upstream source → Haskell

| Upstream | Haskell | Evidence |
| --- | --- | --- |
| `testing/readiness.py` vocabularies (`Lifecycle`, `CheckStatus`, …, `LivenessDisposition`) | sum types with `spelling` (contracts' `Enumeration`) | **Oracle corpus.** Every spelling is admitted and dumped through the corpus. |
| The 14 `StrictValue` dataclasses, with their defaults and `__post_init__` rules | `Hamsterdan.Testing.Readiness` records, each with a strict `Contract` codec. `load`, `loadJson` and `dump` are `StrictValue.load` and `StrictValue.dump`. `checked` is the validating constructor. | **`test/corpus/oracle.jsonl`:** 2000 documents. Each must be admitted or refused as the reference does. The 8 construction rules are named: when a rule is the sole refusal, its exact message must appear. Each admitted document's strict dump must match by SHA-256 of its compact spelling. |
| `ReadinessModel.evaluate` | `evaluate` | **Oracle corpus.** 1658 admitted documents cover all six dispositions, every blocker family and every violation family. Each must produce the reference's `ReadinessExpectation` dump, byte for byte. |
| `evaluate_liveness` | `evaluateLiveness` | **Oracle corpus.** Each verdict is checked under six environments (all conditions declared, then each one withheld) times both budget flags. |
| `FairEnvironment.declared` | `declared` | `ReadinessModelSpec` |
| `tests/integration/host/test_readiness_scenarios.py`: `ScenarioProvider`, `ScenarioRunner`, the Git fixtures, `_run_journey` and the eleven `run_*` journeys | `Hamsterdan.Testing.Journeys`: `runJourney`, `driveJourney`, `Journey`, `Phase`, `phasesOf`, the upstream constants | **Journeys against the reference.** All 11 journeys match the Python journey byte for byte, run whole and cross-resumed both ways (see below). The 11 upstream tests pass under their upstream names. |
| `host/testing/readiness_world.py`: `ReadinessProfile`, `ReadinessChecker`, `ReadinessWorld`, `ReadinessTimeline`, `replay_readiness` | `Hamsterdan.Testing.World`: `readinessProfile`, `readinessChecker` / `checkReadiness`, `newReadinessWorld`, the Timeline facade, `replayReadiness` | **World interop against the reference** (below): 20 scenarios, artifacts byte-identical, each language's artifact replays in the other with identical result bytes. 19 upstream World tests. |
| `host/testing/_readiness_contract.py` (identities, budget, command vocabulary, bounded JSON) | `Hamsterdan.Testing.World.Contract` | Profile and checker identity digests asserted by `test_profile_and_checker_compatibility_identities_are_stable`; every command payload is part of the compared artifacts. |
| `host/testing/_readiness_provider.py` (modeled GitHub, agent and Git truth) | `Hamsterdan.Testing.World.Provider` | Its state is in every observation, so in every compared artifact and checker verdict. |
| `host/testing/readiness_coverage.py` | `Hamsterdan.Testing.World.Coverage`: `collectReadinessCoverage`, `encodeReadinessCoverage`, `loadReadinessCoverage` | Each interop scenario's coverage report is byte-identical to the reference's. 5 upstream coverage tests. |

## Upstream tests

`tests/unit/testing/test_readiness_model.py` is ported in full in
`test/ReadinessModelSpec.hs`. Each upstream test keeps its name, and each
parametrized case is one hspec example. Every facts value goes through
`checked` before it is evaluated, so a test value the reference could not
construct fails the test.

| Upstream file | Functions | Cases | Haskell spec | Examples | Parametrization |
| --- | ---: | ---: | --- | ---: | --- |
| `test_readiness_model.py` | 29 | 34 | `ReadinessModelSpec` | 34 + 7 | Three functions are parametrized: incarnation-bound kinds (dashboard, conversation, reminder), change kinds (coding, git_mutation), and inactive lifecycles (draft, merged, closed). |

There are 7 more examples, under "construction rules". They test each
`__post_init__` message the reference enforces but tests only through the
subject rule.

`test_model_values_fit_the_supported_petrus_detached_contract` builds a
`petrus-dst` `Observation` and `CheckResult` from the model's dumps. It also
checks `apiCompatibility`, `artifactFormat` and `resultVersion`. Haskell
`petrus-dst` has no `ARTIFACT_VERSION` constant: the version is read off a
decoded artifact. The `petrus.testing.dst/v4` API pins it to 4.

`tests/integration/host/test_readiness_scenarios.py` is ported in full in
`test/ReadinessScenariosSpec.hs`. Each upstream test keeps its name and
makes the upstream test's assertions about the `JourneyResult`. The journeys
themselves run in `Hamsterdan.Testing.Journeys`, so the interop suite and
the benchmarks can run them too. They run through the real V5 host
(`hamsterdan-host`): its custody, its SQLite stores, its Local Dispatch
Worker, and, for the journeys that publish, its real Git publisher over a
local bare repository.

| Upstream file | Functions | Haskell spec | Examples | Notes |
| --- | ---: | --- | ---: | --- |
| `test_readiness_scenarios.py` | 11 | `ReadinessScenariosSpec` | 11 | `test_clean_green_user_journey` also checks that `evaluate` of the journey's model facts is ready, as upstream does. `test_hero_review_user_journey` runs the journey twice and compares the two results, as upstream does. |

### Corpus suite

| Spec | Examples | What it checks |
| --- | ---: | --- |
| `OracleCorpusSpec` | 2 | Every corpus row is checked for admission or refusal (with the rule), the facts dump digest, the expectation dump and 12 liveness verdicts. The corpus must cover refusals, named rules and every disposition. |

### Journeys against the reference

`differential/journeys_reference.py` runs each journey in the pinned Python,
through the upstream `run_<name>` function itself, unchanged. It applies the
four determinism seams listed in [DIVERGENCES.md](DIVERGENCES.md), and
nothing else. Its `dump` reads a state directory back the same way for both
languages. SQLite databases become their schema and sorted rows, and every
other file becomes its text. Two things are normalized there, and neither is
in History: the per-process Worker claimant, and the Local Dispatch's
wall-clock milliseconds.

`ReadinessScenariosSpec` ("journeys against the reference") runs four
examples per journey, 44 in all. Each one compares the journey `result`
(the `JourneyResult`: every GitHub request and write, every posted comment,
review and status, the agent calls and results, the Git reconciliations and
publications, and the snapshots) and the whole `state` directory with the
Python journey's:

| Example | First half | Second half |
| --- | --- | --- |
| the whole journey | Haskell, in one host lifetime | none |
| Haskell then Haskell | Haskell | Haskell, in a new host over the same directory |
| Python then Haskell | Python | Haskell, resuming Python's state and carry |
| Haskell then Python | Haskell | Python, resuming Haskell's state and carry |

The split is at half of the journey's phases (`Open`, then `Draft`,
`StaleBase`, `Collaboration` or `FollowUp` as the journey has them). The
`carry` between halves is the same JSON in both languages: provider truth,
runner state, the journey's snapshots and the next delivery number.

All 44 examples pass. Every result and every state directory, including
History, the timer store, custody, the routes and the Local Dispatch, is
identical to the Python journey's. `scripts/interop` runs this group.

### The World, its campaigns and coverage

`tests/integration/testing/test_readiness_world.py`,
`test_readiness_campaign.py` and `test_readiness_coverage.py` are ported in
full. Each upstream test keeps its name and its assertions. The World runs
over the Haskell `petrus-dst` (Petrus DST v4) and the real V5 host
(`hamsterdan-host`).

| Upstream file | Functions | Haskell spec | Examples | Notes |
| --- | ---: | --- | ---: | --- |
| `test_readiness_world.py` | 19 | `ReadinessWorldSpec` | 19 | The `monkeypatch` of `HostService._record_posture` is a `ServiceHooks.aroundRecordPosture` hook installed through `newReadinessWorldWith`. |
| `test_readiness_campaign.py` | 6 | `ReadinessCampaignSpec` | 13 (12, plus a property that every rendered readiness command parses back to itself) | Generated by upstream's method, with fixed seeds and shrinking (see [DIVERGENCES.md](DIVERGENCES.md)). `test_timeline_steps_one_disclosed_host_action`: 1 example. Authority lifecycle: 2 examples, its 3 `@example` cases and a Hedgehog property over upstream's strategies with `max_examples=6`. Reminder timer: 3 examples, its 4 `@example` cases, a Hedgehog property with `max_examples=5` (the `assume` is a `discard`), and on top an enumeration of all 40 cases the `assume` admits. Git publication: 4 examples, its 4 `@example` cases, a Hedgehog property with `max_examples=5` that discards the unrecovered sub-domain below, an enumeration of the other 14 cases, and a separate test of the 2 unrecovered cases (a test-oracle divergence, see below). Delivery recovery: 1 example, a Hedgehog state machine with `max_examples=12` whose every run has exactly `stateful_step_count=5` steps, as Hypothesis's runs do: the `start` rule (`@initialize`) and 4 rules. The invariant is checked after `start` and after every rule. Forced checker failure: 1 example, `max_examples=2` and `stateful_step_count=2`; the shrunk failure's retained artifact replays exactly. The delivery machine's former enumeration floor (8 branch seeds × every rule sequence up to 2, 56 runs) was dropped because it cost 46.5 s. The campaign took 149.7 s (6 examples) before the change and 189.1 s (11 examples) after, at load averages of about 3–4. |
| `test_readiness_coverage.py` | 5 | `ReadinessCoverageSpec` | 5 | The `monkeypatch` of `ReadinessChecker.check` is a custom `Checker` passed to `newReadinessWorldWith`. |

**A test-oracle divergence: the unrecovered Git sub-domain.** The Git
enumeration includes schedules upstream's five Hypothesis examples never
draw: a crash right after the Git ref is accepted, with no response fault
(`not response_lost and crash_cut == "after_acceptance"`). On those two
schedules (`redeliver` false or true) the Haskell campaign does not run
upstream's test body
(`test_generated_v5_git_publication_recovery_schedules_replay_exactly`,
`test_readiness_campaign.py:738-760`), which asserts that the run completes
with every invariant holding. Upstream's own World refuses both schedules:
the independent model fails the boundary after the moved head's CI is set
(`ready_parity` and `progress_disclosed` false), and running the upstream
test body on them in the pinned Python raises the same
`InvariantViolation`. A test asserting upstream's oracle there would fail
in both languages, so the Haskell port asserts the reference World's
verdict instead: an invariant failure whose retained artifact replays
exactly. The sub-domain is its own named test ("an unrecovered crash after
the ref is accepted fails the reference World's own invariant (test-oracle
divergence)"); the generated property discards it and the enumeration
excludes it, so every other Git test checks upstream's oracle unchanged.
The `git-after_acceptance-unrecovered` interop scenario shows that both
languages fail it identically, with the same artifact bytes.

### World interop against the reference

`differential/world_reference.py` authors named scenarios through the
pinned Python's `ReadinessWorld`, replays artifacts with
`replay_readiness`, and collects coverage. `Hamsterdan.Testing.World.Scenarios`
holds the same 20 scenarios: the Timeline call sequences of the World tests,
each campaign's `@example` cases, the coverage fixture, and the unrecovered
Git schedule above. Several end in a budget exhaustion or invariant failure.

`WorldInteropSpec` ("World interop against the reference") runs four
examples per scenario, 80 in all:

| Example | Compares |
| --- | --- |
| the Haskell World authors the reference's artifact bytes | `encode_artifact` bytes of both Worlds |
| the reference's artifact replays in Haskell with the reference's result bytes | canonical replay-result bytes |
| the reference's artifact has the reference's coverage report bytes | `encode_readiness_coverage` bytes |
| the Haskell artifact replays in the reference with the Haskell result bytes | canonical replay-result bytes, the other way |

All 80 pass: every artifact (`petrus.testing.dst/v4`), replay result and
coverage report is byte-identical. An 81st example checks the coverage
per-artifact byte measure against pydantic's `model_dump_json` length on
2045 generated values (`differential/dump_json_lengths.py`).
`scripts/interop` runs this group.

**Suite total:** 215 examples, 0 failures (34 + 7 model, 2 corpus, 11
journeys, 44 journeys against the reference, 19 World, 12 campaign, 5
coverage, 81 World interop).

## Benchmarks

See [bench/RESULTS.md](bench/RESULTS.md). The Haskell and Python runs were
interleaved, and the load average is noted. Haskell is faster on every row:

- **Oracle:** `evaluate` 11.6×; `load` + `evaluate` 1.7×;
  `evaluate_liveness` 22.8×.
- **Journeys, end to end:** 3.3× to 7.0× for the eight journeys without Git
  publication. For the three with real `git` processes: `agent_repair`
  1.7×, `stale_base_update` 2.0×, `true_conflict_resolution` 1.9×.
- **World, four scenarios:** authoring 2.2× to 3.0×; replay 1.7× to 2.4×.

## Gaps

None. The divergences are listed in [DIVERGENCES.md](DIVERGENCES.md).
