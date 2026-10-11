# hamsterdan-testing

This package ports Hamsterdan's deterministic-simulation support from
`upstream/hamsterdan`. Today it holds two parts:

- the independent expected-readiness oracle,
  `src/hamsterdan/testing/readiness.py`;
- the eleven deterministic readiness journeys of
  `tests/integration/host/test_readiness_scenarios.py`, run through the
  real V5 host.

## The oracle

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

## The journeys

Each journey drives one pull request through the `hamsterdan-host` V5 host.
It goes from the first webhook to a ready, blocked or repaired outcome,
against a scripted GitHub (`ScenarioProvider`) and scripted agents
(`ScenarioRunner`). The three journeys that publish (agent repair, stale
base update, true conflict resolution) do so through the host's real Git
publisher, into a local bare repository.

A journey's result is the upstream `JourneyResult` as JSON. A journey can
also run in spans of its phases, one host lifetime per span. The `carry`
between spans is the JSON that `differential/journeys_reference.py` reads
and writes, so a Python span can resume a Haskell span and the reverse. The
interop suite compares results and state directories with the Python
journeys, byte for byte.

## Modules

| Module | Ports | Key API |
| --- | --- | --- |
| `Hamsterdan.Testing.Readiness` | `testing/readiness.py` | **Facts:** `AuthorityClaim`, `AuthorityFacts`, `CheckFacts`, `CiFacts`, `Finding`, `ReviewFacts`, `HumanFacts`, `ChangeAuthorization`, `MutationFacts`, `EffectObligation`, `TimerObligation`, `ReadinessFacts`, `ReadinessExpectation`, `FairEnvironment`. **Vocabularies:** their enumerations and `spell`. **Defaults:** `readinessFacts`, `ciFacts`, `reviewFacts`, `humanFacts`, `mutationFacts`, `effectObligation`, `timerObligation`. **Functions:** `load`, `loadJson`, `dump`, `checked`, `evaluate`, `evaluateLiveness`, `declared` |
| `Hamsterdan.Testing.Journeys` | `tests/integration/host/test_readiness_scenarios.py` | `Journey` (the eleven journeys), `journeyName`, `journeyFromName`, `Phase`, `phasesOf`, `phaseName`, `runJourney`, `driveJourney`, and the upstream module's constants (`headSha`, `blockingFinding`, `heroFindings`, `changeDiff`, …) |

## Using it

```haskell
import Hamsterdan.Testing.Readiness

verdict :: ReadinessFacts -> Either Text ReadinessExpectation
verdict facts = evaluate <$> checked facts   -- refuse what the reference refuses

liveness :: ReadinessExpectation -> LivenessDisposition
liveness expectation =
  evaluateLiveness expectation (FairEnvironment True True True True True) True
```

```haskell
import Hamsterdan.Testing.Journeys

-- The whole journey in a fresh directory, then the same journey in two
-- host lifetimes over another one (`member` reads one object member).
journeys :: FilePath -> FilePath -> IO (Json, Json)
journeys root other = do
  whole <- runJourney AgentRepair root
  let phases = length (phasesOf AgentRepair)
  first <- driveJourney AgentRepair other (0, 1) Nothing
  second <- driveJourney AgentRepair other (1, phases) (Just (member "carry" first))
  pure (whole, member "result" second)   -- equal
```

## Tests, corpus, benchmarks

The interop examples ("journeys against the reference") need the pinned
Python, which `scripts/upstream-python hamsterdan` provisions.

```sh
cabal test hamsterdan-testing -j2 --test-options='+RTS -M2G -RTS'
cabal bench hamsterdan-testing -j2 --benchmark-options='+RTS -M2G -RTS'
upstream/hamsterdan/.venv/bin/python -I -B packages/hamsterdan-testing/scripts/gen_oracle_corpus.py
```

Benchmark results against Python are in [bench/RESULTS.md](bench/RESULTS.md).
