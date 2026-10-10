# petrus-motus-absurd: divergences from the Python reference

What differs from `petrus.motus.dispatch.absurd` at the pin, and why.

**Wire formats, schemas and behavior do not diverge.** These all match the reference, and
the interop suite checks them against the pinned Python in both directions
([PARITY.md](PARITY.md)):

- the vendored Absurd 0.4.0 script and its SHA-256 pin;
- task payloads (`encode_invocation`), publication keys (`{instance}:occurrence-{id}`),
  spawn options and idempotency keys;
- `failure_reason` rows, the latest-details checkpoint name, the `impetus_dispatch` and
  `impetus_results` channels and their payloads;
- every statement's semantics: lookup-first recovery, `FOR UPDATE NOWAIT` custody moves,
  cancellation tombstones, the lease fence on every heartbeat and terminal report.

All the differences below are in API shape.

## Constructors take option records

Keyword arguments become records with the reference's defaults:

| reference | Haskell |
| --- | --- |
| `AbsurdDispatch(connection, instance=..., listen=None, poll_interval=0.25, default_queue="default", activity_queues=...)` | `absurdDispatch connection instance defaultAbsurdDispatchOptions {listen, pollInterval, defaultQueue, activityQueues}` |
| `AbsurdWorkerDispatch(dsn, queues=("default",), worker_id=None, claim_timeout=30)` | `openAbsurdWorkerDispatch dsn defaultAbsurdWorkerOptions {queues, workerId, claimTimeout}` |

A misspelled keyword (the reference's `TypeError: unexpected keyword argument`) cannot be
written. The DSN is a libpq connection string as bytes, as psycopg passes it to libpq.

## Protocols are records

The reference's adapters satisfy the `Dispatch` and `WorkerDispatch` protocols structurally.
Here `toDispatch` and `toWorkerDispatch` build the provider-neutral records of `petrus-motus`
from an adapter. `TestAdapterShape`'s `isinstance` check becomes a check on that record.

## Exceptions

| reference | Haskell |
| --- | --- |
| `ValueError` (a refused argument or invocation) | `DispatchError` (from `petrus-motus`) |
| `RuntimeError` (a refused schema, stale custody, an ambiguous lookup) | `AbsurdError` |
| `psycopg.Error` and its subclasses | `PostgresError`, whose `errorClass` follows psycopg's SQLSTATE mapping (`errorClassForState`) |

Messages are the reference's. The reconnect rule of `_ReconnectableGuardedDispatch` (replace a
dead transport once on `OperationalError` or `InterfaceError`, never on a semantic error) is
exposed as `reconnectOnce`, so the tests drive it directly instead of monkeypatching a facade.

## Statements go through a `Session`

The reference's adapters call `connection.execute`, `commit` and `rollback` on a psycopg
connection, and its tests wrap that object to inject failures. The Haskell adapter speaks through
a `Session` record (`run`, `commit`, `rollback`, plus the `connection`); `sessionOf` is the plain
one. `petrus-engine-absurd` composes the Engine's joined transaction over it, and
`petrus-dst`'s joined worlds wrap it to cut a commit at exactly the reference's boundaries. The
statements sent are the same.

## The optional extra is a package

The reference guards `import petrus.motus.dispatch.absurd` behind the optional `absurd` extra and
explains how to install it when psycopg is missing. Here the extra is this package: a program
uses the Absurd Dispatch by depending on it, and a program that does not cannot import it (the
build names the missing package). `petrus-motus` (the Dispatch protocol, the Worker and its
CLI) depends on nothing Absurd.

For the same reason the Worker CLI cannot build the Absurd provider itself: `petrus-motus` would
have to depend on this package. `Petrus.Motus.Worker.Absurd.absurdPlugins` fills the CLI's
`ProviderPlugins` slot; a worker executable passes it to `workerMain`, and then serves
`--provider absurd --dsn ...` exactly as `python -m petrus.motus.worker` does (same flags, same
defaults, same queue deduplication).

## Names

`fail` and `close` are the reference's method names; they shadow `Prelude` names, so import
the module qualified (`Absurd.fail`, `Absurd.close`).
