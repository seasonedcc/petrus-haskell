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
* ``client``: read ``{"options", "server", "tools"}``, answer
  ``{"ready": true}`` or ``{"error": "start"}``, then serve operations.

Client frames, one JSON object per line in each direction:

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
reads. End of stdin cancels every operation and disconnects the client.
"""

import asyncio
import importlib
import importlib.metadata
import inspect
import json
import sys
import threading
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
    def __init__(self):
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
            _emit({"call": key, "method": method, **fields})
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


def _reader(loop, queue):
    try:
        for line in sys.stdin:
            try:
                frame = json.loads(line)
            except ValueError:
                continue
            loop.call_soon_threadsafe(queue.put_nowait, frame)
        loop.call_soon_threadsafe(queue.put_nowait, None)
    except RuntimeError:
        pass


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


async def _serve(request):
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    threading.Thread(target=_reader, args=(loop, queue), daemon=True).start()
    bridge = _Bridge()
    try:
        sdk = importlib.import_module("claude_agent_sdk")
        raw = _create(sdk, request, bridge)
    except Exception:
        _emit({"error": "start"})
        return
    _emit({"ready": True})
    state = {"stream": None, "connected": False, "disconnected": False}
    tasks = {}

    async def receive():
        async for message in raw.receive_response():
            yield _describe(sdk, message)

    async def run(op, frame):
        if op == "connect":
            state["connected"] = True
            await raw.connect(None)
        elif op == "query":
            await raw.query(frame["prompt"], "default")
        elif op == "receive":
            state["stream"] = receive()
        elif op == "next":
            if state["stream"] is None:
                raise _ProtocolError("malformed-message")
            try:
                return await state["stream"].__anext__()
            except StopAsyncIteration:
                return None
        elif op == "interrupt":
            await raw.interrupt()
        elif op == "disconnect":
            state["disconnected"] = True
            await _disconnect(raw)
        else:
            raise RuntimeError("unknown-operation")
        return None

    def finish(ident, task):
        tasks.pop(ident, None)
        if task.cancelled():
            _emit({"done": ident, "error": "cancelled"})
            return
        failure = task.exception()
        if failure is None:
            _emit({"done": ident, "value": task.result()})
        elif isinstance(failure, _ProtocolError):
            _emit({"done": ident, "error": "protocol", "code": failure.code})
        elif isinstance(failure, TimeoutError):
            _emit({"done": ident, "error": "timeout"})
        else:
            _emit({"done": ident, "error": "failed"})

    while True:
        frame = await queue.get()
        if frame is None:
            break
        if not isinstance(frame, dict):
            continue
        if "reply" in frame:
            bridge.resolve(frame)
            continue
        op, ident = frame.get("op"), frame.get("id")
        if op == "cancel":
            task = tasks.get(frame.get("target"))
            if task is not None:
                task.cancel()
            continue
        task = asyncio.ensure_future(run(op, frame))
        tasks[ident] = task
        task.add_done_callback(lambda done, _ident=ident: finish(_ident, done))
    bridge.close()
    for task in list(tasks.values()):
        task.cancel()
    if state["connected"] and not state["disconnected"]:
        try:
            await raw.disconnect()
        except BaseException:
            pass


def main():
    mode = sys.argv[1]
    sys.path[:0] = sys.argv[2:]
    if mode == "version":
        _emit({"version": _version()})
    elif mode == "probe":
        _emit({"surface": _probe()})
    elif mode == "client":
        line = sys.stdin.readline()
        try:
            request = json.loads(line)
        except ValueError:
            _emit({"error": "start"})
            return
        asyncio.run(_serve(request))
    else:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
