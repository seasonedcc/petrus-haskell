#!/usr/bin/env python3
"""A hermetic stand-in for E2B: the control-plane REST API and envd.

    fake_e2b.py STATE_DIR API_KEY

Prints ``PORT <n>`` on its first stdout line, then serves on 127.0.0.1:<n>
until killed.  One server plays both parts: the API (``/v2/sandboxes``,
``/sandboxes/{id}``) and the shared envd ingress (``https://sandbox.<domain>``
in production), which routes on the ``E2b-Sandbox-Id`` header.

The wire protocol is the one the official ``e2b`` Python SDK 2.55.1 speaks,
read from its source:

* ``e2b/sandbox_sync/sandbox_api.py`` and ``e2b/api/client/api/sandboxes``:
  ``POST /v2/sandboxes`` (201, ``sandboxID``/``envdVersion``/
  ``envdAccessToken``), ``POST /v2/sandboxes/{id}/connect`` (200; 404 when
  gone), ``DELETE /sandboxes/{id}`` (204; 404 when gone), and
  ``GET /v2/sandboxes`` with ``metadata`` (an urlencoded ``k=v`` string),
  ``limit`` and ``nextToken``, the next page announced by ``x-next-token``.
  Requests carry ``X-API-KEY``; errors are JSON ``{"code", "message"}``.
* ``e2b/sandbox_sync/filesystem/filesystem.py``: ``POST /files?path=`` with a
  multipart field ``file`` answers a JSON list of written entries;
  ``GET /files?path=`` answers the bytes, 404 when missing; ``username=user``
  is sent to envd older than 0.4.0.
* ``e2b/envd/process``, ``e2b/envd/filesystem`` and ``e2b/envd/client_shared.py``:
  Connect RPC with the JSON codec, uncompressed.  ``process.Process/Start``
  is a server stream (``application/connect+json``, 5-byte envelopes, a final
  end-stream envelope with flag 2) of ``{"event": {"start"|"data"|"end"}}``
  messages; ``process.Process/SendSignal`` and
  ``filesystem.Filesystem/Remove`` are unary (``application/json``), with
  errors as ``{"code": "not_found", ...}``.  envd requests carry
  ``X-Access-Token``, ``E2b-Sandbox-Id`` and ``E2b-Sandbox-Port: 49983``;
  old envd also gets ``Authorization: Basic dXNlcjo=``.

Each sandbox's guest file system is a host directory: guest ``/home/user``
and ``/tmp`` live under ``STATE_DIR/<sandbox>/``, and commands run there
for real (``/bin/bash -l -c``), with those two guest prefixes rewritten in
the command text and the cwd.  A command sees only ``PATH``, ``HOME``,
``COPYFILE_DISABLE=1`` (so macOS tar adds no AppleDouble members) and the
``envs`` it was started with, never the server's environment.  A killed
command ends with exit code -1, ``exited: false`` and status
``signal: killed``, as envd (Go's ``ProcessState``) reports it.

Templates: ``old-envd`` reports envd 0.0.9 (the SDK refuses it),
``envd-0.3`` reports envd 0.3.0 (default-user era); anything else 0.5.8.

Test controls (not part of E2B):

* ``GET /_fake/requests``: every request so far, as JSON;
* ``POST /_fake/fail`` with ``{"path": ..., "status": ..., "count": n}``
  (and optionally ``"method"``): answer the next ``n`` such requests with
  that status;
* ``POST /_fake/drop-next-stream``: drop the next command stream right
  after its start event.
"""

import base64
import json
import os
import re
import secrets
import shutil
import signal
import struct
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.path.abspath(sys.argv[1])
API_KEY = sys.argv[2]
LOCK = threading.Lock()
SANDBOXES = {}
ORDER = []
PROCESSES = {}
REQUESTS = []
FAILURES = []
DROP_NEXT_STREAM = [False]
COUNTER = [0]
GUEST = re.compile(r"(?<![\w./-])/(home/user|tmp)(?=/|\b)")
ENVD_PORT = "49983"


def envd_version(template):
    if template == "old-envd":
        return "0.0.9"
    if template == "envd-0.3":
        return "0.3.0"
    return "0.5.8"


def guest_to_host(sandbox, text):
    root = sandbox["root"]
    return GUEST.sub(lambda match: root + "/" + match.group(1), text)


def sandbox_json(sandbox):
    return {
        "templateID": sandbox["template"],
        "sandboxID": sandbox["id"],
        "clientID": "fake-client",
        "envdVersion": sandbox["envdVersion"],
        "envdAccessToken": sandbox["token"],
    }


def envelope(flags, payload):
    data = json.dumps(payload).encode()
    return struct.pack(">BI", flags, len(data)) + data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # -- plumbing ---------------------------------------------------------

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def send(self, status, payload=None, raw=None, content_type="application/json", headers=()):
        data = raw if raw is not None else (b"" if payload is None else json.dumps(payload).encode())
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if status != 204:
            self.wfile.write(data)

    def record(self, body):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path.startswith("/_fake/"):
            return parsed
        entry = {
            "method": self.command,
            "path": parsed.path,
            "query": urllib.parse.parse_qs(parsed.query),
            "headers": {name.lower(): value for name, value in self.headers.items()},
        }
        content_type = self.headers.get("Content-Type", "")
        if content_type == "application/json" and body:
            entry["json"] = json.loads(body)
        elif content_type == "application/connect+json" and len(body) >= 5:
            entry["envelope_flags"] = body[0]
            entry["json"] = json.loads(body[5:])
        elif content_type.startswith("multipart/form-data"):
            entry["multipart"] = True
        with LOCK:
            REQUESTS.append(entry)
        return parsed

    def injected_failure(self, path):
        with LOCK:
            for failure in FAILURES:
                if failure["path"] == path and failure.get("method", self.command) == self.command and failure["count"] > 0:
                    failure["count"] -= 1
                    return failure["status"]
        return None

    def route(self):
        body = self.body()
        parsed = self.record(body)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        if path.startswith("/_fake/"):
            return self.control(path, body)
        status = self.injected_failure(path)
        if status is not None:
            return self.send(status, {"code": status, "message": "injected failure"})
        if self.headers.get("E2b-Sandbox-Id") is not None:
            return self.envd(path, query, body)
        if self.headers.get("X-API-KEY") != API_KEY:
            return self.send(401, {"code": 401, "message": "Invalid API key"})
        return self.api(path, query, body)

    do_GET = do_POST = do_DELETE = route

    # -- test controls ----------------------------------------------------

    def control(self, path, body):
        if path == "/_fake/requests":
            with LOCK:
                return self.send(200, REQUESTS)
        if path == "/_fake/fail":
            failure = json.loads(body)
            with LOCK:
                FAILURES.append(failure)
            return self.send(200, {})
        if path == "/_fake/drop-next-stream":
            DROP_NEXT_STREAM[0] = True
            return self.send(200, {})
        return self.send(404, {"code": 404, "message": "unknown control"})

    # -- control plane ----------------------------------------------------

    def api(self, path, query, body):
        if path == "/v2/sandboxes" and self.command == "POST":
            request = json.loads(body)
            with LOCK:
                COUNTER[0] += 1
                identifier = "sbx%04d%s" % (COUNTER[0], secrets.token_hex(4))
                root = os.path.join(STATE, identifier)
                for directory in ("home/user", "tmp"):
                    os.makedirs(os.path.join(root, directory))
                sandbox = {
                    "id": identifier,
                    "template": request["templateID"],
                    "metadata": dict(request.get("metadata") or {}),
                    "timeout": request.get("timeout"),
                    "envdVersion": envd_version(request["templateID"]),
                    "token": secrets.token_hex(16),
                    "root": root,
                    "state": "running",
                }
                SANDBOXES[identifier] = sandbox
                ORDER.append(identifier)
            return self.send(201, sandbox_json(sandbox))
        if path == "/v2/sandboxes" and self.command == "GET":
            wanted = {}
            for encoded in query.get("metadata", []):
                for key, value in urllib.parse.parse_qsl(encoded, keep_blank_values=True):
                    wanted[urllib.parse.unquote(key)] = urllib.parse.unquote(value)
            states = query.get("state", ["running,paused"])[0].split(",")
            limit = int(query.get("limit", ["100"])[0])
            offset = int(query.get("nextToken", ["0"])[0])
            with LOCK:
                matching = [
                    SANDBOXES[identifier]
                    for identifier in ORDER
                    if SANDBOXES[identifier]["state"] in states
                    and all(SANDBOXES[identifier]["metadata"].get(k) == v for k, v in wanted.items())
                ]
            page = matching[offset : offset + limit]
            listed = [
                {
                    "templateID": sandbox["template"],
                    "sandboxID": sandbox["id"],
                    "clientID": "fake-client",
                    "startedAt": "2026-10-11T00:00:00Z",
                    "endAt": "2026-10-11T00:15:00Z",
                    "cpuCount": 2,
                    "memoryMB": 512,
                    "diskSizeMB": 1024,
                    "state": sandbox["state"],
                    "envdVersion": sandbox["envdVersion"],
                    "metadata": sandbox["metadata"],
                }
                for sandbox in page
            ]
            headers = []
            if offset + limit < len(matching):
                headers.append(("x-next-token", str(offset + limit)))
            return self.send(200, listed, headers=headers)
        match = re.fullmatch(r"/v2/sandboxes/([^/]+)/connect", path)
        if match and self.command == "POST":
            with LOCK:
                sandbox = SANDBOXES.get(match.group(1))
            if sandbox is None or sandbox["state"] == "killed":
                return self.send(404, {"code": 404, "message": "sandbox not found"})
            return self.send(200, sandbox_json(sandbox))
        match = re.fullmatch(r"/sandboxes/([^/]+)", path)
        if match and self.command == "DELETE":
            with LOCK:
                sandbox = SANDBOXES.get(match.group(1))
                if sandbox is None or sandbox["state"] == "killed":
                    sandbox = None
                else:
                    sandbox["state"] = "killed"
            if sandbox is None:
                return self.send(404, {"code": 404, "message": "sandbox not found"})
            for process in list(PROCESSES.values()):
                if process["sandbox"] == sandbox["id"]:
                    kill_group(process["popen"])
            shutil.rmtree(sandbox["root"], ignore_errors=True)
            return self.send(204)
        return self.send(404, {"code": 404, "message": "no route"})

    # -- envd -------------------------------------------------------------

    def envd(self, path, query, body):
        with LOCK:
            sandbox = SANDBOXES.get(self.headers["E2b-Sandbox-Id"])
        if sandbox is None or sandbox["state"] == "killed":
            return self.send(502, {"code": 502, "message": "The sandbox was not found"})
        if self.headers.get("E2b-Sandbox-Port") != ENVD_PORT or self.headers.get("X-Access-Token") != sandbox["token"]:
            return self.send(401, {"code": 401, "message": "unauthorized access token"})
        old_envd = sandbox["envdVersion"] < "0.4.0"
        if path == "/files":
            if old_envd and query.get("username") != ["user"]:
                return self.send(400, {"code": 400, "message": "username required"})
            target = guest_to_host(sandbox, query["path"][0])
            if self.command == "GET":
                if not os.path.isfile(target):
                    return self.send(404, {"code": 404, "message": "path not found"})
                with open(target, "rb") as handle:
                    return self.send(200, raw=handle.read(), content_type="application/octet-stream")
            parts = [
                content
                for headers, content in multipart_parts(self.headers["Content-Type"], body)
                if re.search(r'form-data; *name="file"', headers.get("content-disposition", ""))
            ]
            if len(parts) != 1:
                return self.send(400, {"code": 400, "message": "expected one file part"})
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(parts[0])
            return self.send(200, [{"name": os.path.basename(target), "type": "file", "path": query["path"][0]}])
        if old_envd and self.headers.get("Authorization") != "Basic dXNlcjo=":
            return self.send(401, {"code": "unauthenticated", "message": "user required"})
        if path == "/filesystem.Filesystem/Remove":
            target = guest_to_host(sandbox, json.loads(body)["path"])
            if os.path.isdir(target) and not os.path.islink(target):
                shutil.rmtree(target)
            elif os.path.lexists(target):
                os.unlink(target)
            else:
                return self.send(404, {"code": "not_found", "message": "path not found"})
            return self.send(200, {})
        if path == "/process.Process/SendSignal":
            request = json.loads(body)
            pid = request["process"]["pid"]
            with LOCK:
                process = PROCESSES.get(pid)
            if process is None or process["popen"].poll() is not None or request["signal"] != "SIGNAL_SIGKILL":
                return self.send(404, {"code": "not_found", "message": "process with pid %d not found" % pid})
            kill_group(process["popen"])
            return self.send(200, {})
        if path == "/process.Process/Start":
            return self.start(sandbox, json.loads(body[5:]))
        return self.send(404, {"code": "not_found", "message": "no route"})

    def chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()

    def start(self, sandbox, request):
        config = request["process"]
        argv = [config["cmd"]] + list(config.get("args", []))
        if argv[:3] != ["/bin/bash", "-l", "-c"] or len(argv) != 4:
            return self.send(400, {"code": "invalid_argument", "message": "unexpected process config"})
        environment = {
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": sandbox["root"] + "/home/user",
            "COPYFILE_DISABLE": "1",
        }
        environment.update(config.get("envs") or {})
        cwd = guest_to_host(sandbox, config.get("cwd") or "/home/user")
        try:
            popen = subprocess.Popen(
                ["/bin/bash", "-l", "-c", guest_to_host(sandbox, argv[3])],
                cwd=cwd,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except OSError as error:
            return self.send(400, {"code": "invalid_argument", "message": str(error)})
        with LOCK:
            PROCESSES[popen.pid] = {"sandbox": sandbox["id"], "popen": popen}
        self.send_response(200)
        self.send_header("Content-Type", "application/connect+json")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.chunk(envelope(0, {"event": {"start": {"pid": popen.pid}}}))
        if DROP_NEXT_STREAM[0]:
            DROP_NEXT_STREAM[0] = False
            kill_group(popen)
            self.close_connection = True
            self.connection.shutdown(2)
            return
        events = []
        condition = threading.Condition()

        def pump(stream, name):
            for data in iter(lambda: stream.read1(4096), b""):
                with condition:
                    events.append((name, data))
                    condition.notify()
            with condition:
                events.append((name, None))
                condition.notify()

        readers = [
            threading.Thread(target=pump, args=(popen.stdout, "stdout"), daemon=True),
            threading.Thread(target=pump, args=(popen.stderr, "stderr"), daemon=True),
        ]
        for reader in readers:
            reader.start()
        closed = 0
        while closed < 2:
            with condition:
                while not events:
                    condition.wait()
                name, data = events.pop(0)
            if data is None:
                closed += 1
                continue
            self.chunk(envelope(0, {"event": {"data": {name: base64.b64encode(data).decode()}}}))
        returncode = popen.wait()
        if returncode < 0:
            end = {"exitCode": -1, "exited": False, "status": "signal: killed", "error": "signal: killed"}
        else:
            end = {"exitCode": returncode, "exited": True, "status": "exit status %d" % returncode}
            if returncode:
                end["error"] = "exit status %d" % returncode
        self.chunk(envelope(0, {"event": {"end": end}}))
        self.chunk(envelope(2, {}))
        self.chunk(b"")


def multipart_parts(content_type, body):
    """The (headers, content) of each part of a multipart/form-data body."""
    boundary = re.search(r'boundary="?([^";]+)"?', content_type).group(1).encode()
    parts = []
    for section in body.split(b"--" + boundary)[1:]:
        if section.startswith(b"--"):
            break
        head, _, content = section[2:].partition(b"\r\n\r\n")
        headers = {}
        for line in head.split(b"\r\n"):
            name, _, value = line.decode().partition(":")
            headers[name.strip().lower()] = value.strip()
        parts.append((headers, content[:-2] if content.endswith(b"\r\n") else content))
    return parts


def kill_group(popen):
    if popen.poll() is not None:
        return
    try:
        os.killpg(popen.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print("PORT %d" % server.server_address[1], flush=True)
    try:
        server.serve_forever()
    finally:
        for process in list(PROCESSES.values()):
            kill_group(process["popen"])


if __name__ == "__main__":
    main()
