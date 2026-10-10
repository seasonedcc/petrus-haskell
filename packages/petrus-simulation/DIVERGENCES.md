# petrus-simulation: divergences from the Python reference

## What is identical

**The runner.** For every build, marking and `max_actions` that can be
represented in both languages, `simulate` returns the reference's bytes or
refuses with the reference's `SimulationProfileError` message. Evidence:

- the 27 ported upstream items;
- the owner fixture, compared byte for byte;
- 600 random scenarios replayed against upstream `simulate`
  (`test/CorpusSpec.hs`).

**The service.** Simulation HTTP profile 1 is reproduced byte for byte:

- the order of checks;
- status codes;
- headers and their order;
- error codes and messages;
- the one-slot admission and shutdown behavior.

That includes CPython quirks the reference inherits. A two-word HTTP/0.9
request line, for instance, reaches the handler without headers and gets
`http.server`'s 500 page, as upstream does. Evidence:

- `test/WireSpec.hs` compares full responses for 581 raw requests;
- the upstream urllib tests pass against this service
  (`test/PythonClientSpec.hs`).

The HTTP/1.0 server core's own divergences apply too. See
[petrus-http-core/DIVERGENCES.md](../petrus-http-core/DIVERGENCES.md).

## Wire

| Behavior | Reference | This package | Why |
| --- | --- | --- | --- |
| `Server` header | `BaseHTTP/0.6 Python/3.14.x` | `petrus-haskell/<version>` | It names the implementation. No client or spec depends on it. The wire tests ignore this line and `Date`. |
| TCP segments | Head and body go out in two `sendall`s. | One `sendAll`. | Same bytes, and no delayed-ACK stall. |
| JSON nesting in a request body | `_strict_loads` refuses (400 `invalid_json`) when CPython's C stack runs low. On macOS arm64, CPython 3.14 refuses past about 104,700 nested arrays or 61,600 nested objects in a handler thread. The main thread gives slightly different figures, and other platforms and stack sizes give others. | petrus-json's fixed bound: 100,000 nested containers of either kind. | CPython's figure is not a contract: it varies by thread, platform and build, and `spec/simulation-http-v1.md` does not state one. A fixed bound keeps the service deterministic. Bodies differ only between the two limits: 100,001 to about 104,700 nested arrays, refused here and accepted upstream, and about 61,600 to 100,000 nested objects, refused upstream and accepted here, and then answered by the later checks (usually 409). No valid simulation request nests that deeply. See [petrus-json/DIVERGENCES.md](../petrus-json/DIVERGENCES.md). |

## Inputs that cannot be represented

The reference's tests build some inputs that Haskell's types or smart
constructors rule out. The ported tests keep the refusal they check where
an equivalent input exists.

| Reference input | Here |
| --- | --- |
| A READ selecting arc forced past Net validation with `object.__setattr__` | `Net` is abstract, and `mkNet` refuses a handlerless transition whose inputs only read or inhibit. The test asserts that refusal. |
| `Arc(weight=True)`, or any non-integer weight | `weight :: Int`. Weights other than 1 get the reference's refusal ("exact non-boolean integer 1"). |
| A boolean or non-numeric timer value | Timers take a `Number`. Negative and non-integral values get the reference's refusals. |
| An `ANONYMOUS` callable as an arc filter or as the Net completion | Filters and completions are `Cel` values, so the refusal is enforced by types. `ANONYMOUS` handlers and guards are representable and refused as upstream. |
| A queue item that is not a `Token` | Markings hold `Token`s only. |
| `max_actions` given to `simulate` as a `bool`, `float` or `str` | `simulate` takes an `Int`. `maxActionsFromJson` applies the reference's checks and messages to a JSON value, which is the path the service uses. |
| Mutating the input marking, a profile copy or `server.profile` after the call | Values are immutable. The adapted tests check that results and the served profile cannot change. |

## API

| Python | Haskell | Notes |
| --- | --- | --- |
| `simulate(built, marking, *, max_actions=n) -> bytes`, raising `SimulationProfileError` or any other exception | `simulate :: BuiltNet -> Marking -> Int -> IO (Either SimulationError ByteString)` | Refusals are values. `ProfileError` carries the reference's message. `UnexpectedError` is any other failure, and its text is a Haskell diagnostic, not the Python exception's message. The corpus compares only its kind. |
| Module constants `MAX_PLACES` through `CONNECTION_TIMEOUT_SECONDS`, which tests monkeypatch | `SimulationBounds` and `defaultBounds`, used by `simulateWith`, `simulationProfileWith` and `admit` | The same values. The profile's `bounds` object is built from them. |
| `simulation_profile(built)` | `simulationProfile :: BuiltNet -> Either SimulationError Json` | |
| `_admit`, `_ForbiddenDispatch` and the `max_actions` check (private) | `admit`, `forbiddenDispatch`, `maxActionsFromJson` and `pythonRepr` (exported) | Exported for tests and reuse. `forbiddenDispatch` throws `SimulationProfileException`. |
| `create_simulation_server(built, host, port, *, allowed_origin=...)`, raising `ValueError` or `SimulationProfileError` | `createSimulationServer built host port origin`, throwing `SimulationServerError` (`OriginRefused` with the reference's message, or `BuildRefused`) | Like the reference, it validates, profiles and binds. It starts no thread: the caller runs `serveForever (simulationHttp server)`. |
| Tests replace `simulation_http.simulate`; `CONNECTION_TIMEOUT_SECONDS` | `SimulationServerConfig { runner, connectionTimeout, ... }` and `createSimulationServerWith` | Haskell has no monkeypatching. |
| `server.profile` (a detached copy), `server._profile_bytes` | `simulationServerProfile` (the immutable `Json`) and `simulationServerProfileBytes` | |
| `server.shutdown()` (marks shutting down, then stops the loop) and `server.server_close()` (waits for non-daemon handler threads) | `shutdownSimulationServer` and `closeSimulationServer`; `withSimulationServer` brackets both | Same order and the same waits. |
| `_validate_origin` and `_decode_marking` (private) | `validateOrigin` and `decodeMarking` (exported) | The same messages. `decodeMarking` turns a protocol-v1 marking into a `Marking`. |
| The `export` helper in `tests/simulation_support.py`, with `os` and `tempfile` monkeypatched | `Support.export` with `ExportOps { write, fsync, replace }` (test suite only) | Haskell has no monkeypatching. |
