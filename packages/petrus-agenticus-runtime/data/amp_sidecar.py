"""Host the optional Amp SDK for the Haskell Amp A1 runtime.

The Haskell adapter owns admission, publication and cleanup evidence. This
sidecar only performs the three things upstream's ``amp.py`` does through the
Python SDK: ``importlib.metadata.version("amp-sdk")``, the ``AmpOptions`` and
``execute`` protocol check, and ``execute(prompt, AmpOptions(**options))``.

Usage: ``python -I -B amp_sidecar.py MODE [SYS_PATH ...]``

* ``version``: print ``{"version": "<installed>"}`` or ``{"version": null}``.
* ``protocol``: print ``{"ready": true|false}``.
* ``execute``: read ``{"prompt": ..., "options": {...}}`` from stdin, answer
  ``{"started": true}`` or ``{"error": "start"}``, then serve the commands
  ``"next"``, ``"abort"`` and ``"close"`` one JSON line at a time.

Every event is reduced to exactly what upstream's adapter reads from it: the
``_event_size`` byte count (``null`` when it is malformed) and the five
``_event_value`` attributes, with values that are not JSON scalars replaced
by an opaque ``{"opaque": type, "hashable": bool}`` marker. End of stdin
aborts and closes the stream.
"""

import asyncio
import importlib
import importlib.metadata
import inspect
import json
import sys
import threading
from collections.abc import Mapping

_NAMES = ("type", "subtype", "session_id", "is_error", "result")


def _emit(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _scalar(value):
    # Subclasses (a StrEnum event type, say) compare like their base value
    # upstream, so they cross as that value.
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, str):
        return str(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return float(value)
    # Anything else equals no string or boolean the admission compares
    # against; whether it is hashable decides between upstream's protocol
    # code and the TypeError of ``value in {...}``.
    return {"opaque": type(value).__name__, "hashable": type(value).__hash__ is not None}


def _event_value(event, name):
    if isinstance(event, Mapping):
        return event.get(name, None)
    return getattr(event, name, None)


def _event_size(event):
    serializer = getattr(event, "model_dump_json", None)
    if callable(serializer):
        value = serializer()
        if not isinstance(value, str):
            return None
        return len(value.encode())
    size = getattr(event, "encoded_size", None)
    if type(size) is not int or size < 0:
        return None
    return size


def _describe(event):
    try:
        size = _event_size(event)
    except Exception:
        size = None
    values = {}
    for name in _NAMES:
        try:
            values[name] = _scalar(_event_value(event, name))
        except Exception:
            values[name] = {"opaque": "error", "hashable": True}
    return {"event": {"size": size, "values": values}}


def _version():
    try:
        return importlib.metadata.version("amp-sdk")
    except importlib.metadata.PackageNotFoundError:
        return None


def _protocol():
    try:
        sdk = importlib.import_module("amp_sdk")
        amp_options = getattr(sdk, "AmpOptions")
        fields = getattr(amp_options, "model_fields", {})
        execute = getattr(sdk, "execute")
        return {"executor", "project", "continue_thread"}.issubset(fields) and "options" in inspect.signature(
            execute
        ).parameters
    except Exception:
        return False


def _commands(loop, queue):
    try:
        for line in sys.stdin:
            try:
                command = json.loads(line)
            except ValueError:
                command = "close"
            loop.call_soon_threadsafe(queue.put_nowait, command)
        loop.call_soon_threadsafe(queue.put_nowait, None)
    except RuntimeError:
        pass


async def _serve(request):
    try:
        sdk = importlib.import_module("amp_sdk")
        amp_options = getattr(sdk, "AmpOptions")(**dict(request["options"]))
        stream = getattr(sdk, "execute")(request["prompt"], amp_options)
    except Exception:
        _emit({"error": "start"})
        return
    _emit({"started": True})
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    threading.Thread(target=_commands, args=(loop, queue), daemon=True).start()
    pending = None
    aborted = False
    backlog = []
    while True:
        command = backlog.pop(0) if backlog else await queue.get()
        if command == "next" and pending is None:
            pending = asyncio.ensure_future(stream.__anext__())
            waiter = asyncio.ensure_future(queue.get())
            done, _ = await asyncio.wait({pending, waiter}, return_when=asyncio.FIRST_COMPLETED)
            if pending in done:
                if waiter.done():
                    backlog.append(waiter.result())
                else:
                    waiter.cancel()
                try:
                    event = pending.result()
                except StopAsyncIteration:
                    _emit({"end": True})
                except TimeoutError:
                    _emit({"error": "timeout"})
                except BaseException:
                    _emit({"error": "failed"})
                else:
                    _emit(_describe(event))
                pending = None
                continue
            command = waiter.result()
        if command == "abort" or command is None:
            if pending is not None:
                pending.cancel()
                try:
                    await pending
                except BaseException:
                    pass
                pending = None
            if not aborted:
                aborted = True
                athrow = getattr(stream, "athrow", None)
                if callable(athrow):
                    try:
                        await athrow(asyncio.CancelledError())
                    except BaseException:
                        pass
            if command == "abort":
                _emit({"aborted": True})
                continue
        if command == "close" or command is None:
            if pending is not None:
                pending.cancel()
                try:
                    await pending
                except BaseException:
                    pass
            aclose = getattr(stream, "aclose", None)
            if callable(aclose):
                try:
                    await aclose()
                except BaseException:
                    pass
            _emit({"closed": True})
            return


def main():
    mode = sys.argv[1]
    sys.path[:0] = sys.argv[2:]
    if mode == "version":
        _emit({"version": _version()})
    elif mode == "protocol":
        _emit({"ready": _protocol()})
    elif mode == "execute":
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
