"""A fake ``amp_sdk`` for the Haskell Amp sidecar tests.

It has the pinned SDK's protocol surface (``AmpOptions.model_fields`` and
``execute(prompt, options)``) and yields events with ``model_dump_json``.
The project name selects a script; ``options.project`` of ``block:<path>``
yields ``system/init`` then waits forever, touching ``<path>`` when the
cancellation reaches the generator.
"""

import asyncio
import json
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
