# petrus-motus-zeromq

This package is the ZeroMQ Dispatch transport, protocol v2. It is a port of
`petrus.motus.transport.zeromq` from the pinned reference
(`upstream/petrus`).

ZeroMQ here is a transport, not a custody provider. A server exposes the
Worker side of a Local SQLite Dispatch (claim, heartbeat, complete, fail)
to remote Workers, over IPC or over TCP authenticated with CURVE.
Everything another implementation can observe is the reference's, so
clients and servers of either implementation interoperate in both
directions:
- the frames and the canonical JSON envelopes;
- the error kinds and messages;
- the certificate files and the ZAP domain;
- the IPC ownership lock file;
- the CLI's flags, readiness line and exit statuses.

## Modules

| module | reference | contents |
| --- | --- | --- |
| `Petrus.Motus.Transport.ZeroMQ` | `petrus.motus.transport.zeromq` | the public surface; re-exports the modules below |
| `…ZeroMQ.Client` | `ZeroMQWorkerDispatch`, `AsyncZeroMQWorkerAccess` | the synchronous, thread-confined Worker client (a `WorkerDispatch`) and the native asynchronous `WorkerAccess` with bounded in-flight sockets |
| `…ZeroMQ.Server` | `ZeroMQDispatchServer` | the ROUTER server: request validation, the provider cache per client, drain, stop, the IPC lock and CURVE/ZAP set-up |
| `…ZeroMQ.Wire` | `_encode_*`, `_decode_*`, `_parse_request` | the v2 wire codec and its limits |
| `…ZeroMQ.Curve` | `zmq.auth` | certificate files, client and server security checks, and the ZAP handler |
| `…ZeroMQ.Socket` | `_open_socket` | the client socket seam (`SocketFactory`) and its options |
| `…ZeroMQ.Native` | pyzmq | the libzmq binding (see below) |
| `…ZeroMQ.Cli` | `python -m petrus.motus.transport.zeromq`, `_provider_factory` | the server process entry point, and the Worker CLI's `zeromqPlugins` (`--provider zeromq`, `--custody-access native-zeromq`) |
| `…ZeroMQ.Errors` | | the reference's exception types (`ValueError`, `ConnectionError`, …) |

The `petrus-zeromq-dispatch` executable is the server CLI. It is the
equivalent of `python -m petrus.motus.transport.zeromq`.

A Worker executable that should speak ZeroMQ passes `zeromqPlugins` to
`Petrus.Motus.Worker.Cli.workerMain`.

    server <- localServer "ipc:///run/app/dispatch.sock" "app/dispatch.db" ["default"] Nothing Nothing
    withAsync (serveForever server) $ \_ -> do
      endpoint <- waitReady server 5
      client <- newZeroMQWorkerDispatch endpoint defaultClientOptions
      attempt <- claim client

## Why a direct libzmq binding

`Petrus.Motus.Transport.ZeroMQ.Native` binds 23 libzmq 4.x functions with
`capi` imports:
- context, socket, bind, connect, and socket options;
- `zmq_send` and the `zmq_msg_*` receive path;
- `zmq_has` and `zmq_version`;
- Z85 encoding and CURVE key generation.

It does not use `zeromq4-haskell`, for four reasons:

1. **Send timeouts must behave as the reference's do.** The protocol's
   uncertainty rules depend on `ZMQ_SNDTIMEO`. A send that cannot be queued
   within the request timeout fails as `zmq.Again`, so the outcome is
   "not acknowledged". `zeromq4-haskell`'s `send` always uses `DontWait`
   followed by `threadWaitWrite`, ignores `SNDTIMEO`, and waits forever. The
   binding here keeps every C call non-blocking. It waits on `ZMQ_FD` through
   the GHC IO manager, bounded by the socket's own send timeout. So a wait
   never blocks an OS thread, and it composes with asynchronous exceptions,
   which is how cancellation reaches an in-flight request.
2. **Fewer dependencies.** `zeromq4-haskell` brings `async`,
   `monad-control`, `transformers-base`, `exceptions` and `semigroups`.
   None of them is needed for two dozen C calls.
3. **Maintenance.** The last `zeromq4-haskell` release is from 2019.
4. **Small surface.** About twenty functions are needed, and each one is
   documented next to its use.

CURVE is required for TCP. `curveAvailable` (`zmq_has("curve")`) reports
whether the linked libzmq supports it. Homebrew's and Debian's
`libzmq3-dev` both do.

## Building

The library needs libzmq ≥ 4.1 and its headers (`pkg-config libzmq`):
- macOS: `brew install zeromq`;
- Debian and Ubuntu: `apt-get install libzmq3-dev`. CI installs it.

## Tests, interop, benchmarks

- `cabal test petrus-motus-zeromq` runs the port of
  `test_zeromq_dispatch_transport.py` and the cross-implementation interop
  suite. [PARITY.md](PARITY.md) has the ledger.
- [DIVERGENCES.md](DIVERGENCES.md) lists every intentional difference from
  the reference.
- [bench/RESULTS.md](bench/RESULTS.md) compares request latency and
  throughput with the reference.
