# petrus-engine-postgres: parity with the Python reference

This package ports `petrus.engine.postgres` (`create_engine`, `load_engine`)
and its use of `petrus.engine._postgres` (the private authority fence, which
lives in `petrus-postgres` as `Petrus.Postgres.Fence`) at the pin in
[UPSTREAM.md](../../UPSTREAM.md). The composition is
`Petrus.Engine.Postgres.Joined`, the joined-transaction seam that the Absurd
provider (`petrus.engine.absurd`, ported as
[petrus-engine-absurd](../petrus-engine-absurd/PARITY.md)) reuses. It runs these
steps in order:

1. validate the provider's preconditions;
2. take the fence before any History is read;
3. open the PostgreSQL History in join mode;
4. compose the Dispatch and its wake hint;
5. hand the Engine the transaction's fate.

The fate has four parts. Commit runs at every commit point. Rollback
swallows database errors. Release unlocks the fence, then rolls back. Close
closes the connections. Every failed construction rolls back, releases, and
closes before it propagates.

Run `python3 packages/petrus-engine/scripts/parity_check.py` to cross-check
the ledger.

`cabal test petrus-engine-postgres` runs the suite. With
`PETRUS_TEST_POSTGRES` set (CI sets it), every example passes. Without it,
the examples that need a server are pending and say why. Each group of examples
gets its own scratch database.

## Ledger

| upstream test | Haskell spec | status |
| --- | --- | --- |
| test_postgres_engine.py: 12 functions, 13 cases. All are `postgres`-marked. `test_projection_failure_commit_fault_propagates_storage_fate_and_fresh_load_decides` is parametrized over `fault` in `["refused", "acknowledgement-lost"]`. | PostgresSpec / `TestPostgresEngineProvider` | 13 cases ported |
| test_package_boundaries.py `test_postgres_history_provider_returns_only_the_neutral_engine` | PostgresSpec / package boundaries | ported. The return type is checked by the compiler, and the export list is checked for fence, `PostgresEngine`, and coordinator names. |

How the reference's test doubles are spelled here:

- **The commit-wrapping connections** (`_CountCommits`, `FaultOneCommit`, `RefuseOneCommit`) wrap `commit` on a `PostgresSession`, the connection plus the commit and close the Engine performs on it. Their `OSError` is an `IOError` here, propagated unchanged as upstream propagates its own.
- **`ProjectionError.__repr__` raising** proves upstream never renders the durable failure text through `repr`. A Haskell handler returns its rendered failure text itself, and the test checks that exact text in `FiringFailed`.
- **`unknown_option=True` raising `TypeError`** cannot be spelled against a record of options. The ported case uses an option the Engine refuses at construction (`defaultHeartbeatTimeout = 0`), which takes the same failure path, and checks that the supplied connection is closed.

## Beyond upstream

- **PostgresSpec / beyond upstream**:
  - closing releases the fence at once;
  - a poisoned Engine has already released its fence and closed its connection;
  - `postgres_commit` reaches the Engine's telemetry sink;
  - a construction the Engine refuses (unknown instance) leaves the fence free;
  - `withEngine` closes the Engine and its connection.
- **Interop with the reference process** (InteropSpec). These
  run `test/interop/postgres_engine_interop.py`, plus the History suite's
  listener script, under the pinned `upstream/petrus/.venv` on the same
  scratch database. Every reference Engine is upstream's own
  `petrus.engine.postgres`.
  - **Taking turns:**
    - an Instance the reference created loads here and is extended, and the reference loads the result (records and marking equal);
    - the reverse also holds, including the reference's delivery identity being acknowledged here as a prior delivery.
  - **The fence:**
    - both languages derive the same advisory-lock key;
    - a reference Engine's fence refuses a Haskell writer before History loads and closes its connection, until the reference closes;
    - a Haskell Engine's fence refuses a reference writer with the reference's own `RuntimeError` text and closes its connection;
    - a reference holder killed with `SIGKILL` releases the fence with its session;
    - a Haskell holder whose connection drops releases it for the reference.
  - **Fates decided across languages:**
    - a projection failure committed in either language is acknowledged exactly (`PriorAcknowledgement("event-7", 1)`) by a load in the other;
    - an acceptance whose Haskell completion commit was refused is completed exactly by the reference, at the same occurrence.
  - **LISTEN/NOTIFY on the joined seam:** a doorbell Dispatch built on `JoinedProvider` has the Absurd shape. `dispatch` sends `pg_notify('impetus_dispatch', 'default')` on the joined connection. Results are rows probed on a dedicated autocommit listen connection, and the wake hint is `pollWithDoorbell` on `impetus_results`.
    - When the begin-plus-dispatch commit is refused, a reference listener receives nothing.
    - A fresh load dispatches again, and the doorbell arrives once, on commit.
    - The reference's `impetus_results` NOTIFY, sent in the same transaction as its result row, wakes `Engine.wait` well before the 5-second poll tick. The result is then collected and projected.
    - A refused provider precondition closes both connections and leaves no Instance.

## Benchmarks

See [bench/RESULTS.md](bench/RESULTS.md). Every row is faster than the pinned
Python in wall-clock time: deliver, prior redelivery, create plus close
(dominated by connecting and the fence, so the thinnest), the order scenario
driven to rest through internal firings and an Activity round trip, and
loading a 100-order History.
