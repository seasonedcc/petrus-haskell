# petrus-motus: parity with the Python reference

This package holds the Dispatch port (`Petrus.Motus.Dispatch`) and its two
in-process adapters: `InlineDispatch` (`Petrus.Motus.Dispatch.Inline`) and
`InMemoryDispatch` (`Petrus.Motus.Dispatch.InMemory`). It does not cover the
local SQLite Dispatch, the ZeroMQ transport, workers, or Absurd. Those are
separate packages built on this port.

Every Hspec example is named after the upstream test it ports. To cross-check
that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

The script covers this package, `petrus-history-store`, and `petrus-engine`.

`cabal test petrus-motus` runs 29 examples, with 0 failures and 0 pending.

## Ledger

| upstream test | Haskell example | status |
| --- | --- | --- |
| test_coordinator.py `TestInMemoryDispatch` (5) | `TestInMemoryDispatch` / same names | ported |
| test_coordinator.py `TestInlineDispatch` (2) | `TestInlineDispatch (coordinator)` / same names | ported |
| test_activity_seam.py `TestInlineDispatch` (8) | `TestInlineDispatch (activity seam)` / same names | 7 ported, 1 not applicable |
| test_attempt_heartbeats.py `test_inline_context_has_synthetic_identity_and_detached_omitted_null_details` | `inline heartbeat context` / has synthetic identity and detached omitted/null details | ported (renamed) |

There is one test that is not applicable:

- `TestInlineDispatch.test_value_shape_preserves_the_prior_dataclass_contract`
  asserts dataclass reflection: `fields(adapter)` names, the
  `InlineDispatch(activities=mappingproxy(` repr, and `==` between two
  adapters over the same function object. A Haskell `Dispatch` is a record
  of functions. It has no fields to reflect, no `Show`, and no `Eq`. Its
  registry is already immutable, which is the property the reflection
  guarded.

The rest of `test_attempt_heartbeats.py` is out of scope here. That covers
the attempt state model, the detail normalization that lives in
`petrus-activity`, and the reconnectable ZeroMQ heartbeat. It belongs to the
worker and transport packages.

## Beyond upstream

These examples pin behavior that the reference implements without a direct
test.

- **InMemoryDispatch cancellation** (5 examples):
  - It retires pending work, acknowledges a repeat, and reports a conflict
    for a different instruction.
  - It refuses to retire pending work under a different invocation.
  - It reports a buffered terminal outcome and tombstones unknown work.
  - It drops a fenced redispatch of the same invocation and refuses a
    different one.
  - It settles a fenced occurrence without it being pending.
- **InlineDispatch cancellation** (1 example).
- **`CancellationInstruction` and `ActivityAttempt`** construction refusals,
  with the reference's exact texts, and the disposition wire spellings.
- **InlineDispatch edge cases:**
  - An empty exception message is spelled by the exception's type name.
  - An unknown activity, once dispatched, is buffered as a `ValueError`
    failure.
  - A non-retryable classified failure is terminal despite remaining
    attempts.
  - Non-finite heartbeat details are refused.

The Engine's suite exercises both adapters end to end, including
cross-process resume against the reference
(`packages/petrus-engine/test/Petrus/Engine/InteropSpec.hs`).
