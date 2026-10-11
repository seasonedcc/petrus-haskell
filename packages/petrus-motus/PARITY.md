# petrus-motus: parity with the Python reference

This package holds the Dispatch port (`Petrus.Motus.Dispatch`), three
adapters, and the Worker runtime:

- `InlineDispatch` (`Petrus.Motus.Dispatch.Inline`) and `InMemoryDispatch`
  (`Petrus.Motus.Dispatch.InMemory`), both in-process;
- the durable local SQLite Dispatch, `LocalDispatch` and
  `LocalWorkerDispatch` (`Petrus.Motus.Dispatch.Local`), a port of
  `petrus/motus/dispatch/local.py`;
- the Worker runtime (`Petrus.Motus.Worker`): the synchronous `Worker`, the
  `AsyncWorker` with its sync bridge and native-access seam, a port of
  `petrus/motus/worker/{__init__,_runtime,_async}.py`;
- the Worker process entry point (`Petrus.Motus.Worker.Cli`), a port of
  `petrus/motus/worker/_cli.py` (`python -m petrus.motus.worker`).

The ZeroMQ transport (`petrus-motus-zeromq`) and Absurd custody are
separate packages built on this port. They plug into the Worker CLI as
`ProviderPlugins`.

Every Hspec example is named after the upstream test it ports. To cross-check
that every in-scope upstream test is accounted for, run:

    python3 packages/petrus-engine/scripts/parity_check.py

The script covers this package, `petrus-motus-zeromq`, the History stores,
and the Engines.

`cabal test petrus-motus` runs 139 examples, with 0 failures and 0 pending.
The interop examples (8 Local Dispatch, 9 Worker CLI) are marked pending
when `upstream/petrus/.venv` is not synced.

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
| test_worker_runtime.py, 11 of 12 tests | `test_worker_runtime.py` / same names (`WorkerSpec`) | ported |
| test_worker_runtime.py `test_controlled_sequential_local_execution_is_byte_identical_to_inline_history` | `packages/petrus-engine/test/Petrus/Engine/WorkerTopologySpec.hs` / same name | ported in petrus-engine (over the order net; see below) |
| test_async_worker.py, 23 of 26 tests (29 collected) | `test_async_worker.py` / same names (`AsyncWorkerSpec`, 24 examples) | 22 ported, 1 renamed; 2 parameter cases enforced by types |
| test_async_worker.py `test_sync_and_async_workers_cross_reject_before_custody` | `sync and async workers validate the registry before custody` | renamed: there is no colour to cross-reject, so it checks the shared registry validation still precedes custody |
| test_async_worker.py `test_async_decorator_rejects_sync_and_untyped_signatures`, `test_cli_rejects_wrong_mode_registry_before_provider_factory` | none | not applicable (see below) |
| test_worker_topology.py, 36 tests (40 cases) | over Absurd custody, as upstream runs it: `packages/petrus-engine-absurd/test/Petrus/Engine/AbsurdSpec.hs` (27 cases) and `packages/petrus-engine-absurd/test/Petrus/Engine/Absurd/WorkerTopologySpec.hs` (13 cases); over Local custody: `packages/petrus-engine/test/Petrus/Engine/WorkerTopologySpec.hs` (4), `WorkerSpec` (1), `WorkerCliSpec` (1) | all ported; every Worker-backed case runs against the reference's Worker process and a Haskell one (see below) |
| test_package_boundaries.py `test_worker_package_public_contract_and_module_cli` | `Worker CLI` / `test_package_boundaries.py` / worker package public contract and module cli | ported |
| test_package_boundaries.py `test_activity_worker_and_runtime_service_do_not_own_retained_territory_lifecycle`, the Worker half | `test_package_boundaries.py (Worker row)` / activity worker does not own retained territory lifecycle (`BoundarySpec`) | ported over Cabal metadata and module imports: `petrus-motus` depends on no Agenticus package, and no Worker module imports `Petrus.Agenticus.Attachment.Retention`. The Codex adapter and runtime service half belongs to `petrus-agenticus-runtime`. |

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
  reference `Worker` thread. The example was ported before the Worker
  runtime and still performs the same custody sequence by hand over
  `dispatch.worker(...)`: claim, block inside the Activity, then complete
  after the fence. The Worker's own behavior around a fenced terminal is
  covered by the Worker specs below.
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
the attempt state model and the detail normalization that live in
`petrus-activity`, and the reconnectable heartbeat over a psycopg connection,
which is ported with the Absurd Dispatch
(`packages/petrus-motus-absurd/test/Petrus/Motus/Dispatch/Absurd/HeartbeatSpec.hs`).

### Workers: how the reference's tests are ported

`test/Petrus/Motus/WorkerSpec.hs` ports `test_worker_runtime.py`,
`AsyncWorkerSpec.hs` ports `test_async_worker.py`, and `WorkerCliSpec.hs`
covers `_cli.py`.

- **Python task cancellation is an asynchronous exception.** The reference
  cancels the task running `AsyncWorker.run` (or an Activity's task) and
  expects `CancelledError` after the drain. The ports throw an asynchronous
  exception at the thread running `runAsyncWorker` (or at the Activity's
  helper thread). The runtime absorbs it, drains, closes custody, and then
  rethrows it. The "repeated cancellation" tests throw it repeatedly.
- **Event loops become threads.** "On the event loop" assertions, such as
  `test_async_worker_runs_exact_concurrency_on_event_loop_...`, check that
  Activities run concurrently on their own threads. Lane ownership checks
  record the `ThreadId` that touched each provider, as the reference
  records thread idents.
- **Subprocess tests run a real Worker process.** The test executable
  re-executes itself as the Worker CLI (`PETRUS_MOTUS_TEST_WORKER`) over the
  reference's own subprocess registry spelling
  (`tests.petrus.motus.worker.test_worker_runtime:subprocess_activities`).
  The SIGKILL and SIGTERM tests use it.
- **`monkeypatch` becomes a seam.** `partial_thread_start_failure_...`
  patches `threading.Thread.start`; the port passes a `LaneSpawner` that
  fails on the chosen lane.
- **Two parameter cases are enforced by the types.**
  `test_async_worker_requires_positive_integer_concurrency` has the cases
  `0`, `-1`, `True` and `1.5`. Concurrency is an `Int`, so `True` and `1.5`
  are unrepresentable. `0` and `-1` are refused with the reference's
  message.
- **The Worker CLI against the reference.** The `against the reference`
  examples run `python -m petrus.motus.worker` and this package's CLI on the
  same argument vectors. Help text, usage errors (exit status 2), provider
  refusals (exit status 1), abbreviations and `=` values must be
  byte-identical.

Two tests are not applicable, because Haskell has no function colours: one
`Activity` type serves both Workers.

- `test_async_decorator_rejects_sync_and_untyped_signatures` refuses a
  synchronous function given to `@async_activity`, an untyped parameter,
  and an `async def` given to `@activity`. A Haskell definition
  (`Petrus.Activity.defineActivity`) is typed by construction, and has no
  sync/async distinction to get wrong.
- `test_cli_rejects_wrong_mode_registry_before_provider_factory` refuses a
  synchronous registry under `--execution-mode async`. Every registry is
  valid in both modes. `workerMainWith` still loads and validates the
  registry before it builds any provider, and
  `exits 1 on a malformed registry spelling` exercises that path.

`test_worker_runtime.py`'s
`test_controlled_sequential_local_execution_is_byte_identical_to_inline_history`
needs an Engine, so it lives in petrus-engine. The reference runs it over
`tests.absurd_support.topology_net`. The port runs it over the Engine
scenario's order net, which has the same shape: one Activity between pure
transitions. The checked property is the same: inline custody and Local
custody drained by a Worker write byte-identical History and the same
marking. The inline Activity returns its receipt with keys in canonical
order, because Local custody stores results as canonical JSON, exactly as
the reference does. The reference's Activity returns a string, which has
no key order.

### test_worker_topology.py

The reference runs this file over PostgreSQL History, Absurd Dispatch and
real Worker processes. All 40 cases are ported over that same substrate in
petrus-engine-absurd (which depends on this package, so the specs live
there):

- `Petrus.Engine.AbsurdSpec` (27 cases): `TestEndToEnd`,
  `TestLifecycleScopeCancellation`, `TestWorkerKill`, `TestAuthorityKill`
  and every `TestAbsurdProviderEngineConstruction` test.
- `Petrus.Engine.Absurd.WorkerTopologySpec` (13 cases): every
  `TestActivityRegistry` and `TestDispatchDoorbell` test.

Every Worker-backed case runs twice: against the reference's own process
(`python -m petrus.motus.worker --provider absurd`) and against a Haskell
Worker process, which is the test executable re-run as `workerMain` with
the Absurd provider in the `ProviderPlugins` slot
(`Petrus.Motus.Worker.Absurd.absurdPlugins` in petrus-motus-absurd). Both
are killed by exact PID with real SIGKILL and SIGTERM.

Two cases are partly enforced by the types:

- `test_worker_refuses_invalid_activity_registries`: `{}` and `{"": ...}`
  are ported; a non-string name and a non-callable implementation are
  unrepresentable in a `Map Text Activity`.
- `test_worker_and_loader_snapshot_mutable_registries`: a registry is an
  immutable `Map`, and registries are compiled into the worker executable
  rather than imported by name, so there is nothing to mutate.

`test_main_defaults_queue_and_preserves_deduplicated_flag_order` drives the
real entry point (`workerMainWith`) with a fake Absurd provider in the
plugin slot, as the reference monkeypatches `AbsurdWorkerDispatch`.

Over the Local custody this package has, petrus-engine's
`WorkerTopologySpec` keeps the same topology with an Engine over JSONL
History and real Worker processes:
- `TestEndToEnd.test_the_activity_executes_on_the_worker_and_completes_through_server_side_projection`;
- `TestWorkerKill.test_sigkill_mid_activity_redispatches_on_lease_expiry_with_exactly_one_effect`;
- `TestWorkerKill.test_sigterm_drains_gracefully_the_in_flight_activity_completes`;
- `TestActivityRegistry.test_the_worker_refuses_an_unregistered_activity`.

It adds a cross-implementation check: every pairing of a Haskell or
reference Engine with a Haskell or reference Worker, taking turns in
lock-step, writes byte-identical JSONL History. `WorkerSpec` and
`WorkerCliSpec` also cover the invalid-registry and queue-default cases
without a database.

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

- **The Worker CLI** (`WorkerCliSpec`, 17 examples beyond the boundary and
  queue-defaulting tests):
  - every provider's argument validation, with the reference's messages;
  - `int()` and `float()` argument conversions;
  - the process entry point's exit statuses;
  - nine byte-for-byte comparisons with `python -m petrus.motus.worker`
    (help, usage errors, abbreviations, refusals).

Worker interop:
- a Haskell Worker and a reference Worker each drain Local custody written
  by either implementation's Engine, and all four pairings write
  byte-identical History (petrus-engine `WorkerTopologySpec`);
- this package's Worker CLI, re-executed as a process, serves the Engine
  topology tests, and is killed and drained there.

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
