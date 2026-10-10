# petrus-motus: parity with the Python reference

This package holds the Dispatch port (`Petrus.Motus.Dispatch`) and three
adapters:

- `InlineDispatch` (`Petrus.Motus.Dispatch.Inline`) and `InMemoryDispatch`
  (`Petrus.Motus.Dispatch.InMemory`), both in-process;
- the durable local SQLite Dispatch, `LocalDispatch` and
  `LocalWorkerDispatch` (`Petrus.Motus.Dispatch.Local`), a port of
  `petrus/motus/dispatch/local.py`.

The ZeroMQ transport, Workers and Absurd are not covered here. They are
separate packages built on this port.

Every Hspec example is named after the upstream test it ports. To cross-check
that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

The script covers this package, `petrus-history-store`, and `petrus-engine`.

`cabal test petrus-motus` runs 80 examples, with 0 failures and 0 pending. The
8 interop examples are marked pending when `upstream/petrus/.venv` is not
synced.

## Ledger

| upstream test | Haskell example | status |
| --- | --- | --- |
| test_coordinator.py `TestInMemoryDispatch` (5) | `TestInMemoryDispatch` / same names | ported |
| test_coordinator.py `TestInlineDispatch` (2) | `TestInlineDispatch (coordinator)` / same names | ported |
| test_activity_seam.py `TestInlineDispatch` (8) | `TestInlineDispatch (activity seam)` / same names | 7 ported, 1 not applicable |
| test_attempt_heartbeats.py `test_inline_context_has_synthetic_identity_and_detached_omitted_null_details` | `inline heartbeat context` / has synthetic identity and detached omitted/null details | ported (renamed) |
| test_local_dispatch.py, the 32 non-Engine tests (37 collected) | `test_local_dispatch.py` / same names (34 examples) | 32 ported; 3 parameter cases enforced by types |
| test_local_dispatch.py `test_sqlite_history_tables_coexist_untouched` | `Local Dispatch interop with the reference` / sqlite history tables coexist untouched | ported, against the reference's `SqliteHistoryStore` |
| test_local_dispatch.py, the 3 Engine-level tests (`test_engine_*`) | `packages/petrus-engine/test/Petrus/Engine/LocalDispatchSpec.hs` / same names | ported in petrus-engine |

There is one test that is not applicable:

- `TestInlineDispatch.test_value_shape_preserves_the_prior_dataclass_contract`
  asserts dataclass reflection: `fields(adapter)` names, the
  `InlineDispatch(activities=mappingproxy(` repr, and `==` between two
  adapters over the same function object. A Haskell `Dispatch` is a record
  of functions. It has no fields to reflect, no `Show`, and no `Eq`. Its
  registry is already immutable, which is the property the reflection
  guarded.

Three parameter cases of
`test_provider_clock_refuses_non_integer_negative_and_out_of_range_values`
are enforced by the types. A `LocalDispatchClock` is `IO Integer`, so it
cannot return `True`, `1.5` or `"1"`. The cases `-1` and `2**63` are ported
and refused with the reference's exact message.

### Local Dispatch: how the reference's tests are ported

The SQLite file is shared with the reference, so the port's evidence is
behavioral equality on that file, checked in both directions.

- **Refusals are compared exactly.** Wherever an upstream test matches a
  `ValueError` with a regex fragment, the Haskell example compares the full
  `DispatchError` text with the reference's. The texts were captured from
  the pinned reference. Examples: `stale Activity attempt ["one",1]`,
  `<path>: foreign current-version Local Dispatch DDL shape`, and
  `heartbeat details encode to 65538 UTF-8 bytes; limit is 65536`.
- **Spawned processes become threads.** The reference spawns processes in
  `test_schema_initialization_is_atomic_under_spawned_process_startup` and
  `test_spawned_claim_contention_distributes_distinct_work_once`. The ports
  run the same contenders as concurrent threads, each on its own
  connections. The interop suite then repeats both scenarios with reference
  processes and Haskell threads contending on one file.
- **The Worker test.** `test_running_cancellation_..._quarantine` drives a
  reference `Worker` thread. Workers are not ported yet, so the example's
  thread performs the same custody sequence over `dispatch.worker(...)`:
  claim, block inside the Activity, then complete after the fence.
- **`sqlite3.connect` mutations** (expiring a lease, corrupting an
  invocation, dropping a table) are made by the same SQL on a raw
  direct-sqlite connection.

### Interop evidence (`test/Petrus/Motus/Dispatch/LocalInteropSpec.hs`)

These examples run `test/interop/local_interop.py` under the pinned
reference.

1. **Reference to Haskell.** The reference publishes 5 occurrences, a
   Haskell worker claims and completes them, and the reference collects the
   exact outcomes.
2. **Haskell to reference.** Haskell publishes, a reference worker claims
   and completes (its attempt views are checked field by field), and Haskell
   collects.
3. **The provider-clock scenario.** It covers retryable and terminal
   failures with `retry_after`, heartbeat replace and preserve, exact
   terminal retry, cancellation with a fenced redispatch, a
   `start_to_close` lease expiry, `schedule_to_close` expiry before
   claim, routes across two queues, and non-ASCII JSON. Both implementations
   run it under a manual clock. They emit identical `impetus_dispatch_*`
   telemetry (names, fields, field order) and identical results. Every row
   of the two files (`sqlite_master` DDL text, tasks, terminals,
   cancellations, journal mode) is identical, as dumped by the reference.
4. **v1 migration.** A v1 file migrates to identical rows in both
   implementations.
5. **Fresh files.** A fresh file has identical schema rows in both
   implementations, and each validates the other's file as current.
6. **Mixed startup and contention.** Schema initialization under mixed
   reference processes and Haskell threads, and claim contention between
   them, distributing the work exactly once.
7. **`SqliteHistoryStore` co-residence.** This is the port of
   `test_sqlite_history_tables_coexist_untouched`.

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

- **Local Dispatch** (9 examples):
  - It refuses the reference's other name, occurrence, queue, timeout and
    clock-option inputs, and its other corrupt-invocation shapes, with the
    reference's messages.
  - It refuses a non-faithful result and an empty failure before touching
    custody.
  - A caught exception fails retryably and is spelled as its `repr`.
  - It checks the `wait` and `waitForResults` readiness answers, and that
    the `WorkerDispatch` record surface drives the same custody.
  - It checks the reference's telemetry events, fields and field order,
    including lease expiry with an integer epoch, recorded through
    `Petrus.Telemetry.capture`.
  - A generated claimant is the worker label plus a version-4 UUID.

The Engine's suite exercises the adapters end to end:
- cross-process resume against the reference
  (`packages/petrus-engine/test/Petrus/Engine/InteropSpec.hs`);
- the Engine over a JSONL History and the Local Dispatch, across the
  split-store crash windows
  (`packages/petrus-engine/test/Petrus/Engine/LocalDispatchSpec.hs`). That
  spec includes the DST worlds' consumer shape: a world provider clock, a
  wrapped refusing dispatch door, a worker per claim, and a zero-delay
  retry. Its outcome matches the reference run of the same script.

Benchmarks against the reference are in `bench/RESULTS.md`.
