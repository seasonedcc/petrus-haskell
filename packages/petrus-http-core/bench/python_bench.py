"""Python counterparts of petrus-http-core's benchmarks (see bench/Main.hs).

Runs CPython's http.server the way both upstream services do: a
ThreadingHTTPServer with a BaseHTTPRequestHandler speaking HTTP/1.0 and a
silent log_message. Round trips use a fresh loopback connection per request
with a Python socket client that closes with a reset (SO_LINGER 0) so no
TIME_WAIT sockets pile up. Prints ``name,nanoseconds`` lines
(scripts/bench_timing.py).
"""

import io
import os
import socket
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

SNAPSHOT = (
    b'{"frontier":42,"marking":[{"place":"orders.received","tokens":[{"color":null,"data":{"id":7}}]}],'
    b'"protocol":"petrus.observation.v1"}'
)

GET = (
    b"GET /v1/snapshot HTTP/1.1\r\nHost: 127.0.0.1:8000\r\nUser-Agent: bench\r\n"
    b"Accept: application/json\r\nConnection: close\r\n\r\n"
)
POST = (
    b"POST /v1/simulations HTTP/1.1\r\nHost: 127.0.0.1:8000\r\nOrigin: http://localhost:5173\r\n"
    b"Content-Type: application/json\r\nContent-Length: 1024\r\n\r\n" + b"x" * 1024
)
BROWSER_LINE = b"GET /v1/history?after=0&limit=100 HTTP/1.1\r\n"
BROWSER_HEAD = (
    b"Host: localhost:8000\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r\n"
    b"Accept: application/json\r\nAccept-Language: en-US,en;q=0.9\r\nAccept-Encoding: gzip, deflate, br\r\n"
    b"Origin: http://localhost:5173\r\nConnection: keep-alive\r\nReferer: http://localhost:5173/\r\n\r\n"
)

LINGER_RESET = struct.pack("ii", 1, 0)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, format, *args):
        pass

    def _json(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._json(SNAPSHOT)

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length")))
        self._json(str(len(data)).encode())


class Detached(Handler):
    """A handler without a connection, for the parse and render benchmarks."""

    def __init__(self):
        self.client_address = ("127.0.0.1", 50000)
        self.request_version = "HTTP/1.1"
        self.command = "GET"
        self.requestline = "GET / HTTP/1.1"


def roundtrip(port, request):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
        client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, LINGER_RESET)
        client.connect(("127.0.0.1", port))
        client.sendall(request)
        client.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)


def parse_head():
    handler = Detached()
    handler.raw_requestline = BROWSER_LINE
    handler.rfile = io.BytesIO(BROWSER_HEAD)
    handler.parse_request()
    return handler.path


def send_error():
    handler = Detached()
    handler.wfile = io.BytesIO()
    handler.send_error(404)
    return handler.wfile.getvalue()


def render_response():
    handler = Detached()
    handler.wfile = io.BytesIO()
    handler._json(SNAPSHOT)
    return handler.wfile.getvalue()


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        port = server.server_port
        report("roundtrip.get-snapshot", lambda: roundtrip(port, GET))
        report("roundtrip.post-1k", lambda: roundtrip(port, POST))
        report("roundtrip.refused-version", lambda: roundtrip(port, b"GET / HTTP/2.0\r\n\r\n"))
        report("parse.request-head", parse_head)
        report("render.send-error", send_error)
        report("render.response", render_response)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
