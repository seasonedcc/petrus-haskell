"""Time the reference Codex, Claude and Amp host hot paths on the workload of ``bench/HostsBench.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_hosts.py

Each line prints the median per-operation time over 7 batches, after one
warm-up call. ``amp-stream-admit`` drives ``_read_stream`` by sending into
the coroutine directly: the stream never awaits, so no event loop is timed.
"""

from __future__ import annotations

import functools
import json
import statistics
import time
import types

from petrus.agenticus.runtime import _codex_gondolin_service as service
from petrus.agenticus.runtime import amp, claude, codex
from petrus.agenticus.thread.identity import EpisodeId, TurnId

THREAD = "11111111-1111-4111-8111-111111111111"


def codex_stream() -> bytes:
    events = [{"type": "thread.started", "thread_id": THREAD}, {"type": "turn.started"}]
    for i in range(1, 101):
        events.append({"type": "item.started", "item": {"id": f"r{i}", "type": "reasoning", "text": "thinking"}})
        events.append(
            {"type": "item.completed", "item": {"id": f"r{i}", "type": "reasoning", "text": "thinking about it"}}
        )
    events += [
        {"type": "item.completed", "item": {"id": "m1", "type": "agent_message", "text": "first \x1b[31manswer\x1b[0m"}},
        {"type": "item.completed", "item": {"id": "m2", "type": "agent_message", "text": "final answer \xe9"}},
        {"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 20}},
    ]
    return b"\n".join(json.dumps(event).encode() for event in events)


TERMINAL = {
    "ok": True,
    "result": {
        "version": 1,
        "operation_id": "operation-bench",
        "episode_id": "episode-bench",
        "turn_id": "turn-bench",
        "outcome": "completed",
        "accepted_appends": 1,
        "termination_code": "turn-completed",
        "output_reference": "codex-turn-operation-bench",
        "continuation_reference": "codex-continuation-operation-bench",
        "cleanup": {"disposition": "clean", "code": "client-closed"},
    },
}

TRANSCRIPT = [
    {
        "uuid": f"entry-{i}",
        "type": "assistant" if i % 2 == 0 else "user",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "hello \xe9 world"}]},
        "parentUuid": None if i == 0 else f"entry-{i - 1}",
    }
    for i in range(200)
]

TOOL_INPUT = {"path": "src/Main.hs", "pattern": "TODO", "limit": 50, "flags": ["i", "n"]}
RESULT_TEXT = "\x1b[32mok\x1b[0m line \xe9\t with text\n" * 128
AMP_THREAD = "T-0123abcd-4567-89ef"


class Event(dict):
    """An SDK event: a mapping whose compact JSON is its encoded size."""

    def model_dump_json(self) -> str:
        return json.dumps(self, separators=(",", ":"))


def amp_events() -> list[list[tuple[str, object]]]:
    events = [[("type", "system"), ("subtype", "init"), ("session_id", AMP_THREAD)]]
    events += [
        [("type", "assistant"), ("session_id", AMP_THREAD), ("message", {"content": f"step {i}"})] for i in range(1, 201)
    ]
    events.append(
        [("type", "result"), ("subtype", "success"), ("is_error", False), ("session_id", AMP_THREAD), ("result", "done")]
    )
    return events


def amp_reader():
    config = amp.AmpRuntimeConfig(project="project")
    stub = types.SimpleNamespace(_config=config, _continuation_thread_id=None)
    operation = amp._AmpRuntimeOperation
    for name in ("_admit_initial", "_admit_later", "_admit_terminal"):
        setattr(stub, name, functools.partial(getattr(operation, name), stub))

    def admit(raw_events):
        async def source():
            for members in raw_events:
                yield Event(members)

        coroutine = operation._read_stream(stub, source())
        try:
            coroutine.send(None)
        except StopIteration as stop:
            candidate = stop.value
            return candidate.termination_code, candidate.final_text
        raise AssertionError("stream awaited")

    return admit


def timed(label: str, operation, batches: int = 7, per_batch: int = 200) -> None:
    operation()
    samples = []
    for _ in range(batches):
        start = time.perf_counter()
        for _ in range(per_batch):
            operation()
        samples.append((time.perf_counter() - start) / per_batch)
    median = statistics.median(samples)
    unit, scale = ("ms", 1e3) if median >= 1e-3 else ("µs", 1e6) if median >= 1e-6 else ("ns", 1e9)
    print(f"{label:<28} {median * scale:8.3f} {unit}")


def main() -> None:
    stream = codex_stream()
    helper = (
        b'{"ok": true, "rollout_path": "sessions/2026/08/03/rollout-2026-08-03T00-00-00-' + THREAD.encode() + b'.jsonl"}\n'
    )
    frame = service._json_bytes(TERMINAL) + b"\n"
    episode, turn = EpisodeId("episode-bench"), TurnId("turn-bench")
    encoded = claude._encode_transcript(TRANSCRIPT, 10_000, 4_000_000)
    events = amp_events()
    admit = amp_reader()

    timed("codex-jsonl-parse", lambda: codex._parse_jsonl(stream, 0))
    timed("codex-helper-parse", lambda: codex._parse_helper(helper, collect=True), per_batch=20000)
    timed("codex-terminal-encode", lambda: service._json_bytes(TERMINAL), per_batch=20000)
    timed(
        "codex-terminal-parse",
        lambda: service._parse_terminal(frame, operation_id="operation-bench", episode_id=episode, turn_id=turn),
        per_batch=5000,
    )
    timed("claude-transcript-encode", lambda: claude._encode_transcript(TRANSCRIPT, 10_000, 4_000_000))
    timed("claude-transcript-decode", lambda: claude._decode_transcript(encoded, 10_000, 4_000_000))
    timed("claude-canonical-input", lambda: claude._canonical_input(TOOL_INPUT), per_batch=20000)
    timed("claude-sanitize", lambda: claude._sanitize(RESULT_TEXT, 1_000_000), per_batch=2000)
    timed("amp-stream-admit", lambda: admit(events))
    timed("amp-final-text", lambda: amp._safe_final_text(RESULT_TEXT, 1_000_000), per_batch=2000)


if __name__ == "__main__":
    main()
