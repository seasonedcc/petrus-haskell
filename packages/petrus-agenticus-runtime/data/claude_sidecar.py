"""Host the optional Claude Agent SDK for the Haskell Claude A2 runtime.

The Haskell adapter owns admission, custody, the PreToolUse hook, the tool
handlers, the session-store mirror, publication and cleanup evidence. This
sidecar only does what upstream's ``claude.py`` does through the Python SDK:
``importlib.metadata.version("claude-agent-sdk")``, the probe's import and
``ClaudeAgentOptions`` signature, and ``_OfficialFactory.create`` /
``_OfficialClient``. Every hook, tool and session-store call the SDK makes
is forwarded to the Haskell process and answered there.

Usage: ``python -I -B claude_sidecar.py MODE [SYS_PATH ...]``

* ``version``: print ``{"version": "<installed>"}`` or ``{"version": null}``.
* ``probe``: print ``{"surface": {"file", "attributes", "parameters"}}`` or
  ``{"surface": null}`` when the import fails.
* ``serve``: host any number of SDK clients, one per channel, in one event
  loop, so the SDK is imported once per process (upstream imports it once
  into the host's interpreter). Every line, in both directions, is
  ``[channel, frame]``; ``[channel]`` ends a channel: from the Haskell side,
  the end of its input; from this side, its teardown is finished.

A channel's first frame is ``{"options", "server", "tools"}``, answered
``{"ready": true}`` or ``{"error": "start"}`` (which ends the channel). Its
later frames, in each direction:

* Haskell to sidecar: ``{"op": OP, "id": N, ...}`` with OP one of
  ``connect``, ``query`` (``prompt``), ``receive``, ``next``, ``interrupt``,
  ``disconnect``; ``{"op": "cancel", "target": N}``; and
  ``{"reply": K, "value": V}`` or ``{"reply": K, "error": E}`` answering a
  bridge call.
* Sidecar to Haskell: ``{"done": N, "value": V}`` or ``{"done": N, "error":
  "protocol"|"timeout"|"cancelled"|"failed", "code": C}``; and bridge calls
  ``{"call": K, "method": "hook"|"tool"|"append"|"load", ...}``.

``next`` answers ``null`` at the end of the response or one message reduced
to what upstream's ``_OfficialClient.receive_response`` keeps: its kind, its
``_message_size`` byte count and, for a result, the five fields the adapter
reads. Operations start eagerly, as upstream awaits them directly. The end
of a channel's input cancels its operations and disconnects its client (when
connected and not yet disconnected) before the channel ends.
"""

import asyncio
import importlib
import importlib.metadata
import inspect
import json
import os
import sys
from dataclasses import asdict, is_dataclass
from pathlib import Path

_REQUIRED = (
    "ClaudeSDKClient",
    "ClaudeAgentOptions",
    "ResultMessage",
    "MirrorErrorMessage",
    "UserMessage",
    "AssistantMessage",
    "SystemMessage",
    "StreamEvent",
    "RateLimitEvent",
    "SessionStore",
    "tool",
    "create_sdk_mcp_server",
    "HookMatcher",
)


class _ProtocolError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


# How long the end of input waits for the open channels' teardown.
_SHUTDOWN_GRACE = 10.0


def _emit(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _portable(value):
    try:
        json.dumps(value, allow_nan=False)
    except (TypeError, ValueError, RecursionError):
        return False
    return True


def _version():
    try:
        return importlib.metadata.version("claude-agent-sdk")
    except importlib.metadata.PackageNotFoundError:
        return None


def _probe():
    try:
        sdk = importlib.import_module("claude_agent_sdk")
    except Exception:
        return None
    attributes = [name for name in _REQUIRED if hasattr(sdk, name)]
    try:
        parameters = list(inspect.signature(sdk.ClaudeAgentOptions).parameters)
    except Exception:
        parameters = []
    source = getattr(sdk, "__file__", None)
    return {
        "file": source if isinstance(source, str) else None,
        "attributes": attributes,
        "parameters": parameters,
    }


def _message_size(message):
    if not is_dataclass(message) or isinstance(message, type):
        raise _ProtocolError("malformed-message")
    try:
        data = asdict(message)
        encoded = json.dumps(
            data,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
        ).encode()
    except (TypeError, ValueError):
        raise _ProtocolError("malformed-message") from None
    return len(encoded), data


def _describe(sdk, message):
    size, data = _message_size(message)
    if isinstance(message, sdk.ResultMessage):
        return {
            "kind": "result",
            "size": size,
            "subtype": data.get("subtype"),
            "is_error": data.get("is_error"),
            "session_id": data.get("session_id"),
            "terminal_reason": data.get("terminal_reason"),
            "result": data.get("result"),
        }
    if isinstance(message, sdk.MirrorErrorMessage):
        return {"kind": "mirror", "size": size}
    if isinstance(
        message,
        (sdk.UserMessage, sdk.AssistantMessage, sdk.SystemMessage, sdk.StreamEvent, sdk.RateLimitEvent),
    ):
        return {"kind": "event", "size": size}
    raise _ProtocolError("unknown-message")


class _Bridge:
    def __init__(self, emit):
        self.emit = emit
        self.counter = 0
        self.pending = {}
        self.closed = False

    async def call(self, method, **fields):
        if self.closed:
            raise RuntimeError("bridge-closed")
        self.counter += 1
        key = self.counter
        future = asyncio.get_running_loop().create_future()
        self.pending[key] = future
        try:
            self.emit({"call": key, "method": method, **fields})
            reply = await future
        finally:
            self.pending.pop(key, None)
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply.get("value")

    def resolve(self, frame):
        future = self.pending.get(frame.get("reply"))
        if future is not None and not future.done():
            future.set_result(frame)

    def close(self):
        self.closed = True
        for future in self.pending.values():
            if not future.done():
                future.set_result({"error": "closed"})


class _Store:
    """The SDK session store, answered by the Haskell mirror."""

    def __init__(self, bridge):
        self.bridge = bridge

    async def append(self, key, entries):
        key = key if _portable(key) else None
        entries = entries if type(entries) is list and _portable(entries) else None
        try:
            await self.bridge.call("append", key=key, entries=entries)
        except RuntimeError:
            raise RuntimeError("session-store-failed") from None

    async def load(self, key):
        return await self.bridge.call("load", key=key if _portable(key) else None)


def _discard_provider_stderr(_line):
    return None


_DENY = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "unsupported-tool",
    }
}
_UNSUPPORTED = {"content": [{"type": "text", "text": "unsupported-tool"}], "is_error": True}


def _create(sdk, request, bridge):
    async def hook(data, _tool_use_id, _context):
        if not isinstance(data, dict):
            return _DENY
        arguments = data.get("tool_input")
        if isinstance(arguments, dict) and any(type(key) is not str for key in arguments):
            return _DENY
        reduced = {name: data.get(name) for name in ("tool_name", "tool_use_id", "tool_input")}
        for name in ("agent_id", "agent_type"):
            if name in data:
                reduced[name] = True
        if not _portable(reduced):
            return _DENY
        try:
            value = await bridge.call("hook", data=reduced)
        except RuntimeError:
            return _DENY
        return value

    tools = []
    for index, spec in enumerate(request["tools"]):

        async def handler(arguments, *, _index=index):
            if (
                not isinstance(arguments, dict)
                or any(type(key) is not str for key in arguments)
                or not _portable(arguments)
            ):
                return _UNSUPPORTED
            value = await bridge.call("tool", index=_index, arguments=arguments)
            if not isinstance(value, dict):
                raise RuntimeError("tool-failed")
            return value

        tools.append(sdk.tool(spec["name"], spec["description"], spec["schema"])(handler))
    options = dict(request["options"])
    options["cwd"] = Path(options["cwd"])
    options["session_store"] = _Store(bridge)
    options["stderr"] = _discard_provider_stderr
    server = request["server"]
    options["mcp_servers"] = {server: sdk.create_sdk_mcp_server(server, tools=tools)}
    options["hooks"] = {"PreToolUse": [sdk.HookMatcher(matcher=None, hooks=[hook])]}
    return sdk.ClaudeSDKClient(options=sdk.ClaudeAgentOptions(**options))


async def _disconnect(raw):
    materialized = getattr(raw, "_materialized", None)
    config_dir = getattr(materialized, "config_dir", None)
    transport = getattr(raw, "_transport", None)
    process = getattr(transport, "_process", None)
    await raw.disconnect()
    if process is not None and getattr(process, "returncode", None) is None:
        raise _ProtocolError("client-cleanup-uncertain")
    if config_dir is not None:
        try:
            Path(config_dir).lstat()
        except FileNotFoundError:
            pass
        except OSError:
            raise _ProtocolError("private-cleanup-uncertain") from None
        else:
            raise _ProtocolError("private-cleanup-uncertain")


def _eager(loop, coroutine):
    try:
        return asyncio.Task(coroutine, loop=loop, eager_start=True)
    except TypeError:
        return loop.create_task(coroutine)


class _Client:
    """One channel: one official client and its operations."""

    def __init__(self, server, ident):
        self.server = server
        self.ident = ident
        self.bridge = _Bridge(self.emit)
        self.sdk = None
        self.raw = None
        self.stream = None
        self.connected = False
        self.disconnected = False
        self.tasks = {}
        self.ending = None

    def emit(self, frame):
        self.server.emit([self.ident, frame])

    def receive(self, frame):
        if self.ending is not None:
            return
        if frame is None:
            self.ending = _eager(self.server.loop, self.shutdown())
            return
        if self.raw is None:
            self.start(frame)
            return
        if not isinstance(frame, dict):
            return
        if "reply" in frame:
            self.bridge.resolve(frame)
            return
        op, ident = frame.get("op"), frame.get("id")
        if op == "cancel":
            task = self.tasks.get(frame.get("target"))
            if task is not None:
                task.cancel()
            return
        task = _eager(self.server.loop, self.run(op, frame))
        if task.done():
            self.finish(ident, task)
            return
        self.tasks[ident] = task
        task.add_done_callback(lambda done, _ident=ident: self.finish(_ident, done))

    def start(self, request):
        try:
            self.sdk = importlib.import_module("claude_agent_sdk")
            self.raw = _create(self.sdk, request, self.bridge)
        except Exception:
            self.emit({"error": "start"})
            self.server.end(self.ident)
            return
        self.emit({"ready": True})

    async def receive_response(self):
        async for message in self.raw.receive_response():
            yield _describe(self.sdk, message)

    async def run(self, op, frame):
        raw = self.raw
        if op == "connect":
            self.connected = True
            await raw.connect(None)
        elif op == "query":
            await raw.query(frame["prompt"], "default")
        elif op == "receive":
            self.stream = self.receive_response()
        elif op == "next":
            if self.stream is None:
                raise _ProtocolError("malformed-message")
            try:
                return await self.stream.__anext__()
            except StopAsyncIteration:
                return None
        elif op == "interrupt":
            await raw.interrupt()
        elif op == "disconnect":
            self.disconnected = True
            await _disconnect(raw)
        else:
            raise RuntimeError("unknown-operation")
        return None

    def finish(self, ident, task):
        self.tasks.pop(ident, None)
        if self.ending is not None:
            return
        if task.cancelled():
            self.emit({"done": ident, "error": "cancelled"})
            return
        failure = task.exception()
        if failure is None:
            self.emit({"done": ident, "value": task.result()})
        elif isinstance(failure, _ProtocolError):
            self.emit({"done": ident, "error": "protocol", "code": failure.code})
        elif isinstance(failure, TimeoutError):
            self.emit({"done": ident, "error": "timeout"})
        else:
            self.emit({"done": ident, "error": "failed"})

    async def shutdown(self):
        self.bridge.close()
        pending = list(self.tasks.values())
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        if self.raw is not None and self.connected and not self.disconnected:
            try:
                await self.raw.disconnect()
            except BaseException:
                pass
        self.server.end(self.ident)


class _Server:
    def __init__(self, loop):
        self.loop = loop
        self.clients = {}
        self.finished = set()
        self.buffer = bytearray()
        self.done = loop.create_future()
        self.out = sys.stdout.fileno()

    def emit(self, frame):
        data = (json.dumps(frame, separators=(",", ":")) + "\n").encode()
        view = memoryview(data)
        while view:
            written = os.write(self.out, view)
            view = view[written:]

    def end(self, ident):
        if ident not in self.finished:
            self.finished.add(ident)
            self.clients.pop(ident, None)
            self.emit([ident])

    def readable(self):
        try:
            data = os.read(0, 65536)
        except BlockingIOError:
            return
        if not data:
            self.loop.remove_reader(0)
            self.loop.create_task(self.shutdown())
            return
        self.buffer += data
        while True:
            index = self.buffer.find(b"\n")
            if index < 0:
                return
            line = bytes(self.buffer[:index])
            del self.buffer[: index + 1]
            try:
                frame = json.loads(line)
            except ValueError:
                continue
            if not isinstance(frame, list) or not frame or type(frame[0]) is not int:
                continue
            ident = frame[0]
            if ident in self.finished:
                continue
            client = self.clients.get(ident)
            if client is None:
                if len(frame) != 2:
                    continue
                client = self.clients[ident] = _Client(self, ident)
            client.receive(frame[1] if len(frame) == 2 else None)

    async def shutdown(self):
        for client in list(self.clients.values()):
            client.receive(None)
        pending = [client.ending for client in self.clients.values() if client.ending is not None]
        if pending:
            await asyncio.wait(pending, timeout=_SHUTDOWN_GRACE)
        self.done.set_result(None)


def _serve():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    os.set_blocking(0, False)
    server = _Server(loop)
    loop.add_reader(0, server.readable)
    loop.run_until_complete(server.done)
    try:
        if any(not task.done() for task in asyncio.all_tasks(loop)):
            raise TimeoutError
        loop.run_until_complete(asyncio.wait_for(loop.shutdown_asyncgens(), _SHUTDOWN_GRACE))
    except BaseException:
        # A teardown is stuck past the grace: leave without it rather than
        # outlive the process that started us.
        os._exit(0)
    loop.close()


def main():
    mode = sys.argv[1]
    sys.path[:0] = sys.argv[2:]
    if mode == "version":
        _emit({"version": _version()})
    elif mode == "probe":
        _emit({"surface": _probe()})
    elif mode == "serve":
        _serve()
    else:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
