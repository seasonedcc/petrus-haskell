# petrus-motus: divergences from the Python reference

These are deliberate. Each one keeps the reference's observable behavior for
everything that the Engine and History can see.

1. **One `Dispatch` record instead of two protocols.** The reference has a
   `Dispatch` protocol and a `CancellableDispatch` extension, and tells them
   apart with `isinstance`. Here, `Dispatch` is one record whose `cancel`
   field is `Maybe (CancellationInstruction -> IO CancellationDisposition)`.
   `Nothing` is a Dispatch without recoverable cancellation, and
   `isCancellable` replaces the `isinstance` check.
2. **No lifecycle or wait fields on the port.** A provider's transaction
   hooks and wake-up hint are part of the Engine's provider seam
   (`Petrus.Engine.Provider.EngineResources`), not of `Dispatch`. The
   reference attaches them to the composed Engine too, so nothing observable
   changes. An in-process adapter simply never has to pretend it owns a
   transaction.
3. **Outcomes are a sum type.** `collect` returns
   `[(Int, ActivityOutcome)]`, with `Succeeded Json | Failed ActivityFailure`.
   The reference yields `(occurrence, object)` pairs and separates failures
   with `isinstance(outcome, ActivityFailure)`.
4. **Exception classification by Haskell type name.** `InlineDispatch` gives
   an unclassified exception a retryable `ActivityFailure` whose error type
   is the Haskell exception's type name. The reference uses Python's class
   name. Tests that need the reference's spelling define exceptions with the
   Python names (`RuntimeError`, `LookupError`). A `DispatchError` is spelled
   `ValueError`, the reference's type for it. An empty message is spelled as
   the type name, as `str(exc) or type(exc).__name__` does.
5. **No dataclass reflection.** The adapters are closures. They have no
   `repr`, no `==`, and no field list. Their registries are immutable maps,
   which is the property the reference's frozen dataclass guards. See
   PARITY.md.
6. **Constructors validate as `__post_init__` does.**
   `cancellationInstruction` and `activityAttempt` return `Either Text` with
   the reference's exact messages. Type checks that Python performs at run
   time, such as a bool posing as an occurrence, are enforced by the types.
