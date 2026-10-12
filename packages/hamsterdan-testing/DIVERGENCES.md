# hamsterdan-testing divergences

These are the intentional differences from `upstream/hamsterdan`'s
`testing/readiness.py`. None of them changes a wire format. The oracle
corpus checks the following byte for byte against the pinned Python (see
[PARITY.md](PARITY.md)):

- every admission decision;
- every strict dump;
- every expectation;
- every liveness verdict.

## API

1. **Validation happens at the codec, not at construction.**
   - The reference's frozen pydantic dataclasses validate in their
     constructors. That covers both strict types and `__post_init__`.
   - Haskell records do not validate. Every rule lives in the record's
     codec, so `load`, `loadJson` and `checked` refuse exactly what the
     reference's constructor refuses.
   - `checked` re-validates a value built in Haskell. It is the
     reference's constructor.
   - `evaluate` and `evaluateLiveness` are total over any value, including
     one the reference could not build.
2. **Refusal text names the first failure.**
   - pydantic's `ValidationError` lists every failing member.
   - The codec reports the first one as `path: reason`.
   - A construction rule's message is the reference's exact text, such as
     `$: authority identities must be positive`. The corpus checks it
     whenever that rule is the reference's only refusal.
3. **`Literal` vocabularies are enumerations.** For example, `Lifecycle`,
   `EffectKind` and `ReadinessDisposition` are sum types with one
   constructor per spelling. Their wire spelling is `spelling` (contracts'
   `Enumeration`). An invalid spelling cannot be constructed, and decoding
   refuses exactly what pydantic refuses.
4. **The model is two functions.**
   - The stateless class `ReadinessModel().evaluate` is `evaluate`.
   - `evaluate_liveness(…, budget_exhausted=b)` is
     `evaluateLiveness expectation environment b`.
   - The property `FairEnvironment.declared` is the function `declared`.
5. **Defaults are named values.**
   - Python's keyword defaults become named values: `readinessFacts subject
     authority`, `ciFacts`, `reviewFacts`, `humanFacts`, `mutationFacts`,
     `effectObligation`, `timerObligation`.
   - A test changes fields with record update.
6. **`StrictValue.load` takes bytes.** `load` takes UTF-8 bytes, and
   `loadJson` takes an already parsed value.

## Journeys

These are the differences between `Hamsterdan.Testing.Journeys` and
`tests/integration/host/test_readiness_scenarios.py`. None of them shows in
a journey's result or state: the interop suite compares both with the
Python journey's, byte for byte, whole and cross-resumed (see
[PARITY.md](PARITY.md)).

1. **Four determinism seams, applied on both sides.** The upstream module
   is not deterministic across processes, so it cannot be compared byte for
   byte as it stands. `differential/journeys_reference.py` applies these
   seams around the unchanged upstream `run_<name>`, and the Haskell
   journeys build them in:
   - **Delivery ids.** Upstream draws them from `uuid.uuid4()`. Both sides
     count instead: `00000000-0000-0000-0000-000000000001`, then `...2`.
   - **Host clock.** Upstream's `HostService` reads the system clock. Both
     sides fix it at 1786838400.0 (`clockSeconds`).
   - **Git fixtures.** Upstream commits at the current time under the
     user's Git configuration. Both sides commit at
     `2001-01-01T00:00:00Z` (`gitDate`), with `GIT_CONFIG_GLOBAL=/dev/null`
     and `GIT_CONFIG_NOSYSTEM=1`. The fixture commits, and so every head
     the journey publishes, are then the same in every run.
   - **Intent order.** The reference builds the V5 application's `_ALLOWED`
     from a `frozenset`, so the last three allowed intents a conversation
     request declares come in the process's string-hash order. The driver
     patches `_ALLOWED` to source order (`change`, `update_base`,
     `resolve_conflict`). That is the order the Haskell host always uses
     (`mutations` in `Hamsterdan.Host.V5.Application`).
2. **The publisher clones the fixture's remote by its `file://` URL.**
   Upstream gives the real `HostGitPublisher` the public clone URL
   `https://github.com/owner/repo.git`. Its Git environment then rewrites
   that URL to the local bare repository with a `url.<remote>.insteadOf`
   entry (`GIT_CONFIG_KEY_2`). The Haskell host's Git environment is a
   constant, with no seam to patch, so the journeys hand the publisher the
   remote's `file://` URL directly. The publisher runs the same `git`
   commands against the same repository. The URL does not appear in any
   result, state file or History record.
3. **The publication is observed through `reconcileHook`.** Upstream
   monkeypatches `HostGitPublisher.reconcile` and `.publish` to record each
   call. Because `publish` calls `self.reconcile`, the record also holds
   the reconciliations inside a publication. Haskell records cannot be
   patched that way. The journeys wrap `publish` directly, and observe
   every reconciliation through the publisher's `reconcileHook`. That field
   was added to `hamsterdan-host`'s `HostGitPublisher` for this purpose; it
   defaults to no hook. It also sees the `self_caused_head` keyword exactly
   when upstream passes it.
4. **Phases and carry.** Upstream runs a journey as one function. The
   Haskell journey is split into phases (`Phase`, `phasesOf`), and
   `driveJourney` runs a span of them in one host lifetime. Each span
   leaves a `carry` for the next: provider truth, runner state, snapshots
   and the next delivery number. The reference driver's `drive` command
   splits the upstream journey the same way and reads and writes the same
   carry, so either language can resume the other's half. A host opened
   on an existing state directory has loaded no application yet. So "has
   an unresolved publication" answers `False` until the application loads,
   as the reference host answers for an application it has not loaded.
5. **Results are JSON.** `runJourney` returns the `JourneyResult` as the
   plain JSON the reference driver prints, not as a record. The upstream
   tests' assertions read that JSON.

## World, campaigns and coverage

These are the differences between `Hamsterdan.Testing.World` (with its
`Contract`, `Provider`, `Coverage` modules and the specs) and upstream's
`src/hamsterdan/host/testing/*` and `tests/integration/testing/*`. None of
them changes an artifact, a replay result, a checker verdict or a coverage
report: the World interop suite compares all four with the reference's,
byte for byte, in both directions (see [PARITY.md](PARITY.md)).

1. **Webhook ingress calls the host's custody directly.** Upstream posts
   each delivery through a FastAPI `TestClient` over
   `create_app(host, reconcile_startup=False)`. The Haskell World hands the
   same headers and body to the host's `Custody.receive`, which is what that
   route runs. A refusal the route would answer with 400
   (`WebhookRejected`) or 500 (a Python-class exception) raises upstream's
   `AssertionError` naming that status.
2. **Injection seams instead of `monkeypatch`.** Upstream's tests patch
   `HostService._record_posture` and `ReadinessChecker.check`. Haskell
   records cannot be patched, so `newReadinessWorldWith` takes a `prepare`
   action (which can install `ServiceHooks`, such as
   `aroundRecordPosture`, on the profile's hosts) and the `Checker` to run.
   `newReadinessWorld` is `newReadinessWorldWith` with neither.
3. **Hypothesis campaigns are Hedgehog campaigns.** Upstream draws with
   Hypothesis (`derandomize=True`, so a fixed seed), with a few examples
   per test plus explicit `@example` cases. Haskell uses the same method
   with Hedgehog, from a fixed seed and with shrinking:
   - **authority lifecycle:** the 3 `@example` cases, then a Hedgehog
     property over upstream's strategies (seed `0..2^53-1`, path, and
     before/after lists of at most one action) with `max_examples=6`.
   - **delivery recovery machine:** a Hedgehog state machine
     (`Gen.sequential`/`executeSequential`) with `max_examples=12` whose
     every run has exactly `stateful_step_count=5` steps, as Hypothesis's
     runs do: `start` and 4 rules (`Range.singleton`). `start` draws its seed as
     `@initialize` does. Upstream's rule preconditions read the live
     timeline. "Execute one disclosed action" and "redeliver after
     quiescence" partition its states, so the machine has two rules: `Act`,
     whichever of those two is enabled, and `Restart`. The invariant runs
     after `start` and after every rule (an `Ensure` callback), as
     Hypothesis runs it, and the teardown runs upstream's convergence and
     replay. Every draw happens before anything runs, so a shrunk case
     reruns from a fresh World.
   - **forced checker failure:** the same machine with only the forced
     rule (`max_examples=2`, `stateful_step_count=2`). Hedgehog shrinks the
     failure, and the exact artifact retained for it replays its invariant
     failure.
   - **reminder timer and Git publication:** the 4 `@example` cases each,
     then a Hedgehog property over upstream's strategies with
     `max_examples=5`. For the timer, upstream's `assume` becomes a
     `discard`. On top of these come exhaustive enumerations: all 40 timer
     cases the `assume` admits, and the 14 Git cases upstream's test body
     passes. The other 2 Git cases (no response loss, crash after
     acceptance) are a test-oracle divergence: the Git property discards
     them, and a separate test asserts the reference World's own invariant
     failure there (see PARITY.md). Each enumeration
     covers every generated dimension except the World seed, which is the
     case's index.

   Hypothesis' `event(...)` labels become Hedgehog `label`s. In the
   enumerations they become the "falsifying example" line a failing case
   prints. A failing Hedgehog property reports the shrunk case together
   with the seed and shrink path that rerun it. In every campaign, the
   artifact's `origin.seed` is asserted as upstream asserts it.
4. **Retained counterexamples go under `dist-newstyle/`.** A campaign
   example that fails with `BudgetExhausted` or `InvariantViolation`
   retains its exact artifact, and checks that it replays its failure, as
   upstream's `_retain_failure_artifact` does. Upstream writes to
   `.hypothesis/readiness-artifacts/`; Haskell writes to
   `dist-newstyle/readiness-artifacts/` (ignored by Git). The note upstream
   adds to the primary exception is printed to stderr.
5. **Two upstream-refused Git schedules assert the refusal.** See "An
   upstream finding" in [PARITY.md](PARITY.md). Upstream's campaign never
   draws them, and its World fails them. The Haskell enumeration does draw
   them, and so may the Hedgehog property, so both assert the reference's verdict (a retained invariant
   failure that replays exactly) rather than the convergence the upstream
   test body would assert.
6. **The coverage per-artifact byte bound — resolved.** Upstream bounds
   `len(artifact.model_dump_json().encode())`. Haskell used to bound the
   canonical bytes, which escape non-ASCII text and spell floats as
   CPython's `repr`. `modelDumpJsonLength` now measures what pydantic-core
   writes (raw UTF-8, `serde_json` control escapes, `1e+16`/`1e-6`/
   `0.00001` float layout), checked against pydantic on 2045 generated
   values (`WorldInteropSpec`, `differential/dump_json_lengths.py`).
7. **`ValidationError` text is pydantic-shaped, not pydantic's.** A
   refusal from `loadReadinessCoverage` has the class (`ValidationError` or
   `ValueError`) and, for the model validators, the reference's exact
   message (for example "covered dimension requires complete scenario
   evidence"). A schema refusal reports the first failing member as
   `1 validation error for ReadinessCoverageReport`, its location and
   `[type=…]`, where pydantic lists every failing member. Why it stays:
   `load_readiness_coverage` has no caller in the reference beyond its
   tests, which match the class and a fragment, and pydantic's full text
   (every error with its truncated `input_value` repr and the
   `errors.pydantic.dev/2.13/v/…` link) is pydantic-core's report format,
   not a Hamsterdan contract.
