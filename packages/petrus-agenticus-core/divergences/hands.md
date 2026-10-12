# Divergences: Agenticus Hands

Every observable wire output (request normalisation, rejection category and
detail, `ToolResult.to_data`/`to_model_data` bytes, counters, evidence) and
every error message matches upstream; the differential corpus checks this.
What differs is the shape of the API, where Python idiom does not carry over,
plus one behaviour fix in a path upstream never exercises.

## Behaviour

- **An interrupted waiter never abandons someone else's claim.**  Upstream
  `submit` calls `_abandon(request)` on any `BaseException`.  `_abandon`
  deletes a pending entry whose request equals this one.  So a waiter
  interrupted inside `_claim`'s `self._state.wait()` (for example by
  `KeyboardInterrupt`) deletes the *primary's* claim and decrements
  `_in_flight` while the primary is still running.  Here each claim carries
  its own `MVar ()` signal, and abandon/publish act only on the entry holding
  the caller's signal.  Only the thread that made a claim can release it.
  The exact-waiter-reclaims path that upstream tests
  (`test_abandoned_primary_allows_an_exact_waiter_to_reclaim_without_key_error`)
  behaves identically.
- **Adapter exceptions.**  Upstream turns `Exception` raised by an adapter,
  fence, admission or target callback into a sanitised `provider` (or
  fail-closed) result, and lets `BaseException` propagate.  Here synchronous
  exceptions are mapped the same way.  Asynchronous exceptions
  (`SomeAsyncException`: `killThread`, `timeout`, `cancel`) propagate, after
  the claim is abandoned under `mask`, so cancellation stays prompt and an
  exact waiter can reclaim.
- **`AssertionError`.**  Upstream `_detail` uses `assert` for the rejection
  detail bound.  Here it is `OtherError "AssertionError"` with the same
  message, raised by `mkToolRequestRejected` / `mkToolError`.  No ported code
  path can trigger it, because every internal detail is a fixed literal.

## Types and naming

- **`ToolRequestRejected` is a value, not an exception.**  `parseToolRequest`
  returns `Either ToolRequestRejected ToolRequest`, so parsing is pure.
  `rejectedMessage` gives `str(error)` (`"<category>: <detail>"`).
  `rejectedError` gives the exception form (`AgenticusError` with class
  `ToolRequestRejected`, a `ValueError` subclass in `isInstanceOf`).  The
  constructor is hidden (`ToolRequestRejectedValue`).  `mkToolRequestRejected`
  validates the detail the way upstream `__init__` does.
- **Renamed fields** (`NoFieldSelectors` + `DuplicateRecordFields` make
  same-named fields across records ambiguous in updates under `-Werror`):
  - `ToolResult.data` / `.error` → `resultData` / `resultError`.
  - `HandsGateway(max_calls=...)` → `GatewayConfig.maxGatewayCalls`.
  - `GrantLedger.open(...)` keyword arguments → a `GrantSpec` record with
    `spec*` fields, built by `grantSpec capabilities deadline maxCalls`; the
    optional sets default to empty as upstream.
- **Constructors.**  Smart constructors (`mkToolRequest`, `mkToolResult`,
  `mkToolError`, `mkCapabilityGrant`, `mkShellOutcome`, `mkStagedWrite`,
  `mkTestOutcome`, `mkCallFence`) return `Either AgenticusError` and validate
  in upstream order with upstream messages.  `mkCapabilityGrant` keeps
  upstream's positional order.
- **Unreachable type checks.**  Upstream `isinstance` checks on arguments
  that are already typed (for example `deadline` not being `bool`/number, an
  adapter returning something other than `ShellOutcome`, or `fence.snapshot()`
  returning a non-`CallFence`) cannot fail in Haskell, and are omitted.
  Checks on untyped JSON input are all kept: request envelopes, params and
  `ToolResult.data`, where a float is rejected as upstream's `TypeError`.
- **Sets.**  Upstream `frozenset`s (capabilities, writable paths and roots,
  allowed argv) are `Data.Set`, ordered by text (`ToolMethod`'s `Ord` is its
  wire text, as a `StrEnum`).  No output enumerates these sets, so the order
  is not observable.
- **Mutable objects.**  `GrantLedger` and `SevenStepEpisodePolicy` hold their
  state in an `IORef`, so every accessor is in `IO`
  (`currentGrant`, `policyTurns`, `policyFailed`, …).  `GatewayConfig` takes
  `clock :: IO Double` (default `getMonotonicTime`) in place of
  `time.monotonic`.
- **Additions.**  `toolRequestToData` (an encoder upstream does not have; the
  tests and the corpus use it); `parseToolMethod` / `parseRejectionCategory`;
  `try*` variants of `openGrant` / `consumeGrant` returning `Either`;
  `gatewayEpisodeId` / `gatewayAttachmentId` / … accessors.

## Concurrency

- **`Barrier`.**  Upstream shares a `threading.RLock` between the gateway
  and its `EpisodeAttachment`.  `Barrier` is the Haskell equivalent: an
  `MVar ()` plus an owner `ThreadId`, re-entrant for the owning thread.
  `newBarrier`, `withBarrier` and `holdsBarrier` are exported so
  `EpisodeAttachment` can share one barrier with the gateway.  The
  acquisition spins briefly (`tryTakeMVar` + `yield`, 64 attempts) before
  parking: see `bench/results-hands.md`.
- **Call ledger.**  Upstream uses one `Condition` around a dict.  Here it is
  an `IORef` updated with `atomicModifyIORef'`,
  with a per-claim `MVar ()` for exact in-flight duplicates and a `TVar`
  generation that `drain` waits on.  Ordering guarantees are the same:
  - single flight per call id;
  - a conflict fails loud;
  - a full ledger is a `budget` result that is not recorded as a claim;
  - `drain` covers every claimed call from claim to publish.
- **`drain` timeout.**  It is measured on the configured `clock`, as
  upstream measures it on `time.monotonic`.  Real waiting uses
  `registerDelay`, capped at 2 000 s per wait.
