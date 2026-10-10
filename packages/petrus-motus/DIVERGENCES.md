# petrus-motus: divergences from the Python reference

These are deliberate. Each one keeps the reference's observable behavior for
everything that the Engine and History can see.

1. **One `Dispatch` record instead of two protocols.** The reference has a
   `Dispatch` protocol and a `CancellableDispatch` extension, and tells them
   apart with `isinstance`. Here, `Dispatch` is one record whose `cancel`
   field is `Maybe (CancellationInstruction -> IO CancellationDisposition)`.
   `Nothing` is a Dispatch without recoverable cancellation, and
   `isCancellable` replaces the `isinstance` check.
2. **No lifecycle or wait fields on the port.** A provider's transaction
   hooks and wake-up hint are part of the Engine's provider seam
   (`Petrus.Engine.Provider.EngineResources`), not of `Dispatch`. The
   reference attaches them to the composed Engine too, so nothing observable
   changes. An in-process adapter simply never has to pretend it owns a
   transaction.
3. **Outcomes are a sum type.** `collect` returns
   `[(Int, ActivityOutcome)]`, with `Succeeded Json | Failed ActivityFailure`.
   The reference yields `(occurrence, object)` pairs and separates failures
   with `isinstance(outcome, ActivityFailure)`.
4. **Exception classification by Haskell type name.** `InlineDispatch` gives
   an unclassified exception a retryable `ActivityFailure` whose error type
   is the Haskell exception's type name. The reference uses Python's class
   name. Tests that need the reference's spelling define exceptions with the
   Python names (`RuntimeError`, `LookupError`). A `DispatchError` is spelled
   `ValueError`, the reference's type for it. An empty message is spelled as
   the type name, as `str(exc) or type(exc).__name__` does.
5. **No dataclass reflection.** The adapters are closures. They have no
   `repr`, no `==`, and no field list. Their registries are immutable maps,
   which is the property the reference's frozen dataclass guards. See
   PARITY.md.
6. **Constructors validate as `__post_init__` does.**
   `cancellationInstruction` and `activityAttempt` return `Either Text` with
   the reference's exact messages. Type checks that Python performs at run
   time, such as a bool posing as an occurrence, are enforced by the types.

## Local Dispatch (`Petrus.Motus.Dispatch.Local`)

The shared file has no divergences: schema, DDL text, pragmas, statements,
transactions, JSON encodings and row contents are the reference's. The
interop suite checks this row by row. What differs is the host-language
surface:

7. **Keyword arguments become option records.** `LocalDispatch(path,
   instance=..., default_queue=..., activity_queues=..., clock=...)` becomes
   `openLocalDispatch path instance LocalDispatchOptions{..}`, and
   `LocalWorkerDispatch(path, queues=..., worker_id=..., clock=...,
   _claimant=..., _clock_reader=...)` becomes
   `openLocalWorkerDispatch path LocalWorkerOptions{..}`. The private
   `_clock_reader` is the reader `worker`/`workerWith` share from the
   dispatch (`clockReaderOf`). The explicit claimant `_claimant` is the
   `explicitClaimant` option. `activity_queues` is an ordered list in which a
   later entry for a name wins, as in a `dict`.
8. **The provider clock is `IO Integer`.** The reference refuses a `now_ms`
   that returns a bool, a float or a string. Here those values are
   unrepresentable, so three of the five refusal cases are enforced by the
   types. A negative or out-of-range integer is still refused with the
   reference's message, and the shared reader's no-rewind guard is the same.
9. **The private `TypeError`s.** The reference refuses some inputs with
   `TypeError`: a non-`ActivityInvocation` publication, a
   non-`CancellationInstruction`, a non-`ActivityAttempt` custody operation,
   and a worker given both a clock and a clock reader. All but the last are
   unrepresentable here. The last is a `DispatchError` with the reference's
   exact text.
10. **SQLite errors are direct-sqlite's `SQLError`.** The reference
    surfaces `sqlite3.OperationalError` and `sqlite3.IntegrityError`. The
    port surfaces `Database.SQLite3.SQLError` for the same SQLite
    conditions. The upstream test that expects `sqlite3.IntegrityError` for
    a CHECK violation expects `SQLError` here.
11. **`heartbeat` takes `Maybe Json`.** The reference distinguishes an
    omitted `details` argument (keep the stored details) from
    `details=None` (store JSON null) with a sentinel. Here `Nothing` is
    omitted and `Just Null` is null.
12. **An exception failure is spelled by the Haskell exception.** The
    reference's `fail(attempt, exc)` stores the error as `repr(exc)` and the
    kind as `type(exc).__name__`. Here an `AttemptFailure`'s
    `FailureException` is spelled `TypeName('message')` (Python `repr`
    quoting) after the Haskell exception's type name and `displayException`.
    An exception declared as `ValueError` therefore stores exactly the
    reference's `ValueError('…')`.
13. **The generated claimant's UUID** reads 16 bytes from `/dev/urandom` and
    formats a version-4 UUID as `str(uuid.uuid4())` does.
14. **Corrupt-row messages from the JSON parser.** A durable row that fails
    the reference's *validation* is refused with the reference's exact
    text, prefixed `corrupt durable Activity invocation: ` and so on. A row
    that is not JSON at all carries `petrus-json`'s parse error after that
    prefix, where the reference carries `json.JSONDecodeError`'s text. Such
    a row cannot be written through either implementation, since every
    column has a `json_valid` CHECK.
15. **Connections close when their operation ends.** Both implementations
    open one connection per operation. The reference's read-only
    `with _connect(path) as connection:` blocks, schema initialization among
    them, commit on exit but do not close, because a Python `sqlite3`
    context manager never closes. The connection closes when the cyclic
    garbage collector reaches it. The port closes every connection
    deterministically. Rows and transactions are identical; only the WAL's
    last-close checkpoint timing differs. See `bench/RESULTS.md`.
16. **Spawn-based tests run as threads.** See PARITY.md. The cross-process
    behavior they guard is covered by the interop suite, with reference
    processes and Haskell threads contending on one file.
17. **No `Worker` yet.** `dispatch.worker(...)` returns the custody surface;
    there is no Worker loop to drive it. The upstream Worker-driven
    cancellation test runs the same custody sequence by hand.
