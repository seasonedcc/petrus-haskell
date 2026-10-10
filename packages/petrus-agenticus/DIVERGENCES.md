# petrus-agenticus divergences

These choices are deliberate. None of them changes a History byte, a wire
byte or a refusal; the differential corpora pin all three. The error model
(one `AgenticusError` value with an `ErrorClass` hierarchy and byte-exact
messages) is shared with `petrus-agenticus-core`. It is described in that
package's DIVERGENCES.md.

## Agent-as-a-Net (`Petrus.Agenticus.Program.AgentNet`)

1. **Pure handlers and guards.** The reference's `_classify`, `_reject_tool`
   and `_record` handlers and its `_execute` and `_reject` guards are Python
   functions over plain values. Here they are total, pure Haskell functions:
   `Binding -> [Arc] -> Either Text HandlerResult` and
   `Binding -> Either Text Bool`. A `Left` carries the reference's
   `repr(error)` text, so the Engine records the same failure bytes.

2. **The Net is authored once, with the DSL.** `agentNet` is built with
   `Petrus.Impetus.Dsl` and is spelled exactly like the DSL corpus's
   agent-net. The handler and guard symbols are the reference's
   (`_classify`, `model_phase`, `hands` and so on), so the implementation URIs
   and the net-definition bytes match the reference.
   - The two Activity bridges, `model_phase` and `hands`, are bound to their
     `ActivityHandler`s by URI after the build.
   - `agentNetOptions` installs the handlers, the guards and the CEL compiler
     in one step. The reference passes `handlers=` and `guards=` separately,
     and its CEL compiler is ambient.

3. **`ToolWork` keeps the spelling of its index.** The reference keeps
   whatever JSON value arrived as `index` (Python's `bool` is an `int`, so
   `true` passes as 1 and is written back as `true`). The Haskell record keeps
   the validated `Integer` for logic, plus a hidden copy of the original JSON
   spelling for `to_data`. The resulting bytes are identical.

4. **Python's dynamic type errors are reproduced at the JSON boundary.** These
   are refusals such as `TypeError: '<=' not supported between instances of
   'int' and 'NoneType'`, `slice indices must be integers...` and
   `cannot use 'list' as a set element`. The Haskell constructors cannot
   receive such values; the `*FromData` decoders check for them in the
   reference's order and raise the same class and message. The corpus pins
   each case.

## Attachment binding (`Petrus.Agenticus.Attachment.Binding`)

5. **The protocol is a record.** `AttachmentBinding` is the reference's
   `Protocol`. It is a record of IO actions (`cancel`, `exportArchive`,
   `settle`) plus an optional Motus view. A provider-managed binding is a
   value of that record, not a subclass.

6. **Re-entrancy is tracked per thread.** The reference serializes operations
   with an `RLock` and counts active operations. Here, `withBindingOperation`
   keeps a per-`ThreadId` depth map in STM, so a nested operation on the
   same thread is admitted even after admission closes, as the `RLock`
   allows. `bindingQuiesce` then waits with an STM timeout for active
   operations to reach zero, instead of polling.

7. **Settlement evidence never prints its detail.** `BindingSettlement`'s
   `Show` instance omits `detail`, which can hold provider diagnostics. The
   reference achieves the same with `field(repr=False)`.

8. **Test monkeypatching becomes record overrides.** `EnvironmentProvider` is
   a record of functions. The upstream tests patch `destroy` and `attach`;
   the Haskell tests override `providerDestroy` and `providerAttach` on a
   copy of the real local provider.

## Hands workspace (`Petrus.Agenticus.Hands.Workspace`)

9. **The adapter is a value, not a class.** `MotusWorkspaceAdapter` holds the
   provider, the attachment, its lease and an `IORef` of registered stage
   tokens.
   `workspaceHandsAdapter` turns it into the gateway's `HandsAdapter` record.
   The reference's `HandsAdapter` is a structural `Protocol` that the class
   satisfies.

## Episode attachment (`Petrus.Agenticus.Attachment.Episode`)

10. **The epoch is an `Integer`.** The reference refuses `bool` epochs at run
    time, because Python's `bool` is an `int`. In Haskell, `True` cannot reach
    the constructor, so only the `0` and negative refusals exist.

## Territory retention (`Petrus.Agenticus.Attachment.Retention`)

11. **SQLite through `direct-sqlite`, behind `Petrus.Agenticus.Internal.Sqlite`.**
    `petrus-sqlite` is not on `main` yet, so the ledger talks to SQLite
    through that small internal module (swap point). The DDL strings,
    including their whitespace, and the column order are the reference's, so
    either implementation can open the other's file. The differential corpus
    proves this in both directions.

12. **`timeout=5` becomes `PRAGMA busy_timeout = 5000`.** Python's
    `sqlite3.connect(timeout=5)` installs a 5-second busy handler.
    `setBusyTimeout` installs the same handler through the pragma.
    `inTransaction` is `not (sqlite3_get_autocommit)`, which is how CPython
    computes `Connection.in_transaction`.

13. **The writer fence uses `flock` directly through the FFI.** The reference
    calls `fcntl.flock(LOCK_EX | LOCK_NB)` on `.<name>.writer.lock`. The
    Haskell ledger calls the same `flock(2)` with the same flags. It does not
    use `fcntl` record locks, which would not exclude a second open in the
    same process.

14. **The clock is an `IO Double`.** `openTerritoryCustodyWith path clock`
    takes the reference's `clock=` callable. `openTerritoryCustody` uses
    `getPOSIXTime`, which is `time.time()`.

15. **Test fault injection without monkeypatching.** The reference's tests
    patch `provider.create`, `provider.lookup`, `provider.export`,
    `provider.destroy` and the private `custody._write`. The provider patches
    become record overrides. The `_write` crash is reproduced by a real lock
    conflict, so the failure the ledger sees is `OperationalError`
    ("database is locked"), not `OSError("crash")`. The behaviour under test
    is the same: the lease is destroyed but the tombstone is not committed,
    and a retry still reaches `retired`.

## Packaging

16. **Boundary tests check cabal dependency graphs.** Haskell imports have no
   side effects, so `test_root_import_has_no_facade_or_optional_provider_side_effects`
   cannot observe import-time behaviour. `BoundariesSpec` asserts the
   equivalent structural fact instead: `petrus-agenticus-core` depends on no
   kernel package, and no agenticus package depends on a provider SDK
   binding.
