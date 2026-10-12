# petrus-motus-zeromq: divergences from the Python reference

The wire protocol has no divergences. The interop suite checks all of the
following in both directions:
- frames, envelopes, canonical JSON, limits, and error kinds;
- error messages for every request a conforming peer can send, and for 80
  malformed ones (byte for byte);
- certificate files, the ZAP domain, the IPC lock file, and the CLI's
  readiness line and exit statuses.

The differences below are in the host-language surface. A few concern
requests no conforming peer can produce.

1. **No owner-loop check on the asynchronous access.** The reference's
   `AsyncZeroMQWorkerAccess` belongs to the event loop that created it, and
   refuses use from any other loop with `ZeroMQ Worker access may only be
   used by its owning event loop`. Haskell has no event loop to own. Any
   thread may use an `AsyncZeroMQWorkerAccess`, and its permits bound the
   sockets in flight exactly as the reference's semaphore does. The
   synchronous client keeps the reference's thread confinement and its
   message (`ZeroMQ Worker Dispatch sockets may only be used by their
   owning thread`). See PARITY.md for the test this affects.
2. **Lone surrogate escapes are refused at parse time.** CPython's
   `json.loads` accepts `"\ud800"` into a `str`. The reference then fails
   when it first encodes that string, and answers with a `protocol` error
   quoting the `UnicodeEncodeError`, for example `'utf-8' codec can't
   encode character '\ud800' in position 1: surrogates not allowed`.

   `Data.Text` cannot hold a lone surrogate, so `petrus-json` refuses the
   escape while parsing. The answer has the same kind (`protocol`) and the
   same `request_id` (`unknown`), but the message is `invalid ZeroMQ
   Dispatch JSON message: JSON strings must contain Unicode scalar values`.
   No conforming peer sends a lone surrogate: both encoders refuse to
   produce one.
3. **Nesting depth is a fixed limit.** CPython's JSON decoder recurses, and
   its limit is the interpreter's recursion limit and C stack. The pinned
   CPython 3.14 decodes a request nested 100 001 levels deep and then
   refuses its shape.

   `petrus-json` refuses nesting deeper than 100 000 levels, with a
   `protocol` answer: `invalid ZeroMQ Dispatch JSON message: maximum
   nesting depth (100000) exceeded while decoding a JSON array from a
   unicode string`. The reference's own limit depends on the stack it runs
   on, so no fixed number would match it everywhere. Every valid request is
   far shallower.
4. **SQLite failures are direct-sqlite's.** A custody operation that fails
   inside SQLite answers `service`. The reference's message is
   `str(sqlite3.Error)`; here it is direct-sqlite's error details. Both
   quote SQLite's `sqlite3_errmsg` (`database is locked`, …). Python's
   `sqlite3` module phrases a few conditions itself (a closed connection,
   for one), and those texts can differ. See also
   `packages/petrus-motus/DIVERGENCES.md` (10).
5. **Other unexpected exceptions are spelled by their Haskell type.** A
   `service` answer carries `str(error).strip()`, or the class name when
   that is empty, and a Worker's exception failure carries `repr(error)` and
   the class. Both name the exception through the Motus mapping
   (`packages/petrus-motus/DIVERGENCES.md` item 4), where this package's
   `ConnectionError`, `OperationUncertain`, `_ProtocolError` and `ZMQError`
   declare their classes. The exceptions the protocol can produce all have
   names there:
   - `ValueError` (and a `DispatchError`), refused;
   - `TypeError`, the failure constructor's non-boolean `retryable`;
   - `RuntimeError`, `ConnectionError`, `TimeoutError`, and `OSError`.

   An `IOException` is the `OSError` subclass its `errno` selects. Anything
   else falls back to its Haskell type constructor's name and
   `displayException` text. The interop suite
   compares ten exceptions' `_classified_failure` with the reference's.
6. **The server CLI's program name and its errors.**
   - `petrus-zeromq-dispatch` prints its own name in help and usage text,
     where the reference prints `python -m petrus.motus.transport.zeromq`.
     `serverMainWith` takes the name, and the tests pass the reference's.
   - A startup failure (a refused configuration, an IPC endpoint another
     server owns) exits with status 1. The reference also exits with status
     1, but prints a Python traceback first. Here only the traceback's last
     line goes to stderr, in its `Type: message` form.
   - Usage errors (exit status 2) are the reference's text exactly.
7. **Keyword arguments become option records.** These map as follows:
   - `ZeroMQWorkerDispatch(endpoint, queues=..., worker_id=...,
     client_secret_certificate=..., server_public_certificate=...,
     request_timeout=..., terminal_timeout=...)` becomes
     `newZeroMQWorkerDispatch endpoint ClientOptions{..}`;
   - the asynchronous access takes the same record, whose
     `maxInFlightOperations` is `max_in_flight_operations`;
   - the server's keyword arguments are `ServerOptions`;
   - assigning `client.request_timeout` is `setRequestTimeout` (or
     `setAccessRequestTimeout`).

   The validation and its messages are the reference's.
8. **Test seams are exported functions.** The reference's tests monkeypatch
   `_context`, `_open_socket` and the server's internals. This package
   takes small seams instead:
   - `ClientOptions`'s `socketFactory` (for `_context`) and
     `socketOpener` (for the access's `_open_socket`), fixed at
     construction;
   - `openClientSocket` and `openAccessSocket`, exported under "Seams for
     tests";
   - the server's `fromFactory`, which is the reference's private
     `_from_factory` door.

   Production code has no reason to call them. They change nothing on the
   wire.
9. **The libzmq binding is this package's own.** The reference uses pyzmq.
   Here a thin `capi` binding (`Petrus.Motus.Transport.ZeroMQ.Native`) keeps
   every C call non-blocking and waits through the GHC IO manager; README.md
   explains why. The socket options, the high-water marks, `IMMEDIATE`,
   linger 0 and the send timeout are the reference's. So are the
   per-request DEALER sockets and the ROUTER's `ROUTER_MANDATORY`.

   The ZAP handler that enforces the CURVE allowlist is this package's
   equivalent of pyzmq's `ThreadAuthenticator`. It runs on its own thread
   and gives the same answers: an unknown client key is refused, so the
   stranger's request times out. The thread is linked to the server's: if
   it ever fails, `serveForever` ends with that failure (and `waitReady`
   reports it), where pyzmq's thread would print a traceback and die,
   leaving every later CURVE handshake to time out unexplained. The server
   stops it by cancellation.
