# petrus-postgres: divergences from upstream's psycopg usage

Intentional differences from how the pinned Petrus drives PostgreSQL through
psycopg 3.3. Everything not listed here is meant to behave identically; the
test suite runs the same statements through psycopg against the same server
and compares transaction state, row counts, status messages, SQLSTATEs,
exception classes, `str(e)` texts, parameter types, notifications and the
authority fence.

| Behavior | Upstream (psycopg 3) | petrus-postgres | Why |
| --- | --- | --- | --- |
| Isolation level | `BEGIN` with no level: the server's `default_transaction_isolation`, READ COMMITTED unless reconfigured. | `BEGIN ISOLATION LEVEL READ COMMITTED` by default (psycopg's own spelling when `isolation_level=READ_COMMITTED`); `ServerDefault` sends plain `BEGIN`. | Upstream's verify-on-conflict re-reads rely on READ COMMITTED; spelling it out keeps that true on a server configured otherwise. |
| Parameter wire format | `int`, `bool`, `float` and `bytes` go out in binary. | Text format with the same type OIDs (`int2`/`int4`/`int8`/`numeric` by magnitude, `bool`, `float8`); `bytea` in binary. `str` and lists of `str` are untyped (OID 0) exactly as psycopg sends them. | The server resolves types from the OIDs, which match; the tests compare `pg_typeof` for every kind. |
| Result values | Loaded into Python objects (`jsonb` through `json.loads`). | Rows hold PostgreSQL's text output; `Petrus.Postgres.Value` decodes on demand (`jsonb` through petrus-json, CPython `json.loads` semantics). | Callers decode only the columns they read. |
| Lost notifications | `notifies(stop_after=1)` may drop the rest of a batch that arrived in the same packet when the consumer stops after the first. | Every notification stays queued in libpq until read; `waitForNotification` returns them one by one. | Upstream treats NOTIFY as a lossy wake-up hint and always re-probes, so an extra wake-up only costs a probe. |
| Error text prefix | `strip_severity` removes localized severity prefixes (de, es, fr, …). | Removes the English ones (`ERROR:`, `FATAL:`, …). | Servers in the supported deployments run with English messages; SQLSTATEs are locale-independent. |
| Placeholders | `%s`, `%b`, `%t` and named `%(name)s`. | Positional only; a named placeholder is refused. | Upstream uses positional placeholders only. |
| Statements without parameters | `execute(sql)` (params `None`) is sent as written; `execute(sql, ())` converts `%%`. | An empty parameter list always means "sent as written" (simple protocol, several statements allowed). | Upstream never passes an empty tuple. |
| Nested owned transactions | `connection.transaction()` inside an open transaction creates a `SAVEPOINT`. | `withTransaction` joins the open transaction. | Upstream's `_transaction()` helper only owns a transaction on an idle autocommit connection. |
| Client encoding | Whatever the server chose; text is decoded with it. | Switched to UTF8 at connect when the server chose another. | Haskell `Text` crosses the boundary as UTF-8. |
| Connecting | Asynchronous connect, interruptible. | libpq's blocking `PQconnectdb` (bound it with `connect_timeout` in the DSN). | Connections are opened once per process; statement execution and waits are interruptible. |
| Waiting for the server | `poll()` on the socket. | With the threaded runtime, an interruptible `poll()` on the calling OS thread; with the non-threaded runtime, the GHC IO manager. Asynchronous exceptions cancel the running statement on the server (psycopg does the same on `KeyboardInterrupt`). | Same wake-up latency as psycopg. |
