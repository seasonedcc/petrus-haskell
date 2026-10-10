# petrus-http-core: divergences from CPython's http.server

These are the intentional differences from CPython 3.14's
`ThreadingHTTPServer` with a `BaseHTTPRequestHandler` at
`protocol_version = "HTTP/1.0"`, which both upstream services use. Everything
else is meant to be byte-identical. The test suite runs the same handler on
both servers and compares full responses for more than 80 raw requests,
covering:

- malformed request lines and versions;
- HTTP/0.9;
- the line and header-count limits;
- folded, duplicate and malformed headers;
- latin-1 bytes;
- bodies, pipelining and timeouts;
- `send_error` pages.

It also compares 1,500 generated request lines with `parse_request` and
1,500 generated header blocks with `http.client`.

| Behavior | CPython | petrus-http-core | Why |
| --- | --- | --- | --- |
| `Server` header | `BaseHTTP/0.6 Python/3.14.x` | `petrus-haskell/<version>` (`serverSoftware`, configurable). | It names the implementation; clients do not depend on it. This is the only intended byte difference. |
| Writes | The status line and headers go out in one `sendall`, the body in a second (`wbufsize = 0`). | `sendResponse` and `sendError` write the response in one `sendAll`. | Same bytes in fewer TCP segments, and no Nagle/delayed-ACK stall between the two writes. |
| Threads | One OS thread per connection. | One GHC thread per connection. | Lightweight and cheap; the observable behavior is the same. |
| Process exit with running handlers | Non-daemon handler threads keep the process alive (the simulation server). | Returning from `main` ends every thread. Call `serverClose` with `waitForHandlersOnClose` first, as upstream's shutdown sequence does. | GHC semantics. |
| `shutdown()` with no loop running | Blocks forever: it waits for an event only `serve_forever` sets. | Returns at once. The request still stands, so the next `serveForever` returns at once and clears it, as in CPython. | A deadlock is never wanted. |
| Accept loop wake-up | `serve_forever(poll_interval)` notices `shutdown()` within the poll interval (0.5 s by default). | Woken at once through STM. | Faster shutdown, same ordering. |
| Logging | `log_message` writes an access and error log to standard error. | No log at all. | Both upstream servers override `log_message` with a no-op. |
| `handle_error` | Prints a traceback between dashed lines. | The `reportException` hook. The default prints the same frame and client address with the exception's `displayException` instead of a traceback. | Haskell exceptions carry no Python traceback; consumers can install their own reporter. |
| Header values | `str` decoded from ISO-8859-1. | The same characters as raw bytes. Use `Data.Text.Encoding.decodeLatin1` for `Text`. | Lossless and cheaper; ISO-8859-1 maps bytes to code points one to one. |
| Non-ISO-8859-1 reason phrase | `UnicodeEncodeError`, which goes to `handle_error`. | `ResponseEncodingError`, which goes to `reportException`. | Same outcome: no response, connection closed. |
| Timeout of zero | `settimeout(0)` makes the socket non-blocking, so a receive with no data raises `BlockingIOError`. | `Just 0` times out any receive or write that would wait, raising `ConnectionTimeout`. | Neither upstream service uses a zero timeout. |
| `server_name` | `HTTPServer.server_bind` resolves `socket.getfqdn(host)`. | Not computed. | Upstream never reads it, and a reverse DNS lookup at bind time can stall. |

Behaviors that might look like divergences but match CPython:

- Each socket operation has its own timeout. Each receive waits at most the timeout. A write is one `sendAll` with a single deadline, like `sendall` since Python 3.5.
- Reads use the same 128 KiB request size as CPython 3.14's buffered reader (`io.DEFAULT_BUFFER_SIZE`). Pipelined bytes are therefore consumed and discarded the same way, and the connection closes with FIN or RST under the same conditions.
- `shutdown(SHUT_WR)` comes before `close`, and pipelined requests are ignored.
- `HEAD` handling is identical: `sendError` leaves out the page for `HEAD`, while `sendResponse` writes whatever body it is given, as `wfile.write` does.
