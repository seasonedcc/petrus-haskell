# petrus-motus-zeromq: parity with the Python reference

This package ports `petrus/motus/transport/zeromq.py` and its server CLI.
The upstream tests are in
`tests/petrus/motus/transport/test_zeromq_dispatch_transport.py`.

`cabal test petrus-motus-zeromq` runs the suite with no failure and no pending example:
- 35 in `test_zeromq_dispatch_transport.py`
  (`test/Petrus/Motus/Transport/ZeroMQ/TransportSpec.hs`): the 32 of the
  ledger below and 3 beyond the reference suite (the CPython wording of
  `_decode_message`'s refusals; a CURVE server stopped while its clients
  are connected; a receive with no deadline cancelled while peers come and
  go, the last two for the 50 ms poll bound in README.md);
- 12 in the interop suite (`test/Petrus/Motus/Transport/ZeroMQ/InteropSpec.hs`);
- 1 boundary row (`test/Petrus/Motus/Transport/ZeroMQ/BoundarySpec.hs`);
- 3 properties of the wire codecs
  (`test/Petrus/Motus/Transport/ZeroMQ/WirePropertiesSpec.hs`).

The reference's processes are needed by the interop examples and by the two
"the reference's server" cases. They provision the pinned reference through
`scripts/upstream-python` and fail, never go pending, when they cannot.

To check that every upstream test is accounted for:

    python3 packages/petrus-engine/scripts/parity_check.py

## Ledger

| upstream | collected | status |
| --- | ---: | --- |
| test_zeromq_dispatch_transport.py, 26 tests | 30 | 25 ported by name; 1 ported in part (below) |
| test_package_boundaries.py `test_zeromq_transport_base_import_is_optional_and_deep_import_has_guidance` | 1 | ported over Cabal metadata (below) |

### The boundary row

The reference's base `petrus.motus.transport` is an empty namespace, and its
deep import names the missing `zeromq` extra. Here, `petrus-motus` links no
libzmq, neither through a Haskell package nor through `pkgconfig-depends` or
`extra-libraries`. No package but this one exposes a `Petrus.Motus.Transport`
module. This package requires `libzmq` through pkg-config, so a build without
the native library stops at configure and names it. The README carries the
install guidance (`brew install zeromq`, `apt-get install libzmq3-dev`).

### Parametrized tests

- `test_worker_socket_setup_failure_closes_new_socket[asynchronous]` has the
  cases `asynchronous=False` and `asynchronous=True`. Both are ported.
- `test_tcp_requires_curve_and_ipc_rejects_curve_configuration[endpoint]`
  has the cases `tcp://127.0.0.1:5000` and `ipc:///tmp/impetus-test`. Both
  are ported.
- `test_non_finite_request_terminal_and_drain_timeouts_are_refused[timeout]`
  has the cases `nan`, `inf` and `-inf`. All three are ported.

### Added parametrization

Two process-death tests start a replacement or restarted server process:
- `test_uncertain_completion_redelivers_exactly_across_dispatch_process_death`;
- `test_dispatch_service_process_death_preserves_lease_details_and_restart_recovery`.

In the port, each runs twice: once with this package's server process
(this test executable re-executed as the server CLI), and once with the
reference's `python -m petrus.motus.transport.zeromq`. Either server must
take over the other's custody state and honour this client's redelivery.

### Ported in part

- `test_async_access_refuses_wrong_loop_and_owner_close_remains_idempotent`
  is ported as
  `async access owner close remains idempotent (the wrong-loop refusal has no Haskell analogue)`.

  The reference checks two things:
  - an `AsyncZeroMQWorkerAccess` refuses use from an event loop other than
    the one that created it (`ZeroMQ Worker access may only be used by its
    owning event loop`);
  - closing it twice is harmless.

  A Haskell access belongs to no event loop: any thread may use it, and
  admission is bounded by its permits. So the first check has nothing to
  check. The port keeps the second, and adds that every operation after
  close is refused with the reference's `is closed` message. See
  DIVERGENCES.md (1).

### Markers and fixtures

The upstream file has no skip or `xfail` markers. Its fixtures map as
follows.

- **`tmp_path`.** Short temporary directories
  (`getTemporaryDirectory` + `pzq…`), because macOS limits IPC socket paths
  to 104 bytes.
- **Spawned server processes.** These are the test executable re-executed
  with `PETRUS_ZEROMQ_TEST_SERVER` set:
  - `server` is the server CLI;
  - `delayed` is the reference's delayed-completion server script: it
    commits a completion, records that it did, then hangs.
- **`monkeypatch` on `_context` and `_open_socket`.** These become the
  client socket seams (`ClientOptions`'s `socketFactory` and
  `socketOpener`). They inject:
  - sockets that fail while being configured;
  - sockets that block while sending;
  - sockets that never answer.
- **The reference's raw ROUTER/DEALER probes.** These are the thin native
  binding's own DEALER sockets.

## Interop evidence (`InteropSpec.hs`)

These examples run the pinned reference with
`test/interop/zeromq_interop.py`.

1. **The reference's clients against this package's server.** This runs
   over IPC, and over CURVE-authenticated TCP with certificates written by
   this package.

   The driver's `client` scenario runs the reference's
   `ZeroMQWorkerDispatch` and native `AsyncZeroMQWorkerAccess` through:
   - a v2 invocation with nested input, non-ASCII text, a float, and a full
     execution policy;
   - claim, heartbeat (with details, then omitted, then null), completion,
     and stale-attempt and conflict refusals;
   - native-access heartbeats, and an empty claim after draining;
   - a stranger key refused by the server's ZAP allowlist, on TCP.

   On this side, `collect` must return exactly the reference client's
   outcomes. Occurrence 4 failed retryably and must still be in backoff.
2. **This package's clients against the reference's server CLI.** This runs
   over IPC, and over CURVE TCP with certificates written by `zmq.auth`. The
   same custody sequence runs from the Haskell clients. Terminating the
   reference's server must exit with status 0.
3. **A raw corpus, byte for byte.** 80 raw requests go to both servers, and
   every reply must be byte-identical. The corpus covers:
   - valid claims, malformed UTF-8, malformed JSON, and wrong types;
   - missing and widened fields, and unknown versions and operations;
   - over-long identities and integers, and multipart violations;
   - stale attempts and invalid failures.

   The answers must count exactly 2 `ok`, 70 `protocol`, 7 `refused` and 1
   `service`. The error texts quote CPython's `UnicodeDecodeError` and
   `JSONDecodeError` messages, so the Haskell server reproduces them
   (petrus-json's `Petrus.Json.Python.Decode` and
   `Petrus.Json.Python.Scanner`).
4. **Process death across implementations.** This is the added
   parametrization above: a Haskell client's uncertain completion is
   redelivered exactly once to a reference replacement server. A
   reference server also takes over Haskell-written custody after a crash
   and restart.

5. **The server CLI.** `python -m petrus.motus.transport.zeromq` and this
   package's CLI, run under the reference's program name, are compared on
   the same argument vectors:
   - help output, byte for byte;
   - missing options, an invalid float, an unrecognized argument, and
     abbreviated options: usage errors with exit status 2, byte for byte;
   - a refused configuration (TCP without CURVE): exit status 1, with the
     same final stderr line.
6. **Exception classification.** Ten exceptions a Worker can report
   (`DispatchError` with a message and empty, the built-in exception types
   the port names, and the transport's `NotAcknowledged`,
   `OperationUncertain` and `ProtocolError`) are classified by `Wire` and
   must equal the reference's `_classified_failure` of their Python twins
   (`ConnectionError`, `OperationUncertain`, `_ProtocolError`): the
   failure's `error`, `kind` and `retryable`.

Benchmarks against the reference are in [bench/RESULTS.md](bench/RESULTS.md).
