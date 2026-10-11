"""Host the optional Amp SDK for the Haskell Amp A1 runtime.

The Haskell adapter owns admission, publication and cleanup evidence. This
sidecar only performs the three things upstream's ``amp.py`` does through the
Python SDK: ``importlib.metadata.version("amp-sdk")``, the ``AmpOptions`` and
``execute`` protocol check, and ``execute(prompt, AmpOptions(**options))``.

Usage: ``python -I -B amp_sidecar.py MODE [SYS_PATH ...]``

* ``version``: print ``{"version": "<installed>"}`` or ``{"version": null}``.
* ``protocol``: print ``{"ready": true|false}``.
* ``serve``: host any number of SDK streams, one per channel, in one event
  loop, so the SDK is imported once per process (upstream imports it once
  into the host's interpreter). Every line, in both directions, is
  ``[channel, frame]``; ``[channel]`` ends a channel: from the Haskell side,
  the end of its input; from this side, its teardown is finished.

A channel's first frame is ``{"prompt": ..., "options": {...}}``, answered
``{"started": true}`` or ``{"error": "start"}`` (which ends the channel).
Then it takes the commands ``"next"``, ``"abort"`` and ``"close"``:

* ``"next"`` pulls one event (``stream.__anext__()``), started eagerly, as
  upstream awaits it directly, and answers the event, ``{"end": true}``, or
  ``{"error": "timeout"|"cancelled"|"failed"}``. When the stream is a native
  async generator that has now stopped, the answer also carries
  ``"finished": true`` and the channel ends: ``athrow`` and ``aclose`` on a
  closed generator run no SDK code, so its finalizers are not needed.
* ``"abort"`` cancels a pending pull and injects ``CancelledError`` into the
  SDK generator once (upstream's ``athrow``), answering ``{"aborted": true}``.
* ``"close"`` cancels a pending pull, calls ``aclose()``, answers
  ``{"closed": true}`` and ends the channel. The end of a channel's input
  aborts and closes it first.

Every event is reduced to exactly what upstream's adapter reads from it: the
``_event_size`` byte count (``null`` when it is malformed) and the five
``_event_value`` attributes, with values that are not JSON scalars replaced
by an opaque ``{"opaque": type, "hashable": bool}`` marker. When computing
the size, or reading one attribute, raises (where upstream's ``_run`` would
see the exception), that part crosses as ``{"raised": kind}``: ``timeout``
for a ``TimeoutError``, ``cancelled`` for a ``CancelledError``, ``failed``
for anything else.
"""

import asyncio
import importlib
import importlib.metadata
import inspect
import json
import os
import sys
from collections.abc import Mapping

_NAMES = ("type", "subtype", "session_id", "is_error", "result")


# How long the end of input waits for the open channels' teardown.
_SHUTDOWN_GRACE = 10.0


def _emit(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _raised(error):
    if isinstance(error, asyncio.CancelledError):
        return {"raised": "cancelled"}
    if isinstance(error, TimeoutError):
        return {"raised": "timeout"}
    return {"raised": "failed"}


def _scalar(value):
    # Subclasses (a StrEnum event type, say) compare like their base value
    # upstream, so they cross as that value.
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, str):
        return str.__str__(value)
    if isinstance(value, int):
        return int.__int__(value)
    if isinstance(value, float):
        return float.__float__(value)
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
    except BaseException as error:
        size = _raised(error)
    values = {}
    for name in _NAMES:
        try:
            values[name] = _scalar(_event_value(event, name))
        except BaseException as error:
            values[name] = _raised(error)
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


def _eager(loop, coroutine):
    try:
        return asyncio.Task(coroutine, loop=loop, eager_start=True)
    except TypeError:
        return loop.create_task(coroutine)


class _Stream:
    """One channel: one SDK stream and its pending pull."""

    def __init__(self, server, ident):
        self.server = server
        self.ident = ident
        self.stream = None
        self.pending = None
        self.aborted = False
        self.finalizing = None

    def emit(self, frame):
        self.server.emit([self.ident, frame])

    def receive(self, frame):
        if self.stream is None:
            self.start(frame)
        elif self.finalizing is not None:
            # Commands after a finalizer run in order behind it.
            self.finalizing = _eager(self.server.loop, self.after(self.finalizing, frame))
        elif frame == "next":
            if self.pending is None:
                self.pull()
        elif frame in ("abort", "close", None):
            self.finalizing = _eager(self.server.loop, self.finalize(frame))

    def start(self, request):
        try:
            sdk = importlib.import_module("amp_sdk")
            amp_options = getattr(sdk, "AmpOptions")(**dict(request["options"]))
            self.stream = getattr(sdk, "execute")(request["prompt"], amp_options)
        except BaseException:
            self.emit({"error": "start"})
            self.server.end(self.ident)
            return
        self.emit({"started": True})

    def pull(self):
        task = _eager(self.server.loop, self.stream.__anext__())
        self.pending = task
        if task.done():
            self.pulled(task)
        else:
            task.add_done_callback(self.pulled)

    def pulled(self, task):
        if self.pending is not task:
            return
        self.pending = None
        if task.cancelled():
            # Only a finalizer cancels a pull, and it clears ``pending``
            # first, so this CancelledError came from the SDK itself.
            self.finish({"error": "cancelled"})
            return
        error = task.exception()
        if error is None:
            self.emit(_describe(task.result()))
        elif isinstance(error, StopAsyncIteration):
            self.finish({"end": True})
        elif isinstance(error, TimeoutError):
            self.finish({"error": "timeout"})
        else:
            self.finish({"error": "failed"})

    def finish(self, frame):
        # A native async generator that has stopped (returned or raised) is
        # closed: ``athrow`` and ``aclose`` on it run no SDK code. Its
        # finalizers are then no-ops, so the channel ends with this frame.
        stream = self.stream
        if inspect.isasyncgen(stream) and inspect.getasyncgenstate(stream) == inspect.AGEN_CLOSED:
            frame["finished"] = True
            self.emit(frame)
            self.server.end(self.ident)
        else:
            self.emit(frame)

    async def after(self, previous, frame):
        try:
            await previous
        except BaseException:
            pass
        if frame in ("abort", "close", None):
            await self.finalize(frame)

    async def cancel_pending(self):
        pending, self.pending = self.pending, None
        if pending is not None:
            pending.cancel()
            try:
                await pending
            except BaseException:
                pass

    async def finalize(self, command):
        if self.server.ended(self.ident):
            return
        await self.cancel_pending()
        if command in ("abort", None) and not self.aborted:
            self.aborted = True
            athrow = getattr(self.stream, "athrow", None)
            if callable(athrow):
                try:
                    await athrow(asyncio.CancelledError())
                except BaseException:
                    pass
        if command == "abort":
            self.emit({"aborted": True})
            return
        aclose = getattr(self.stream, "aclose", None)
        if callable(aclose):
            try:
                await aclose()
            except BaseException:
                pass
        self.emit({"closed": True})
        self.server.end(self.ident)


class _Server:
    def __init__(self, loop):
        self.loop = loop
        self.streams = {}
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

    def ended(self, ident):
        return ident in self.finished

    def end(self, ident):
        if ident not in self.finished:
            self.finished.add(ident)
            self.streams.pop(ident, None)
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
            stream = self.streams.get(ident)
            if stream is None:
                if len(frame) != 2:
                    continue
                stream = self.streams[ident] = _Stream(self, ident)
            stream.receive(frame[1] if len(frame) == 2 else None)

    async def shutdown(self):
        for stream in list(self.streams.values()):
            stream.receive(None)
        pending = [stream.finalizing for stream in self.streams.values() if stream.finalizing is not None]
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
    elif mode == "protocol":
        _emit({"ready": _protocol()})
    elif mode == "serve":
        _serve()
    else:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
