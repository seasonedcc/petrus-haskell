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
| `testing/readiness.py` vocabularies (`Lifecycle`, `CheckStatus`, …, `LivenessDisposition`) | sum types with `spell` (`Spelled`) | **Oracle corpus.** Every spelling is admitted and dumped through the corpus. |
| The 14 `StrictValue` dataclasses, with their defaults and `__post_init__` rules | `Hamsterdan.Testing.Readiness` records, each with a strict `Contract` codec. `load`, `loadJson` and `dump` are `StrictValue.load` and `StrictValue.dump`. `checked` is the validating constructor. | **`test/corpus/oracle.jsonl`:** 2000 documents. Each must be admitted or refused as the reference does. The 8 construction rules are named: when a rule is the sole refusal, its exact message must appear. Each admitted document's strict dump must match by SHA-256 of its compact spelling. |
| `ReadinessModel.evaluate` | `evaluate` | **Oracle corpus.** 1658 admitted documents cover all six dispositions, every blocker family and every violation family. Each must produce the reference's `ReadinessExpectation` dump, byte for byte. |
| `evaluate_liveness` | `evaluateLiveness` | **Oracle corpus.** Each verdict is checked under six environments (all conditions declared, then each one withheld) times both budget flags. |
| `FairEnvironment.declared` | `declared` | `ReadinessModelSpec` |
| `tests/integration/host/test_readiness_scenarios.py`: `ScenarioProvider`, `ScenarioRunner`, the Git fixtures, `_run_journey` and the eleven `run_*` journeys | `Hamsterdan.Testing.Journeys`: `runJourney`, `driveJourney`, `Journey`, `Phase`, `phasesOf`, the upstream constants | **Journeys against the reference.** All 11 journeys match the Python journey byte for byte, run whole and cross-resumed both ways (see below). The 11 upstream tests pass under their upstream names. |

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

**Suite total:** 98 examples, 0 failures (34 + 7 model, 2 corpus, 11
journeys, 44 journeys against the reference).

## Benchmarks

See [bench/RESULTS.md](bench/RESULTS.md). The Haskell and Python runs were
interleaved, and the load average is noted. Haskell is faster on every row:

- **Oracle:** `evaluate` 11.6×; `load` + `evaluate` 1.7×;
  `evaluate_liveness` 22.8×.
- **Journeys, end to end:** 3.3× to 7.0× for the eight journeys without Git
  publication. For the three with real `git` processes: `agent_repair`
  1.7×, `stale_base_update` 2.0×, `true_conflict_resolution` 1.9×.

## Gaps

- **The deterministic World and its campaigns are not ported.** This covers
  `src/hamsterdan/host/testing/*` over Petrus DST v4: `ReadinessWorld`, the
  readiness profile and checker, `replay_readiness` and the semantic
  coverage report. Its upstream tests are not ported either:
  `tests/integration/testing/test_readiness_world.py`,
  `test_readiness_campaign.py` and `test_readiness_coverage.py`.
