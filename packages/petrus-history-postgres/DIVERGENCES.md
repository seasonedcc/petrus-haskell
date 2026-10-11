# petrus-history-postgres: divergences from `petrus.impetus.history_store.postgres`

The parts that are meant to match the pinned reference exactly do match. That
covers the schema (the DDL text and the resulting catalog), the rows, the
event ids, the payload spelling, the statements, the transaction behavior,
the verify-on-conflict outcomes, and every refusal text. InteropSpec checks
all of them against the reference process on a shared database. This file
lists only differences in the API surface.

The connection-level differences (`BEGIN ISOLATION LEVEL READ COMMITTED`,
text-format parameters, and the others) come from `petrus-postgres`. See
[its DIVERGENCES](../petrus-postgres/DIVERGENCES.md).

| # | Reference | Haskell | Why |
| --- | --- | --- | --- |
| 1 | `PostgresHistoryStore(connection, instance)` is a class with `records`, `__len__`, `__iter__`, `append`, and `extend`. | `openPostgresHistoryStore connection instance` returns the kernel's `HistoryStore` record (`snapshot`, `count`, `extend`, `mode`), and `Petrus.Impetus.HistoryStore.records`, `size`, and `append` work over it. | Every backend implements the kernel's one contract. The mode (`BackendOwned` for autocommit, `JoinedTransaction` for join mode) is read once from the connection at open time. The reference reads `connection.autocommit` at every write, so switching a connection's mode under an open store is not supported. |
| 2 | Refusals are `ValueError` (unprovisioned table, empty instance id, undecodable row, unencodable record, different fact) and `RuntimeError` (a conflict no stored row explains). | `HistoryStoreError` (the JSONL store's type, re-exported) and `UnverifiableConflict` (the kernel's `Petrus.Impetus.HistoryStore` type, re-exported and shared with the SQLite store). The texts are the reference's. | The shared backend-contract suite selects on `HistoryStoreError` for every backend. |
| 3 | A non-`str` instance id raises `ValueError`. | Enforced by types (`Text`). The empty id is refused with the reference's text. | — |
| 4 | Importing the module without psycopg raises `ImportError` with the "optional 'postgres' extra" guidance. | The store is its own package (`petrus-history-postgres`). Depending on it is the opt-in, and the kernel and `petrus-history-store` never depend on the PostgreSQL client (BoundarySpec). | Cabal resolves dependencies at build time, so there is no import-time failure to word. |
| 5 | The `postgres_commit` event goes to the process-wide `impetus` logger. | `openPostgresHistoryStoreWith defaultPostgresHistoryOptions {telemetry = Just sink}` routes it to an `EventSink`. With `Nothing` (the `openPostgresHistoryStore` default), it goes to the `impetus` logger, as in the reference. The Engine providers pass the Engine's sink. | Explicit sinks are this port's telemetry convention (`petrus-telemetry`). The event name and fields (`records`, `entered`, `elapsed_ms`) are the reference's. |
| 6 | Statements live inline in methods. | They are also exported (`schemaStatements`, `loadStatement`, `insertStatement`, `identityStatement`, `terminalStatement`) with the reference's exact text, and so are `eventId`, `encodePayload`, and `loadPostgresHistory`. | Interop and benchmarks compare them directly. The additions are additive. |
