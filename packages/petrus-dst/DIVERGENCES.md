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

### Checkers are pure

`check :: Observation -> Either ProfileError CheckResult`. The reference's checkers are objects
that could hold state. A Haskell checker cannot, which makes the reference's documented
requirement (an independent property over a detached observation) a type.

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

## Input limits

### Lone UTF-16 surrogates are refused

CPython's loader admits lone surrogates from `\ud800` escapes or `surrogatepass` decoding.
Haskell `Text` cannot hold them. The strict loader refuses such input with
`invalid strict DST JSON: the payload contains a lone UTF-16 surrogate, which this port cannot
represent`.

The raw-bytes corpus pins exactly which inputs this affects. No committed fixture contains one.

### No recursion limit on nested JSON values

The reference refuses JSON values nested past its validators' recursion guard. A command
payload of nested lists is refused:

- from 255 levels, with pydantic `recursion_loop`;
- from 993 levels, with `RecursionError`.

Nested objects hit the guard one level earlier. The exact depth depends on where the value sits
and on what kind of containers it holds.

These limits come from the Python implementation, not the format. The port admits any depth and
re-encodes it byte for byte, which the codec spec tests up to depth 5000. No fixture comes
within two orders of magnitude of the limit.

## Additions

None of these change behavior.

- `Petrus.Testing.Dst.Transcript` replays an artifact against a recorded system under test. It
  is the stand-in for the Engine until the Haskell Engine exists (see the Engine seam in
  [PARITY.md](PARITY.md)).
- `Petrus.Testing.Dst.Internal.Canonical` is a specialized encoder for the canonical
  `json.dumps` spelling. It produces exactly petrus-json's bytes, which a QuickCheck property
  and every corpus check. It exists for speed (`bench/RESULTS.md`).

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
