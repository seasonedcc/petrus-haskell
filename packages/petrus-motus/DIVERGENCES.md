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
4. **Exceptions are named by one explicit mapping, not by Python classes.**
   Wherever the reference records `type(error).__name__` and `repr(error)`
   or `str(error)` (the Inline Dispatch, Local and Absurd `fail`, the ZeroMQ
   client's `_classified_failure` and server error kinds, the Engine's
   firing-failure text), the port asks one total function,
   `Petrus.Motus.PythonException.pythonException`. `DispatchError` is the
   reference's `ValueError`. The built-in classes the port raises
   (`ValueError`, `RuntimeError`, `LookupError`, `TypeError`,
   `TimeoutError`, `OSError`, `CancelledError`) are declared there under
   those names. A SQLite failure is `OperationalError`, the class `sqlite3`
   raises for the busy, locked and I/O failures a custody store meets. The
   ZeroMQ and Absurd packages add their own (`ConnectionError`,
   `OperationUncertain`, `_ProtocolError`, `ZMQError`; `AbsurdError` is
   `RuntimeError`).

   The remaining divergence: any other Haskell exception, such as one an
   Activity throws, is named after its Haskell type constructor, since it
   has no Python class. `repr` assumes the exception was raised with its
   message as the one argument. An empty message is spelled `Name()`, and
   the Inline error falls back to the class name, as
   `str(exc) or type(exc).__name__` does. The Local and ZeroMQ spellings
   are compared with the reference's in the interop suites: a refused
   heartbeat's `ValueError` failed through Local, and ten exceptions through
   `_classified_failure`. The Absurd interop compares the `failure_reason`
   rows of a reference and a Haskell exception failure.
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
12. **An exception failure is spelled through the mapping in (4).** The
    reference's `fail(attempt, exc)` stores the error as `repr(exc)` and the
    kind as `type(exc).__name__`. A `FailureException` stores
    `pythonExceptionRepr` and the class name of `pythonException`, so a
    `DispatchError` stores exactly the reference's `ValueError('…')`.
13. **The generated claimant's UUID** takes 16 bytes from the operating
    system's random source through `getentropy`, which `os.urandom` also
    uses, and formats a version-4 UUID as `str(uuid.uuid4())` does.
14. **Corrupt-row messages from the JSON parser.** A durable row that fails
    the reference's *validation* is refused with the reference's exact
    text, prefixed `corrupt durable Activity invocation: ` and so on. A row
    that is not JSON at all carries `petrus-json`'s parse error after that
    prefix, where the reference carries `json.JSONDecodeError`'s text. Such
    a row cannot be written through either implementation, since every
    column has a `json_valid` CHECK.
15. **Sessions keep their connections open between operations.** Both
    implementations run every operation on a connection of its own, with
    the reference's pragmas, statements and transactions. The reference
    opens a new connection for each operation. Its read-only
    `with _connect(path) as connection:` blocks, schema initialization
    among them, commit on exit but do not close, because a Python `sqlite3`
    context manager never closes. Those connections linger until the cyclic
    garbage collector reaches them.

    The port keeps up to four idle connections per session in a pool
    (`Petrus.Sqlite.Pool`) and reuses them for later operations. The
    workers a session constructs (`worker`, `workerWith`) share its pool.
    The pool closes deterministically:
    - `closeLocalDispatch` or `withLocalDispatch` closes a session's pool;
    - `close` closes the pool of a worker opened on its own, where the
      reference's `close()` does nothing;
    - `LocalConnections` lets independent workers share one pool, which its
      creator closes. The ZeroMQ server's Local providers share one this
      way, closed when the server stops;
    - a session dropped without closing closes its pool when it is garbage
      collected.

    Everything stays usable after a close: each later operation opens and
    closes a connection of its own, as in the reference. A pooled
    connection is reused only while the path still names the file it was
    opened on, and a connection that saw a SQLite error is not reused.

    Rows, statements and transactions are identical, and the interop suite
    checks this. What differs is when connections open and close, and so
    when the WAL's last-close checkpoint runs. In the port it runs when the
    last pool closes. In the reference it runs whenever an operation's
    connection happens to be the only one open. See `bench/RESULTS.md`.
16. **Spawn-based tests run as threads.** See PARITY.md. The cross-process
    behavior they guard is covered by the interop suite, with reference
    processes and Haskell threads contending on one file.
17. **The Worker-driven Local cancellation test runs by hand.**
    `test_running_cancellation_..._quarantine` was ported before the Worker
    runtime. It runs the same custody sequence over `dispatch.worker(...)`
    by hand. The Worker's own drain and terminal reporting are covered by
    the Worker specs. See PARITY.md.

## Worker runtime (`Petrus.Motus.Worker`, `Petrus.Motus.Worker.Cli`)

What a Worker exchanges with custody is the reference's:
- the claim, heartbeat and terminal sequence;
- the failure classification;
- the result normalization (`json.loads(json.dumps(result, allow_nan=False))`);
- the supervisor-facing event lines (CPython's default `json.dumps`
  spelling, members in the reference's order);
- the exit statuses and every CLI message.

Interop checks this both ways. What differs is the host-language surface:

18. **One Activity type, no function colours.** The reference keeps
    synchronous and `async def` Activities apart. `Worker` refuses
    coroutine functions, `AsyncWorker` refuses synchronous definitions, and
    `@activity` / `@async_activity` check signatures and type annotations.
    Here an `Activity` is `ActivityInvocation -> ActivityExecutionContext -> IO Json`
    and serves both Workers. Those refusals have nothing to refuse. An
    `AsyncWorker` runs each Activity on its own thread, which is how GHC
    threads give an `async def` its concurrency.
19. **Cancellation is an asynchronous exception.** The reference's
    `AsyncWorker.run` absorbs a `CancelledError` thrown into its task:
    admission stops, running Activities and claims in progress drain,
    custody closes, and the cancellation is re-raised. `runAsyncWorker` does
    the same with any asynchronous exception thrown at its thread
    (`killThread`, `cancel`, `timeout`). A Worker error raised meanwhile
    wins, as in the reference.

    An Activity that ends with an asynchronous exception is reported as the
    reference reports a cancelled task: `RuntimeError("Activity cancelled:
    …")`. `CancelledError` is provided for an Activity that wants to cancel
    itself with a message.
20. **The sync bridge's lanes are threads, not executor workers.** The
    reference gives each slot a dedicated `threading.Thread` that owns the
    provider its factory built. Here each slot gets a forked lane thread
    (`forkLane`), with the same ownership: every custody call for a slot
    runs on that slot's thread.

    A `LaneSpawner` argument replaces the reference's monkeypatched
    `Thread.start` as the seam for thread-start failures. The native-access
    door, `AsyncWorker._from_async_access`, is the public
    `asyncWorkerFromAccess`.
21. **Keyword arguments become `WorkerOptions`.** `resolver=`, `worker_id=`
    and the event sink are fields of `WorkerOptions`. `output` replaces the
    reference's `print`, so an embedding host can route or silence event
    lines. It defaults to `stdoutEvents`, which writes the reference's
    bytes. `run(poll_interval=)` and `run_available(limit=)` take their
    arguments positionally.
22. **Registries are compiled in, not imported by name.** The reference's
    `--registry module:attribute` imports a Python module at run time.
    Haskell cannot do that, so an application builds its own worker
    executable around `workerMain`. It passes the registries it was
    compiled with, keyed by the same `module:attribute` spellings, and the
    provider plugins it links. Local custody is built in. Absurd and ZeroMQ
    arrive as `ProviderPlugins`, so this package never links libpq or
    libzmq.

    A spelling that is malformed, unknown, or yields an invalid registry is
    refused with exit status 1 and a message in the reference's style. The
    reference's import errors (`ModuleNotFoundError` and so on) have no
    equivalent here.

    The program name in help and usage text is the one the executable
    passes to `workerMain`. The byte-for-byte comparisons pass the
    reference's `python -m petrus.motus.worker`.
23. **Exception names come from the mapping in (4).** A failure the Worker
    hands to custody (`FailureException`) is spelled as in (12). The
    Worker's own refusals (`ValueError`, `RuntimeError`, `LookupError`) are
    the mapping's built-in classes, so they read identically.
