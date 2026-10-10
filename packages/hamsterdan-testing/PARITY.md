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

### Corpus suite

| Spec | Examples | What it checks |
| --- | ---: | --- |
| `OracleCorpusSpec` | 2 | Every corpus row is checked for admission or refusal (with the rule), the facts dump digest, the expectation dump and 12 liveness verdicts. The corpus must cover refusals, named rules and every disposition. |

**Suite total:** 43 examples, 0 failures.

## Benchmarks

See [bench/RESULTS.md](bench/RESULTS.md). The Haskell and Python runs were
interleaved, and the load average is noted. Haskell is faster on every row:

- `evaluate`: 11.6×;
- `load` + `evaluate`: 1.7×;
- `evaluate_liveness`: 22.8×.

## Gaps

- **Only the oracle is ported.** The rest of the testing surface is planned
  for this package but not started. That includes the deterministic World
  and its campaigns (`src/hamsterdan/host/testing`) and the deterministic
  journeys (`tests/integration/host/test_readiness_scenarios.py`). Both need
  `hamsterdan-host`.
