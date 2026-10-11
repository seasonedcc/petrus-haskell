"""A fake ``amp_sdk`` for the Haskell Amp sidecar tests.

It has the pinned SDK's protocol surface (``AmpOptions.model_fields`` and
``execute(prompt, options)``) and yields events with ``model_dump_json``.
The project name selects a script; ``options.project`` of ``block:<path>``
yields ``system/init`` then waits forever, touching ``<path>`` when the
cancellation reaches the generator, and ``raise:<scenario>`` yields one of
the ``SCENARIOS`` below, whose events (or the stream itself) raise where the
adapter reads them.
"""

import asyncio
import json
from collections.abc import Mapping
from pathlib import Path

THREAD_ID = "T-11111111-1111-1111-1111-111111111111"


class AmpOptions:
    model_fields = {
        "executor": None,
        "project": None,
        "mode": None,
        "visibility": None,
        "no_archive_after_execute": None,
        "continue_thread": None,
    }

    def __init__(self, **values):
        unknown = set(values) - set(self.model_fields)
        if unknown:
            raise TypeError(f"unknown options {sorted(unknown)}")
        self.values = values


class Event:
    def __init__(self, **values):
        self.__dict__.update(values)
        self._values = values

    def model_dump_json(self):
        return json.dumps(self._values, separators=(",", ":"))


async def execute(prompt, options):
    project = options.values["project"]
    if project.startswith("raise:"):
        async for event in _scenario(project.removeprefix("raise:")):
            yield event
        return
    thread = options.values.get("continue_thread", THREAD_ID)
    yield Event(type="system", subtype="init", session_id=thread)
    if project.startswith("block:"):
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            Path(project.removeprefix("block:")).touch()
            raise
    echoed = json.dumps({"prompt": prompt, "options": options.values}, sort_keys=True)
    yield Event(type="assistant", session_id=thread, message={"content": [{"type": "text", "text": echoed}]})
    yield Event(type="result", subtype="success", session_id=thread, is_error=False, result=echoed)


def _exception(kind):
    return {
        "failed": RuntimeError("boom"),
        "timeout": TimeoutError(),
        "cancelled": asyncio.CancelledError(),
        "attribute": AttributeError("absent"),
        "key": KeyError("absent"),
    }[kind]


class RaisingEvent:
    """An event whose listed attributes (and ``size``: ``model_dump_json``)
    raise the listed exception kinds when read."""

    def __init__(self, raising, **values):
        object.__setattr__(self, "_raising", dict(raising))
        object.__setattr__(self, "_values", values)

    def __getattr__(self, name):
        raising = object.__getattribute__(self, "_raising")
        if name in raising:
            raise _exception(raising[name])
        values = object.__getattribute__(self, "_values")
        if name in values:
            return values[name]
        raise AttributeError(name)

    def model_dump_json(self):
        raising = object.__getattribute__(self, "_raising")
        if "size" in raising:
            raise _exception(raising["size"])
        return json.dumps(object.__getattribute__(self, "_values"), separators=(",", ":"))


class RaisingMapping(Mapping):
    """A mapping event whose ``get`` raises for the listed keys."""

    def __init__(self, raising, **values):
        self._raising = dict(raising)
        self._values = values

    def __getitem__(self, key):
        return self._values[key]

    def __iter__(self):
        return iter(self._values)

    def __len__(self):
        return len(self._values)

    def get(self, key, default=None):
        if key in self._raising:
            raise _exception(self._raising[key])
        return self._values.get(key, default)

    def model_dump_json(self):
        return json.dumps(self._values, separators=(",", ":"))


def _init(**raising):
    return RaisingEvent(raising, type="system", subtype="init", session_id=THREAD_ID)


def _success(**raising):
    return RaisingEvent(raising, type="result", subtype="success", session_id=THREAD_ID, is_error=False, result="done")


_ASSISTANT = dict(type="assistant", session_id=THREAD_ID)

# Each scenario: the events, then what the stream raises after them (or None).
SCENARIOS = {
    "size-failed": ([_init(size="failed")], None),
    "size-timeout": ([_init(size="timeout")], None),
    "size-cancelled": ([_init(size="cancelled")], None),
    "init-type-short-circuit": ([RaisingEvent({"subtype": "failed"}, type="assistant", session_id=THREAD_ID)], None),
    "init-subtype-failed": ([RaisingEvent({"subtype": "failed"}, type="system", session_id=THREAD_ID)], None),
    "init-subtype-attribute": ([RaisingEvent({"subtype": "attribute"}, type="system", session_id=THREAD_ID)], None),
    "init-session-timeout": ([_init(session_id="timeout")], None),
    "later-session-cancelled": ([_init(), RaisingEvent({"session_id": "cancelled"}, type="assistant")], None),
    "later-type-after-mismatch": ([_init(), RaisingEvent({"type": "failed"}, session_id="T-other")], None),
    "later-type-failed": ([_init(), RaisingEvent({"type": "failed"}, session_id=THREAD_ID)], None),
    "later-size-timeout": ([_init(), RaisingEvent({"size": "timeout"}, **_ASSISTANT)], None),
    "terminal-is-error-failed": ([_init(), _success(is_error="failed")], None),
    "terminal-subtype-cancelled": ([_init(), _success(subtype="cancelled")], None),
    "terminal-result-cancelled": ([_init(), _success(result="cancelled")], None),
    "terminal-result-short-circuit": (
        [
            _init(),
            RaisingEvent(
                {"result": "failed"},
                type="result",
                subtype="error_max_turns",
                session_id=THREAD_ID,
                is_error=True,
            ),
        ],
        None,
    ),
    "after-terminal": ([_init(), _success(), RaisingEvent({"size": "failed"}, **_ASSISTANT)], None),
    "mapping-get-key": ([_init(), RaisingMapping({"type": "key"}, **_ASSISTANT)], None),
    "pull-failed": ([_init()], "failed"),
    "pull-timeout": ([_init()], "timeout"),
    "pull-cancelled": ([_init()], "cancelled"),
    "pull-after-terminal": ([_init(), _success()], "failed"),
    "clean": ([_init(), RaisingEvent({}, **_ASSISTANT), _success()], None),
}


async def _scenario(name):
    events, failure = SCENARIOS[name]
    for event in events:
        yield event
    if failure is not None:
        raise _exception(failure)
