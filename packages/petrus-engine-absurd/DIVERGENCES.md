# petrus-engine-absurd: divergences from the Python reference

This file lists what differs from `petrus.engine.absurd` at the pin, and why.

**Wire formats, schemas and behavior do not diverge.** The following match the reference:

- the History rows and the Absurd task rows;
- the publication keys;
- the `impetus_dispatch` and `impetus_results` doorbells;
- the authority fence;
- the joined-transaction boundaries;
- the order in which construction validates, fences, loads and closes.

The interop suite checks these against the pinned Python, with Engines and Workers of both
languages on one Instance ([PARITY.md](PARITY.md)). Every difference below is in the shape of the
API.

## Doors take positional arguments and option records

| reference | Haskell |
| --- | --- |
| `create_engine(connection, net, instance, *, listen, poll_interval=0.25, default_queue="default", activity_queues=..., **engine_options)` | `createEngine joined (Just listen) net instanceId defaultAbsurdEngineOptions {pollInterval, defaultQueue, activityQueues} engineOptions` |
| `load_engine(...)` (same arguments) | `loadEngine ...` (same arguments) |

- `AbsurdEngineOptions` holds the provider's keywords. The reference's defaults are in
  `defaultAbsurdEngineOptions`.
- `EngineOptions` (from `petrus-engine`) holds the Engine's keywords.
- `withEngine` is the bracket form: it opens the Engine, runs an action, and closes the Engine.

A misspelled or unknown keyword raises `TypeError` in the reference. In Haskell it cannot be
written. The construction test for it ("an invalid provider option closes both connections")
passes an invalid option value instead: `defaultQueue = "not a queue"`. Construction refuses that
value, and the outcome is the same as for the reference's unknown keyword: both connections are
closed.

## The listen connection is a `Maybe`

The reference's `listen` keyword is required but may be `None`, and `None` is `Nothing` here. As
in the reference, it is refused with the reference's message: the Engine needs a dedicated autocommit listen connection to `wait`.
`validateConnections` checks that the joined connection is not in autocommit mode, that the
listener is, and that the two are different connections. It runs before anything else, as
`_validate_connections` does.

## Errors are the Engine's typed errors

The reference raises `ValueError` and `RuntimeError`. Here they are `EngineValueError` and
`EngineRuntimeError` from `petrus-engine`, with the reference's messages. `psycopg.Error`
becomes `PostgresError` (see [petrus-motus-absurd's DIVERGENCES](../petrus-motus-absurd/DIVERGENCES.md)).

## `AbsurdSession` and `openAbsurdEngine` (an addition)

The reference closes over its two psycopg connections. The composition here is a record:

- `AbsurdSession`: `connection`, `listen`, `commit`, `rollback`, `close`, `dispatchSession` and
  `observeHistory`;
- `absurdSession`: the connections' own acts;
- `openAbsurdEngine`: the doors over any such record.

`createEngine` and `loadEngine` are `openAbsurdEngine` over `absurdSession`, so they behave as
the reference does. `petrus-dst`'s joined worlds wrap the record to cut a commit at exactly the
reference's fault boundaries ([petrus-dst DIVERGENCES](../petrus-dst/DIVERGENCES.md)). The
reference does this by wrapping the psycopg connection. The statements sent are the same.

## Read-only by construction

The reference tests that the session hands out no writer and that its accessors cannot be
assigned. Here `Engine` is abstract and its reads are functions, so the types enforce this. The
example is kept and says so.

## The Worker process is an executable

`python -m petrus.motus.worker --provider absurd` imports its Activity registries by module path.
A Haskell Worker executable compiles its registries in and passes the Absurd provider to the
`petrus-motus` CLI through `absurdPlugins` (see
[petrus-motus-absurd's DIVERGENCES](../petrus-motus-absurd/DIVERGENCES.md)). The two consequences
for `test_worker_topology.py` are listed in [PARITY.md](PARITY.md): the mutable-registry snapshot
does not apply, and non-string or non-callable registry entries cannot be written. The command
line, its defaults and the JSON event lines on stdout are the reference's.
