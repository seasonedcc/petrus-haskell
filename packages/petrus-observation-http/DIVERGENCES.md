# petrus-observation-http: divergences from the Python reference

The wire behavior is the reference's, byte for byte, and that covers:

- routes, methods and query grammar;
- status codes, header order and values;
- JSON bodies and error messages;
- the 501 page;
- HTTP/0.9 handling.

`test/WireSpec.hs` compares full responses with the upstream server for 501
requests over each of three Engine states, plus a corpus over failing read
doors. The upstream tests also pass against this server when run as Python
urllib clients (`test/PythonClientSpec.hs`).

What differs is listed below. The HTTP/1.0 server core's own divergences
apply here too: see
[petrus-http-core/DIVERGENCES.md](../petrus-http-core/DIVERGENCES.md).

## Wire

| Behavior | Reference | This package | Why |
| --- | --- | --- | --- |
| `Server` header | `BaseHTTP/0.6 Python/3.14.x` | `petrus-haskell/<version>` | It names the implementation. No client or spec depends on it. The wire tests ignore this line and `Date`. |
| TCP segments | The status line and headers go out in one `sendall`, the body in a second. | The response goes out in one `sendAll`. | Same bytes, fewer segments, and no delayed-ACK stall. |
| JSON nesting while encoding a view | `json.dumps` raises `RecursionError` (503) when the C stack runs low, at about 104,000 nested containers on macOS. | petrus-json's fixed bound of 100,000 nested containers gives 503 `engine_unavailable`, the same outcome. | CPython's figure depends on the stack, so no exact match is possible. Only token data nested 100,000 or more levels deep reaches the difference, and then only between the two limits. The petrus-json divergence is in [petrus-json/DIVERGENCES.md](../petrus-json/DIVERGENCES.md). |

## API

The Python module is a factory over a `ThreadingHTTPServer` subclass. The
Haskell module exposes functions over petrus-http-core's `Server`.

| Python | Haskell | Notes |
| --- | --- | --- |
| `create_observation_server(engine, host, port)` returns an `ObservationHTTPServer` | `createObservationServer engine host port` returns an `ObservationServer` (petrus-http-core's `Server`) | Same contract: it only binds and starts no thread. The caller runs `serveForever`, then `shutdown` and `serverClose`, all re-exported. `withRunningServer` brackets them. |
| `server.engine` (the bound Engine) | none | The server holds `ObservationDoors` instead. Keep the Engine you passed in. |
| Tests replace Engine methods or pass a stub Engine | `ObservationDoors` (`snapshotDoor`, `documentDoor`, `historyDoor`), `engineDoors` and `createObservationServerWith` | Haskell has no monkeypatching. The doors are the three read calls the handler makes. |
| `daemon_threads = True` | `observationServerConfig`: `waitForHandlersOnClose = False`, no socket timeout, and the method list upstream defines `do_*` for | Same behavior, stated as configuration. |
| `except ValueError` gives 400, `except RuntimeError` gives 503, `BrokenPipeError` and `ConnectionResetError` are ignored, `except Exception` gives 500 | `ObservationError`, `EngineValueError` and the adapter's own target and query refusals give 400 with their text. `EngineRuntimeError` gives 503. `EPIPE` and `ECONNRESET` I/O errors are ignored. `EngineTypeError`, `EngineHandlerFailed` and anything else give 500. | The same classes of failure, by Haskell type. JSON encoding refusals map as `json.dumps` raises them: non-finite numbers and over-long integers are a `ValueError`, nesting is a `RecursionError`. Asynchronous exceptions, such as a killed thread, are re-thrown rather than answered. Python's `except Exception` does not catch `KeyboardInterrupt` either. |
| `_ObservationHandler._history_query` (private) | `historyQuery :: Text -> Either Text (Integer, Integer)` and `maxHistoryPageLimit` | Exported for reuse. `Left` carries the reference's `ValueError` text. |
| `log_message` overridden to a no-op | no logging | Same behavior. |
