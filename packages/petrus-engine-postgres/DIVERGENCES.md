# petrus-engine-postgres: divergences from `petrus.engine.postgres`

The parts that are meant to match the pinned reference exactly do match. That
covers the fence key and its refusal text, the order of fence, History load,
and construction, the commit points, rollback and poisoning, release (unlock,
then rollback), closing the connection on every failed construction, and the
rows written. PostgresSpec and InteropSpec check them, the latter against the
reference's own Engines on a shared database. This file lists only
differences in the API surface.

| # | Reference | Haskell | Why |
| --- | --- | --- | --- |
| 1 | `create_engine(connection, net, instance, *, dispatch, **options)` takes keyword options, and an unknown keyword raises `TypeError` after the connection is closed. | `createEngine connection net instance dispatch options` takes `EngineOptions`, a record, so unknown options cannot be spelled. Options the Engine refuses at construction still close the connection. | Haskell has no keyword arguments. |
| 2 | Tests wrap the connection object (`__getattr__` delegation) to count, refuse, or fault commits. | `PostgresSession {connection, commit, close}` with `openPostgresEngine session mode …`, where `postgresSession connection` is the connection's own commit and close. | It is the explicit form of the same seam, and it is additive. |
| 3 | `Engine._open(…, create=True/False)` is private. The construction steps (`_open_engine`) are private too and are repeated in `petrus.engine.absurd`. | The construction is public as `Petrus.Engine.Postgres.Joined` (`JoinedProvider`, `openJoinedEngine`, and the `rollbackQuietly`, `releaseFenceThenRollback`, and `closeBoth` helpers). | One audited composition serves both providers: Absurd supplies `validate` (its connection checks), `compose` (its Dispatch and `wait_for_results`), and `closeConnections` (`closeBoth listen joined`). |
| 4 | When construction fails inside `Engine._open`, both `Engine._open`'s fate and `_open_engine`'s `except` run rollback, release, and close (twice; each is idempotent). | `openJoinedEngine` cleans up only failures before it hands the resources to `openEngine`. After that, `openEngine`'s own fate runs once. | It is not observable: the second pass of rollback, fence release, and close is a no-op upstream. |
| 5 | A held fence raises `RuntimeError`. A missing schema, a duplicate create, or a missing load raises `ValueError`. | `FenceError (FenceHeld …)` from `petrus-postgres`, `HistoryStoreError` from the store, and `EngineValueError` from the Engine. The texts are the reference's. | Each layer keeps its own error type. |
| 6 | `withEngine` does not exist. | `withEngine mode connection … action` brackets open and `Engine.close`. | It is a convenience and is additive. |
| 7 | The History store logs `postgres_commit` to the global `impetus` logger. | The provider passes the Engine's `telemetrySink` to the store, so the event reaches the same sink as the Engine's events. The name and fields are unchanged. | Explicit sinks are this port's telemetry convention. |
