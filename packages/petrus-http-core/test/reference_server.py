# The reference for petrus-http-core's differential tests: CPython's
# ThreadingHTTPServer with a BaseHTTPRequestHandler speaking HTTP/1.0, as
# both upstream Petrus services configure it. test/Main.hs runs the same
# handler on petrus-http-core and compares the bytes on the wire.
#
# argv[1]: per-connection timeout in seconds, or "none".
# Prints the bound port, then serves until stdin closes.
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TIMEOUT = None if sys.argv[1] == "none" else float(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(TIMEOUT)

    def log_message(self, format, *args):
        pass

    def parse_request(self):
        words = str(self.raw_requestline, "iso-8859-1").rstrip("\r\n").split()
        self.raw_target = words[1] if len(words) >= 2 else None
        return super().parse_request()

    def echo(self):
        length = self.headers.get("Content-Length")
        body = b""
        if length is not None and length.isascii() and length.isdigit():
            try:
                body = self.rfile.read(int(length))
            except TimeoutError:
                body = b"<timeout>"
        payload = json.dumps(
            [
                self.command,
                self.path,
                self.raw_target,
                self.request_version,
                self.requestline,
                [[k, v] for k, v in self.headers.items()],
                body.decode("latin-1"),
            ]
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = echo

    def do_TEAPOT(self):
        self.send_error(418, "<tea & cake>", "short & stout")

    def do_NOCONTENT(self):
        self.send_error(204)

    def do_UNKNOWN(self):
        self.send_error(599)

    def do_DEFAULT(self):
        self.send_error(404)

    def do_REASON(self):
        self.send_response(299, "Custom Reason")
        self.send_header("X-A", "1")
        self.end_headers()
        self.wfile.write(b"done")

    def do_NOPHRASE(self):
        self.send_response(299)
        self.end_headers()

    def do_BOOM(self):
        raise RuntimeError("boom")


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # keep the test log quiet; the connection still closes


server = Server(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
thread.start()
sys.stdin.read()
server.shutdown()
server.server_close()
thread.join()
