# Divergences: Thread lifecycle, Agent Program descriptors, runtime foundation values

Every wire format (`to_data` key order, `json.dumps` bytes) and every refusal
(class, message, check order) matches the reference; the differential corpus
checks this.  What differs is how the Haskell types carry the values.

## Identities are distinct types

`ThreadId`, `ContinuationId`, `EpisodeId` and `TurnId` are separate newtypes.
Upstream subclasses one dataclass so that equal text in different roles is
unequal at runtime; here mixing roles does not type-check.  The refusal
message keeps the upstream class name (`"EpisodeId value must be …"`).

## Thread transitions do not revalidate earlier Episodes

Upstream Thread transitions `dataclasses.replace` the Thread, which reruns
`__post_init__` over every Episode, so each transition is linear in Thread
length and building a Thread is quadratic (51.7 s for 1 000 Episodes of 4
Turns).  Here:

* every Episode-level transition still revalidates its Episode in full,
  exactly as upstream;
* Thread transitions (`startEpisode`, `startTurn`, `acceptAppend`,
  `settleTurn`, `requestCancellation`, `settleEpisode`, `closeThread`) run
  only the checks the transition can violate.  The Thread-level invariants
  that concern earlier Episodes (unique Episode ids, adjacent Continuation
  revisions, unique result Continuation ids, Episode/Thread ownership) are
  preserved by construction once the transition's own refusals pass:
  `startEpisode` refuses duplicate ids and claims the resting revision;
  `settleEpisode` refuses foreign, unavailable, mismatched or already-known
  result Continuations before the Episode settles.

The observable result is identical, and the differential replay checks it:
after each of the 1 371 accepted Thread-level trace steps, the resulting Thread must
round-trip through `threadFromData` (full validation) unchanged.  `mkThread`
and `threadFromData` run the complete upstream validation.

The duplicate-id scan in `startEpisode` and the known-Continuation scan in
`settleEpisode` remain linear, as upstream; nothing else is.

## `IncompatibleContinuation` carries its result through two channels

Upstream raises `IncompatibleContinuation(result)`; the exception has
`.result`.  The Haskell lifecycle functions return
`Either AgenticusError …`, and `AgenticusError` has no payload slot, so:

* `requireContinuationCompatible` returns
  `Either IncompatibleContinuationError ()`, where
  `IncompatibleContinuationError {result :: CompatibilityResult}` is also an
  `Exception`; `incompatibleContinuationError` converts it to the
  `AgenticusError` (class `IncompatibleContinuation`, upstream message);
* `startEpisode` surfaces that `AgenticusError`; the result it refused on is
  `threadContinuationCompatibility program thread`, a pure function of the
  same inputs, computed before anything executes.

## Error attributes become accessors

* `EpisodeBudgetExceeded.dimension` → `budgetExceededDimension`.
* `RuntimeProtocolError.code` → `runtimeProtocolErrorCode`.
  `runtimeProtocolError code` returns the `ValueError` upstream's constructor
  raises when the code is not a machine token.

## Representations

* Enum constructors carry a type prefix (`TurnCompleted`, `EpisodeCompleted`,
  `CancellationTooLate`, `ContinuationInUse`, `RuntimeCleanupClean`,
  `ProbeReady`, …) because several enums share spellings; wire values are
  unchanged (`StrEnum` class, `enumText`).
* `Episode.turns` and `Thread.episodes` are `Data.Sequence.Seq`, so appending
  and replacing the final element are O(1)/O(log n).
* `RuntimeInstallation.capabilities` is a `Set Text`; components and probe
  issues are stored sorted, like upstream.
* `ProgramSeams directive trace evaluation` keeps the program-native types
  as type parameters; steering and evaluation are `IO` functions.
* `ContinuationCodec payload` and `RuntimeOperation` are records of `IO`
  functions instead of structural Protocols.  `RuntimeOperation.wait` takes
  the bound in seconds (`Maybe Double`) and throws an `AgenticusError` of
  class `TimeoutError` on expiry.
* `Show` for `Continuation` omits `stateReference`, and `Show` for
  `RuntimeTurnSettlement` omits both references, mirroring
  `field(repr=False)`.
* Constructor-argument type checks (`isinstance`, `type(x) is bool`) have no
  counterpart: the types rule those inputs out.  Their JSON-decoding
  equivalents (`… must be a boolean`, `… must be a JSON array`, …) are kept.
* The runtime foundation values (`Runtime.Installation`, `Runtime.Result`,
  `Runtime.Operation`) live in `petrus-agenticus-core` because they are pure
  and the lifecycle-adjacent packages need them without the runtime adapters.

## Probe issues with a shared code

`RuntimeProbeResult` sorts its issues.  Upstream sorts `(code, component)`
tuples, so two issues with the same code where only one names a component
make `sorted()` raise a raw `TypeError` (`'<' not supported between
instances of 'NoneType' and 'str'`; which operand comes first depends on
timsort's comparison order).  Haskell orders an absent component first and
accepts the value.  This is the only reference behavior not reproduced; the
corpus does not generate it.
