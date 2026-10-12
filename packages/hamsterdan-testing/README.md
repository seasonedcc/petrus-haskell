# hamsterdan-testing

This package ports Hamsterdan's deterministic-simulation support from
`upstream/hamsterdan`. It holds three parts:

- the independent expected-readiness oracle,
  `src/hamsterdan/testing/readiness.py`;
- the eleven deterministic readiness journeys of
  `tests/integration/host/test_readiness_scenarios.py`, run through the
  real V5 host;
- the deterministic readiness World, `src/hamsterdan/host/testing/*`: the
  V5 host under Petrus DST v4 (`petrus-dst`), with its profile, checker,
  replay and semantic coverage report.

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

## The World

`Hamsterdan.Testing.World` is the readiness profile for Petrus DST: a
deterministic external world (modeled GitHub, agents and Git) around the
real V5 host. A test drives it through a Timeline (`setPullRequest`,
`setCi`, `emitWebhook`, `deliverWebhook`, `crash`, `converge`, …), and the
independent checker compares the host with the oracle at every boundary.
`artifact` retains the run as a `petrus.testing.dst/v4` artifact, and
`replayReadiness` replays one. The artifacts, replay results and coverage
reports are the reference's bytes, so either language replays the other's
artifacts with the same verdict.

## Modules

| Module | Ports | Key API |
| --- | --- | --- |
| `Hamsterdan.Testing.Readiness` | `testing/readiness.py` | **Facts:** `AuthorityClaim`, `AuthorityFacts`, `CheckFacts`, `CiFacts`, `Finding`, `ReviewFacts`, `HumanFacts`, `ChangeAuthorization`, `MutationFacts`, `EffectObligation`, `TimerObligation`, `ReadinessFacts`, `ReadinessExpectation`, `FairEnvironment`. **Vocabularies:** their enumerations and `spelling`. **Defaults:** `readinessFacts`, `ciFacts`, `reviewFacts`, `humanFacts`, `mutationFacts`, `effectObligation`, `timerObligation`. **Functions:** `load`, `loadJson`, `dump`, `checked`, `evaluate`, `evaluateLiveness`, `declared` |
| `Hamsterdan.Testing.Journeys` | `tests/integration/host/test_readiness_scenarios.py` | `Journey` (the eleven journeys), `journeyName`, `journeyFromName`, `Phase`, `phasesOf`, `phaseName`, `runJourney`, `driveJourney`, and the upstream module's constants (`headSha`, `blockingFinding`, `heroFindings`, `changeDiff`, …) |
| `Hamsterdan.Testing.World` | `host/testing/readiness_world.py` | `readinessProfile`, `readinessChecker`, `newReadinessWorld`, `newReadinessWorldWith`, `timeline`, `restart`, `artifact`, `closeWorld`, the Timeline facade (`ReadinessTimeline`, `setPullRequest`, `setCi`, `setReview`, `setHumanComment`, `setAgentTerminal`, `emitWebhook`, `deliverWebhook`, `loseEffectResponse`, `faultEffect`, `faultGitPublication`, `advanceTime`, `observe`, `runUntil`, `crash`, `converge`, …), `replayReadiness` |
| `Hamsterdan.Testing.World.Contract` | `host/testing/_readiness_contract.py` | `profileIdentity`, `checkerIdentity`, `defaultBudget`, `withProfileResource`, the World's constants |
| `Hamsterdan.Testing.World.Provider` | `host/testing/_readiness_provider.py` | the modeled provider truth and its effects |
| `Hamsterdan.Testing.World.Coverage` | `host/testing/readiness_coverage.py` | `CoverageRun`, `CoverageReport`, `collectReadinessCoverage`, `encodeReadinessCoverage`, `loadReadinessCoverage`, `covered`, `blocked` |
| `Hamsterdan.Testing.World.Scenarios` | (the interop and benchmark scenarios) | `scenarios`, `authorScenario` |

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

The interop examples ("journeys against the reference", "World interop
against the reference") need the pinned Python, which
`scripts/upstream-python hamsterdan` provisions.

```sh
cabal test hamsterdan-testing -j2 --test-options='+RTS -M2G -RTS'
cabal bench hamsterdan-testing -j2 --benchmark-options='+RTS -M2G -RTS'
upstream/hamsterdan/.venv/bin/python -I -B packages/hamsterdan-testing/scripts/gen_oracle_corpus.py
```

Benchmark results against Python are in [bench/RESULTS.md](bench/RESULTS.md).
