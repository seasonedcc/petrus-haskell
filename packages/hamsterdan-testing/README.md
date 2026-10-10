# hamsterdan-testing

This package ports Hamsterdan's deterministic-simulation support from
`upstream/hamsterdan`. Today it holds the independent expected-readiness
oracle, `src/hamsterdan/testing/readiness.py`.

The oracle knows only normalized external facts:

- provider and admitted authority;
- CI and review evidence;
- human gates;
- mutation, effect and timer obligations.

From these it computes the readiness verdict a correct host must reach:
disposition, blockers and safety violations. It also classifies bounded
convergence (`evaluateLiveness`) without blaming an unfair environment. It
deliberately does not depend on the readiness topology, Petrus or the host.

Every value loads and dumps exactly as the reference's `StrictValue`. Every
verdict matches the reference byte for byte, as a committed corpus proves
(see [PARITY.md](PARITY.md)). Intentional API differences are listed in
[DIVERGENCES.md](DIVERGENCES.md).

## Modules

| Module | Ports | Key API |
| --- | --- | --- |
| `Hamsterdan.Testing.Readiness` | `testing/readiness.py` | **Facts:** `AuthorityClaim`, `AuthorityFacts`, `CheckFacts`, `CiFacts`, `Finding`, `ReviewFacts`, `HumanFacts`, `ChangeAuthorization`, `MutationFacts`, `EffectObligation`, `TimerObligation`, `ReadinessFacts`, `ReadinessExpectation`, `FairEnvironment`. **Vocabularies:** their enumerations and `spell`. **Defaults:** `readinessFacts`, `ciFacts`, `reviewFacts`, `humanFacts`, `mutationFacts`, `effectObligation`, `timerObligation`. **Functions:** `load`, `loadJson`, `dump`, `checked`, `evaluate`, `evaluateLiveness`, `declared` |

## Using it

```haskell
import Hamsterdan.Testing.Readiness

verdict :: ReadinessFacts -> Either Text ReadinessExpectation
verdict facts = evaluate <$> checked facts   -- refuse what the reference refuses

liveness :: ReadinessExpectation -> LivenessDisposition
liveness expectation =
  evaluateLiveness expectation (FairEnvironment True True True True True) True
```

## Tests, corpus, benchmarks

```sh
cabal test hamsterdan-testing -j2 --test-options='+RTS -M2G -RTS'
cabal bench hamsterdan-testing -j2 --benchmark-options='+RTS -M2G -RTS'
upstream/hamsterdan/.venv/bin/python -I -B packages/hamsterdan-testing/scripts/gen_oracle_corpus.py
```

Benchmark results against Python are in [bench/RESULTS.md](bench/RESULTS.md).
