# petrus-dst divergences

What differs from `petrus.testing.dst` at the pin (`3f85fc2`), and why.

**Wire formats do not diverge.** These all match the reference byte for byte, checked against
vectors generated from the pinned Python (see [PARITY.md](PARITY.md)):

- artifacts v1 to v4;
- replay results;
- digests;
- choice streams;
- process-runner specs, progress frames and results.

The divergences fall into three groups: API shape, where Haskell types replace run-time checks;
reporting detail; and input limits.

## API shape

### Profiles are records, not protocols

`ScenarioProfile` becomes `Profile m g`, a record of door functions polymorphic in the monad `m`
and the generation type `g`. `Checker` becomes a record too.

- The World stores the generation as a typed value. The reference compares `object()` instances
  instead.
- A version-4 profile still declares `resourceUsage` as an optional door. Leaving it out under a
  `BudgetV4` raises the reference's `TypeError` (`a version-4 DST profile must define
  resource_usage`).

### Doors raise `ProfileError`

A door signals failure with `ProfileError {errorType, errorMessage}`: the class name and
`str()` it would have raised in Python.

- The World passes it through unchanged, as `ProfileRaised`, just as the reference propagates a
  profile's exception unchanged.
- Raising the World's own class names (`BudgetExhausted`, `InvariantViolation`) does not turn
  into a World failure. The `not-reclassified` story checks this.

### The scenario context is structural

`create`, `load`, `apply` and `observe` run in `Scenario m`. Its only services are `now`,
`stableId` and `faults`.

- A door cannot reach the World at all. So the reference's run-time re-entrancy refusal
  (`ScenarioProfile cannot recursively enter the World interpreter`) has nothing to guard.
- The context cannot outlive its door.
- `validate`, `validate_fault`, `drop`, `close` and `resource_usage` get no context, as in the
  reference.

### Checkers are pure Mealy machines

A checker's `check` is a `Check`: an initial memory `s` and a pure step
`s -> Observation -> Either ProfileError (CheckResult, s)`. Most checkers are stateless
(`pureCheck`, memory `()`). The reference's checkers are objects, and one of them
(`GeneratedRuntimeAuthorityChecker`) keeps a dictionary across the checks of one World. Here
that memory is an explicit value. The World threads it from one check to the next and starts
every World or replay from the checker's initial memory. So verdicts stay pure and independent
of the World's monad, and a checker value can sit in a registry and serve any number of
replays. The reference's documented requirement (an independent property over a detached
observation) stays a type.

An effectful `Checker m` (a `check` door in the World's monad, like a profile door) was tried
and rejected. It would let a checker read anything at all, and it would make a registry hold
checker factories rather than checkers. One stateful checker needs a fold, not effects.

### Static guarantees replace run-time `TypeError`s

These checks are enforced by types, so they have no run-time counterpart:

- `GenerationStart.scheduled` is a list of `ScheduledCommand`. The reference raises `TypeError`
  for a non-tuple.
- `ApplyResult`, `CheckResult` and `ResourceUsage` are constructed values.
- A bool can never pass as an integer anywhere in the API.

The decoders still refuse such data in artifacts and specs, with the reference's messages.

### Authored finishes take `AuthoredDisposition`

`Timeline.finish` accepts `Converged | Quiescent | ExternalWait | Quarantined`. The reference
takes any `Disposition` and refuses the failure dispositions at run time.

### Index draws take `IndexAuthority`

`chooseIndex` accepts `WorkloadChoice | FaultChoice | EventOrderChoice`. The reference's
`index(ChoiceAuthority.IDENTIFIER, …)` raises `ValueError`. Here it cannot be written:
identifiers go through `chooseIdentifier`.

### World and Timeline are `WorldT` operations

`World.step`, `Timeline.command` and the rest run in `WorldT m g`, a state monad over the
interpreter. `withWorld` builds a World, runs a computation and always closes it, as the
reference's `try`/`finally world.close()` idiom does. A refused operation is a `DstFailure`
value, so `tryWorld` replaces `pytest.raises`.

### Process entrypoints are a static table; the child re-executes the program

The reference imports `module:function` in a fresh `python -c` child. A Haskell program cannot
import by name. Instead:

- The program registers its entrypoints in a `Map Text Entrypoint`, keyed by the same
  `module:function` strings.
- The program calls `processChildHook` first in `main`.
- `runProcessScenario selfChildCommand` re-executes the running binary with a hidden argument.
- `ChildCommand` can name any other executable that does the same.

The spec, progress protocol, watchdog, process group, signals and result are unchanged. An
unknown entrypoint fails the scenario as the reference's failed import does. The `failed`
frame is identical; only the class and message of the child-internal exception differ.

### A process session runs one computation

`ProcessSession.world(...)` returns a World object. `sessionWorld session config body` instead
validates and acknowledges the World metadata, then runs `body` against the World. The World
stays open until the child closes the session, as in the reference.

A second `sessionWorld` raises the reference's `DstError` (`a DST process session owns exactly
one World`), with the same progress bytes.

## Reporting detail

### Validation errors report the first error only

A refused artifact or spec raises `ContractViolation "ValidationError"`. Its message is
`1 validation error for <Model>`, then the location line, then `  <msg> [type=<type>]`.

- The error is always one that pydantic also reports, with the same location, type and
  message. The differential tests check exactly this.
- pydantic may report several errors at once. It also appends `input_value=…, input_type=…` and
  a documentation URL. The port reproduces neither.
- Union-tag errors quote the tag the way pydantic does (`'None'`, `'True'`, `'[]'`, …).
- After pydantic's recursion guard refuses a too-deeply nested JSON value (`recursion_loop`),
  pydantic-core also refuses later values of the same validation that are the same Python
  object (small integers, for one), so the reference may report spurious extra errors. The port
  reports the first error, which is the guard's.

### Very deep JSON is refused as `recursion_loop`

Acceptance of nested JSON values matches the reference exactly. Every JSON value field
(`JsonValue`) is refused once pydantic's recursion guard would trip: 255 guard entries, one per
value, counting the definitions above the field. The guard applies to artifacts, run specs,
progress frames, and the models the World builds, including its journal entries. See
`jsonValueRecursion` in `Petrus.Testing.Dst.Decode`.

Deeper still, the reference fails differently. For values nested past about 993 levels, its
recursive `_strict_json` raises `RecursionError` before pydantic runs. The exact depth depends
on the Python stack at the call. Past CPython's C stack limit, `json.loads` raises
`RecursionError` too. The port has no stack-dependent limits:

- it refuses such a value with the same `recursion_loop` validation error it reports from 255
  levels;
- it refuses a document nested past petrus-json's 100000-level parser limit as invalid strict
  DST JSON.

## Input limits

### Lone UTF-16 surrogates in object keys are refused

CPython's loader admits lone surrogates from `\ud800` escapes or `surrogatepass` decoding. The
port admits them in string values too: petrus-json keeps such a string as WTF-8, and the loader,
the validators and the canonical encoder agree with the reference on it byte for byte (the
raw-bytes corpus and `Spec.ToolingInterop` exchange such an artifact both ways). A lone surrogate
in an object key is refused with `invalid strict DST JSON: the payload contains a lone UTF-16
surrogate in an object key, which this port cannot represent`. The raw-bytes corpus pins that
case. No committed fixture contains one.

Why it stays: the reference re-encodes an artifact through pydantic-core's
`model_dump(mode="json")`, which treats keys differently from values: a `JsonValue` object key
holding a lone surrogate is written with one U+FFFD per byte of the surrogate's `surrogatepass`
encoding (so `"\ud83d"` becomes `"���"`, and keys that collide that way merge, the last value
winning), and a typed `dict[str, int]` key holding one raises `UnicodeEncodeError`. Matching that
means reproducing pydantic-core's serializer field by field; a clean refusal is the smaller and
safer difference.

## Additions

None of these change behavior.

- `Petrus.Testing.Dst.Transcript` replays an artifact against a recorded system under test. It
  was the stand-in for the Engine before the Haskell Engine existed. It now cross-checks every
  door call, including for the joined Postgres worlds, independently of the real profiles (see
  the Engine seam in [PARITY.md](PARITY.md)).
- `Petrus.Testing.Dst.Internal.Canonical` is a specialized encoder for the canonical
  `json.dumps` spelling. It produces exactly petrus-json's bytes, which a QuickCheck property
  and every corpus check. It exists for speed (`bench/RESULTS.md`).

## Engine worlds (`petrus-dst:engine-worlds`)

The ported `tests/dst/*_world.py` modules are test code, not library API. Their artifacts,
replay results and checker verdicts are byte-identical to the reference's. Their shape differs
in four ways.

- **Class hierarchies become records.** A reference subclass such as
  `HistoryRefusalEngineProfile(EngineProfile)` overrides protected hooks (`_history`,
  `_dispatch`, `_bridge`, `_configure_faults`, `_observation_state`) and some public doors. In
  the port:
  - the hooks are fields of a `Base` record;
  - a subclass is a `Base` value plus record updates on the `Profile` that `baseProfile`
    builds.

  The retry family (`RetryEngineProfile` and its two subclasses) is one constructor with a
  `RetryKind`.
- **Handlers are pure, so a bridge's effects run as the Engine's handler observer.** The
  Engine calls an `ActivityHandler`'s `prepare` and `project` as pure functions. The
  reference's bridges count their calls, and some read an armed fault. Every world builds its
  bridge as a `Bridged` value (the pure `prepare`/`project`, plus `onPrepare`/`onProject`
  effects) and installs it with `Petrus.Testing.Dst.Engine.Bridge.withBridge`, which binds the
  pure handler and passes the effects as `EngineOptions.handlerObserver`. The Engine's writing
  door runs that observer exactly once before each call, and a `Left` from it is the bridge
  raising. The authored journals, which record `prepared` and `projected` at every
  observation, prove the counts equal the reference's.
- **The stateful generated-runtime checker threads its memory.**
  `GeneratedRuntimeAuthorityChecker` keeps `_frozen_execution_counts` across the checks of one
  instance. `generatedRuntimeChecker` is a pure `Check` whose memory is that dictionary (see
  "Checkers are pure Mealy machines"). Every World or replay starts it empty, just as the
  reference constructs a fresh instance.
- **Exceptions map to Python class names.** A door's exception becomes the reference's
  `(type(error).__name__, str(error))`, which the profiles compare for expected faults:
  - profile adapters raise `PyException "OSError" message`;
  - Engine refusals map from `EngineError`;
  - LocalDispatch refusals map from `DispatchError`, as `ValueError`.

The authoring tests compare the Haskell stories with the reference builders' current output, in
`test/data/engine-authored.json`, rather than with the committed fixtures. Three retained
fixtures are older versions than what the builders now author:

- `projection-crash-recovery-world-v1.json`;
- the two v2 failure fixtures.

Those fixtures are replay-only in both runtimes, and replay through the real profiles in
`Spec.EngineWorlds`.

## Joined worlds (`petrus-dst:joined-worlds`)

The ported `tests/dst/joined_*world.py` modules are test code too. Their artifacts, replay
results and checker verdicts are byte-identical to the reference's. Everything said above for
the Engine worlds applies (records instead of class hierarchies, bridges installed through
`Engine.Bridge.withBridge`, Python class names for exceptions). They differ in two more ways.

- **The fault connection wraps session seams, not a DB-API connection.** The reference's
  `JoinedFaultConnection` subclasses the psycopg connection and intercepts `execute`, `commit`
  and `rollback`. The Haskell Engine talks to PostgreSQL through an `AbsurdSession` record
  (`petrus-engine-absurd`), so `faultSession` wraps its fields instead: the Dispatch statements
  (`run`), the History store's batches (`observeHistory`, which names the semantic records each
  batch inserts), and the transaction's fate (`commit`, `rollback`). The cut points are the same:
  a refusal fires before the delegate commits, an acknowledgement loss after it, and each fires
  for exactly one armed boundary. The recorded attempts (`accepted`, `record_types`, `dispatched`)
  are identical, which every authored journal proves.
- **Checkers fail closed on malformed evidence.** The reference's checkers index observation
  members and compare numbers directly, so a missing member or a non-numeric counter raises
  `KeyError` or `TypeError` out of `check`. The Haskell checkers are total: such evidence fails
  the comparison it appears in and the verdict is `passed = false`. Observations the profiles
  produce are always well formed, so no artifact or replay can tell the difference; it shows
  only for hand-built observations, and the 35 recorded checker vectors contain none.

## DST tooling (`petrus-dst:campaigns`, `petrus-dst-world`)

The ported `tests/dst/` tooling (`replay.py`, `failure.py`, `campaign.py`, `boundaries.py`,
`generated_runtime_qualification.py` and the generated-schedule state machines) keeps the
reference's file formats, so artifacts, failure bundles and legacy replay results cross between
the languages (`Spec.ToolingInterop`). The pytest and Python runtime around it differs.

- **The CLI is one executable.** The reference runs `python -m tests.dst.replay_world`,
  `tests.dst.replay`, `tests.dst.failure` and `tests.dst.campaign`. Here they are the routes
  `replay`, `legacy-replay`, `failure`, `campaign` and `boundaries` of `petrus-dst-world`. Their
  arguments, standard output and exit statuses are the reference's. A refusal prints
  `Class: message` to standard error.
- **A campaign child is `petrus-dst-world campaign-profile NAME`, not a pytest node.** The
  reference runs `python -m pytest -q NODE --forbid-skips --hypothesis-seed=SEED` per profile.
  The child receives the same environment (tier, seed, case-log path) and has the same timeout
  and output bounds. The report's `node` is that command line.
- **Runtime identity.** Campaign reports and failure manifests name the runtime that made them.
  The reference records Python and its packages, so here the `python` member holds the GHC
  version and `dependencies` lists `hedgehog` and `petrus-dst`. `Spec.ToolingInterop` compares
  manifests without it.
- **Failure bundles keep the reference's replay command.** A manifest's `replay.command` is the
  reference's literal (`uv run python -m tests.dst.failure replay {bundle}`), which both
  languages validate, so a bundle replays through either one. `petrus-dst-world failure
  demonstrate` prints its own route as `replay_command`.
- **Boundary owners are hspec selections.** Each production-boundary profile names the Haskell
  test that owns the same claim, as its Cabal suite and an hspec `--match` path (PARITY.md lists
  them), not a pytest node:
  - one child per suite, with every selected path of that suite;
  - the children run in sequence under one wall clock (`PROFILE_TIMEOUT_SECONDS`);
  - `--fail-on=empty,pending` stands in for `--forbid-skips`;
  - the binaries are the ones `cabal build` left under `dist-newstyle`.

  The lock is the reference's file, taken with `flock(2)` as `fcntl.flock` takes it, so a
  Haskell and a Python qualification exclude each other. The reference finally removes Docker
  containers labelled for its PostgreSQL fixture; the Haskell owners start no containers, so
  there is nothing to remove.
- **Hedgehog runs the generated schedules.** The state machines, strategies and settings map
  rule for rule (PARITY.md, "Generation method"). A Hedgehog example ends at its first failing
  step, before its own teardown steps; everything after the example's `forAll` runs inside a
  `bracket` (`bracketExample`), so its World still closes when that example ends, as the
  reference's `finally` closes it.
- **Case counts differ.** With the same settings, Hedgehog runs exactly `max_examples`
  examples. Hypothesis runs some examples that it does not count towards `max_examples`, so it
  may run more. For example, the ordinary `runtime-focused` campaign records 10 cases here and
  14 in the reference. In both, a report's `cases` is at least `examples_target`. The schedules
  themselves differ too: the two runners use the same seed but different generators.

## A reference quirk, reproduced

The generated-script property found one quirk: a budget refusal after the World has already
ended still records a failure operation. In the reference:

1. The World ends with `budget_exhausted`.
2. A second over-budget command records a second `FailureOperation`.
3. `artifact()` then refuses with `a failed DST artifact must end with exactly one failure
   operation`.

The port does the same, operation for operation. The `failure-after-end` story pins it against
the reference. Fixing it belongs upstream: the World should refuse operations after it has ended
(`DST World already ended as …`) before checking budgets.
