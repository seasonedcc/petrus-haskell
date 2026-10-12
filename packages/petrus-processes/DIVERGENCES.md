# petrus-processes: divergences from `petrus.processes`

The parts meant to match the pinned reference do match. They are checked
against the reference itself on one database:

- the call and spawn payload JSON, and the derived request, reply and child
  identities;
- the spawn idempotency key, the spec digest, and the `impetus_lifecycle`
  schema, rows and statements;
- the refusal categories, and the refusal texts where the spec quotes them;
- the `process.spawn` Activity's invocation and outcome bytes;
- the demo's nets, records and printed lines.

The evidence is in [PARITY.md](PARITY.md). This file lists only differences
in the API surface. The Fabric-level divergences (error type, smart
constructors, U+0000, the canonical encoder) are
[petrus-fabric's](../petrus-fabric/DIVERGENCES.md) and apply here too.

| # | Reference | Haskell | Why |
| --- | --- | --- | --- |
| 1 | `CallRequest`, `CallResult`, `CallError`, `SpawnSpec`, `Provisioning`, `SpawnClaim`, `SpawnOutcome` and `Lineage` are frozen dataclasses. They validate in `__post_init__`, and the payload types offer `to_data()` and `from_data()`. `SpawnSpec.child` and `SpawnSpec.digest` are properties. | Smart constructors (`callRequest`, `spawnSpec`, …) answer `Either FabricError`. Fields are read with record dot syntax. The conversions are `callRequestToData`, `spawnSpecFromData` and so on. `child` and `digest` are computed on first use and then kept. | The same convention as petrus-fabric. |
| 2 | `request_envelope`, `result_envelope` and `error_envelope` take keyword arguments, with `delivery_id=None`. | Positional arguments, with `Maybe Text` for the delivery id override: `requestEnvelope request sender recipient source route Nothing`. | Haskell has no keyword arguments. The argument order follows the reference's keyword order. |
| 3 | `request_envelope(reply_route=None)` raises `ValueError`, because a call needs a reply route. | **Type-enforced.** The route is a `ReplyRoute`, not a `Maybe ReplyRoute`. The conformance twin answers a missing route with an `InvalidType` refusal saying "type-enforced". | The refusal moves from run time to compile time. |
| 4 | `reply_from_envelope(envelope, request=...)` returns a `CallResult` or a `CallError`. | `replyFromEnvelope reply request :: Either FabricError CallReply`, where `CallReply` is `ReplyResult CallResult` or `ReplyError CallError`. | A sum type in place of a union. |
| 5 | `SpawnRegistry` and `ProcessProvisioner` are Protocols. `SpawnActivity(registry, provisioner)` is a callable taking `(invocation, *, context)`. A provisioner whose `ensure` returns anything but `None` raises `TypeError`. A registry returning a non-`SpawnClaim` raises `TypeError`. | `SpawnRegistry` is a record of four functions, and `ProcessProvisioner` is a record with `ensure :: Provisioning -> IO ()`. `spawnActivity registry provisioner invocation :: IO Json` takes no context, since the Activity uses none. A live value cannot be returned from `ensure`, and `claim` can only return a `SpawnClaim` (P-055). [TypedSpec](test/Petrus/Processes/TypedSpec.hs) checks this against the real signature under deferred type errors, and the ported `test_spawn_activity_refuses_a_live_object_from_the_provisioner` runs it. | **Type-enforced refusals.** The other run-time checks are kept with the reference's texts: the activity name, the idempotency key, and a claim for a different identity. |
| 6 | `PostgresSpawnRegistry(connection, parent, credential)` is an object with `claim`, `child_of`, `children_of` and `parent_of` methods. | `postgresSpawnRegistry connection parent credential :: IO PostgresSpawnRegistry`. It refuses a non-autocommit connection with the reference's text. The methods are functions that take the registry first. `spawnRegistry` adapts the registry to the port record for `spawnActivity`. | Haskell module style. The SQL, the authentication and the parent binding are the reference's. |
| 7 | The reference provisioning profile (§13.2), `DemoProvisioner`, lives in `scripts/cv5-lifecycle-demo.py`. | `referenceProvisioner` and `hmacChildCredential` are exported by `Petrus.Processes.Postgres`. | This is an addition. A Haskell parent can provision children exactly as a Python parent does, and either kind of parent can spawn the other's children. |
| 8 | `scripts/cv5-lifecycle-demo.py` starts a disposable PostgreSQL container with docker when `--dsn` is not given. | `cv5-lifecycle-demo` requires `--dsn` and exits 1 without it. Two flags are added. `--child-command` runs the child subprocess with another implementation. `--spawn-worker-command` executes `process.spawn` in a worker of another implementation, with one JSON object per line; `--internal-spawn-worker` is this implementation's worker. Without them, the scenario and its printed lines are the reference's. | The test suites and CI provide a server. The flags drive the cross-implementation runs (P-038, P-079). The worker line protocol keeps the scenario's inline dispatch (the reference's demo executes its Activities inline through `DemoInlineDispatch`, never through custody), and both workers build the invocation through its refusals and answer `f"{type(error).__name__}: {error}"`. Refusals through real Local custody are checked in both directions by `WorkerRefusalSpec` (the reference's dispatcher with each implementation's Worker, and the port's dispatcher with the reference's Worker). |
| 9 | Telemetry (`lifecycle_claimed`, `lifecycle_conflict`, `lifecycle_denied`) goes to the process-wide `impetus` logger. | The same events and fields, emitted through `petrus-telemetry`'s `impetus` logger. | — |
