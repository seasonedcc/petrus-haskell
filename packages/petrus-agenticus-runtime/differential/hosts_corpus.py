"""Generate the Codex, Claude and Amp host differential corpus from the reference.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python -I -B ../../packages/petrus-agenticus-runtime/differential/hosts_corpus.py \
        ../../packages/petrus-agenticus-runtime/differential/hosts_corpus.json

Every case records the reference's value (``ok``) or its ``{class, message}``
refusal (``error``). Byte strings are lowercase hex. Seed 4242 drives the
random cases; the hand-written edge cases come first in each section.

Sections:

* ``codex``: ``_text``, ``_uuid``, ``_rollout_path``, ``_final_text``,
  ``CodexContinuationPayloadV1``, ``_parse_helper``, ``_parse_jsonl``,
  ``_json_bytes`` and ``_parse_terminal`` (the A3 runtime service's wire).
* ``claude``: ``_text``, ``_uuid``, ``_encode_transcript``,
  ``_decode_transcript``, ``_canonical_input``, ``_sanitize`` and
  ``ClaudeContinuationPayloadV1``.
* ``amp``: ``_bounded_text``, ``_thread_id``, ``_safe_final_text``,
  ``AmpContinuationPayloadV1.from_data``/``to_data``, ``_execution_options``
  and ``_read_stream`` over whole event streams. A stream refusal is the
  settlement code ``_run`` would return: a ``RuntimeProtocolError`` keeps its
  code and any other exception becomes ``client-failed``.
"""

from __future__ import annotations

import asyncio
import functools
import json
import random
import sys
import types
from pathlib import Path

from petrus.agenticus.runtime import _codex_gondolin_service as service
from petrus.agenticus.runtime import amp, claude, codex
from petrus.agenticus.runtime.operation import RuntimeProtocolError
from petrus.agenticus.thread.identity import EpisodeId, TurnId

SEED = 4242
rng = random.Random(SEED)

THREAD = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
ROLLOUT = f"sessions/2026/08/03/rollout-2026-08-03T00-00-00-{THREAD}.jsonl"

PIECES = [
    "a",
    "Z",
    "0",
    "9",
    " ",
    "\t",
    "\n",
    "\r",
    "\x00",
    "\x07",
    "\x1b",
    "\x1b[31m",
    "\x1b[0m",
    "\x1b]0;title\x07",
    "\x1b]8;;x\x1b\\",
    "\x7f",
    "\x85",
    "\x9f",
    "\xa0",
    "é",
    "€",
    "😀",
    "-",
    "/",
    ".",
    "_",
    "T-",
    "�",
    " ",
]


def refusal(error: BaseException) -> dict[str, object]:
    return {"class": type(error).__name__, "message": str(error)}


def attempt(action) -> dict[str, object]:
    try:
        return {"ok": action()}
    except Exception as error:  # noqa: BLE001 - every refusal is corpus data
        return {"error": refusal(error)}


def text(low: int = 0, high: int = 12) -> str:
    return "".join(rng.choice(PIECES) for _ in range(rng.randint(low, high)))


def mutate(value: str) -> str:
    if not value:
        return text(1, 3)
    i = rng.randrange(len(value))
    choice = rng.randrange(4)
    if choice == 0:
        return value[:i] + value[i + 1 :]
    if choice == 1:
        return value[:i] + rng.choice(PIECES) + value[i:]
    if choice == 2:
        return value[:i] + rng.choice("0123456789abcdefABCDEF-") + value[i + 1 :]
    return value.upper() if rng.random() < 0.5 else " " + value


def uuid_like() -> str:
    hexes = "0123456789abcdef"
    shape = [8, 4, 4, 4, 12]
    parts = ["".join(rng.choice(hexes) for _ in range(n)) for n in shape]
    if rng.random() < 0.7:
        parts[2] = rng.choice("12345") + parts[2][1:]
        parts[3] = rng.choice("89ab") + parts[3][1:]
    value = "-".join(parts)
    return mutate(value) if rng.random() < 0.4 else value


def hexed(value: bytes) -> str:
    return value.hex()


def json_value(depth: int = 0):
    roll = rng.random()
    if depth > 3 or roll < 0.45:
        return rng.choice(
            [
                None,
                True,
                False,
                0,
                1,
                -7,
                2**53 + 1,
                1.5,
                -0.25,
                1e20,
                text(0, 6),
                "",
                "x",
                "é€😀",
            ]
        )
    if roll < 0.7:
        return [json_value(depth + 1) for _ in range(rng.randint(0, 3))]
    return {text(0, 4): json_value(depth + 1) for _ in range(rng.randint(0, 3))}


# ---------------------------------------------------------------------------
# Codex


def codex_section() -> dict[str, object]:
    texts = [("Codex value", v, m) for v, m in [("x", 256), ("", 256), (" x", 256), ("x ", 256), ("a\x1fb", 256), ("é" * 128, 256), ("é" * 129, 256), ("\x7f", 256)]]
    texts += [("Codex value", text(0, 10), rng.choice([4, 16, 256])) for _ in range(300)]
    uuids = [THREAD, THREAD.upper(), "{" + THREAD + "}", THREAD.replace("-", ""), "urn:uuid:" + THREAD, "", " " + THREAD, "00000000-0000-0000-0000-000000000000"]
    uuids += [uuid_like() for _ in range(300)]
    paths = [
        (ROLLOUT, THREAD),
        (ROLLOUT, OTHER),
        ("../" + ROLLOUT, THREAD),
        (ROLLOUT.replace("/08/", "/13/"), THREAD),
        (ROLLOUT.replace("/03/", "/32/"), THREAD),
        (ROLLOUT.replace("rollout-2026", "rollout-a b"), THREAD),
        ("/" + ROLLOUT, THREAD),
        (ROLLOUT + "\n", THREAD),
    ]
    paths += [(mutate(ROLLOUT), THREAD) for _ in range(200)]
    finals = ["plain", "\x1b[31mred\x1b[0m", "a\x00b", "\x85\x9f\xa0", "\x1b]0;t\x07x", "\x1b]8;;u\x1b\\y", ""]
    finals += [text(0, 20) for _ in range(300)]
    # Oversized messages are recorded as ``{"repeat": piece, "times": n}``.
    oversized = [("x", 1_000_001), ("\x1b[0m", 300_000), ("é", 500_001)]

    payloads = [(THREAD, ROLLOUT, b"r"), (THREAD, ROLLOUT, b""), (OTHER, ROLLOUT, b"r"), (THREAD.upper(), ROLLOUT, b"r")]
    payloads += [(uuid_like() if rng.random() < 0.3 else THREAD, mutate(ROLLOUT) if rng.random() < 0.5 else ROLLOUT, rng.choice([b"r", b"", b"\x00\xff"])) for _ in range(100)]

    def payload(thread, path, rollout):
        value = codex.CodexContinuationPayloadV1(thread, path, rollout)
        return {"thread_id": value.thread_id, "rollout_path": value.rollout_path, "rollout": hexed(value.rollout)}

    helper_stdouts = [
        (b'{"ok":true}', False),
        (b'{"ok":true}', True),
        (b'{"ok":true,"rollout_path":"x"}', True),
        (b'{"ok":true,"rollout_path":null}', True),
        (b'{"ok":true,"rollout_path":7}', True),
        (b'{"ok":1}', False),
        (b'{"ok":true,"ok":true}', False),
        (b' {"ok":true}\n', False),
        (b"\xef\xbb\xbf{\"ok\":true}", False),
        (b"\xff", False),
        (b"[]", False),
        (b'{"ok":true,"x":' + b"1" * 600 + b"}", False),
        (b'{"ok":NaN}', False),
        (b"", False),
    ]
    for _ in range(200):
        members = {}
        if rng.random() < 0.9:
            members["ok"] = rng.choice([True, True, True, False, 1, None])
        if rng.random() < 0.5:
            members["rollout_path"] = rng.choice([ROLLOUT, None, 3, "", text(0, 5)])
        if rng.random() < 0.1:
            members[text(1, 3)] = json_value()
        encoded = json.dumps(members, ensure_ascii=rng.random() < 0.5).encode()
        if rng.random() < 0.15:
            encoded = encoded[: rng.randrange(len(encoded) + 1)]
        helper_stdouts.append((encoded, rng.random() < 0.5))

    # Lone surrogates, appended after the seeded draws so they never shift them.
    texts += [("Codex value", v, 256) for v in ["a\ud800", "\udc80", "é\udfff"]]
    uuids += ["\ud800", THREAD[:-1] + "\udc00"]
    paths += [(ROLLOUT[:-6] + "\ud800.jsonl", THREAD)]
    finals += ["x\ud800y", "\x1b[31m\udc80\x1b[0m", "\ud83d\ude00\ud800"]
    payloads += [(THREAD, ROLLOUT[:-6] + "\ud800.jsonl", b"r"), ("\ud800", ROLLOUT, b"r")]
    helper_stdouts += [(b'{"ok":true,"rollout_path":"\\ud800"}', True), (b'{"ok":true,"\\udc00":1}', False)]

    return {
        "text": [{"input": [n, v, m], **attempt(lambda: codex._text(v, n, m))} for n, v, m in texts],
        "uuid": [{"input": v, **attempt(lambda: codex._uuid(v))} for v in uuids],
        "rollout_path": [{"input": [p, t], **attempt(lambda: codex._rollout_path(p, t))} for p, t in paths],
        "final_text": [{"input": v, **attempt(lambda: codex._final_text(v))} for v in finals]
        + [{"input": {"repeat": p, "times": n}, **attempt(lambda: codex._final_text(p * n))} for p, n in oversized],
        "payload": [{"input": [t, p, hexed(r)], **attempt(lambda: payload(t, p, r))} for t, p, r in payloads],
        "helper": [
            {"input": [hexed(s), c], **attempt(lambda: codex._parse_helper(s, collect=c))} for s, c in helper_stdouts
        ],
        "jsonl": jsonl_cases(),
        "json_bytes": json_bytes_cases(),
        "terminal": terminal_cases(),
    }


def codex_event(kind: str):
    if kind == "thread.started":
        return {"type": kind, "thread_id": rng.choice([THREAD, THREAD, THREAD, uuid_like(), 7])}
    if kind == "turn.started":
        return {"type": kind}
    if kind == "turn.completed":
        return {"type": kind, "usage": rng.choice([{}, {}, {"input_tokens": 3}, None, []])}
    if kind == "turn.failed":
        return {"type": kind, "error": rng.choice([{"message": "safe"}, {"message": 7}, {}, "x"])}
    if kind == "error":
        return {"type": kind, "message": rng.choice(["safe", "safe", 7, None])}
    item_type = rng.choice(["agent_message", "agent_message", "reasoning", "command_execution", "todo_list", "error", "unknown", ["agent_message"], None])
    item = {"id": rng.choice(["i1", "i2", "i3", "", 5]), "type": item_type}
    if item_type == "agent_message" and rng.random() < 0.9:
        item["text"] = rng.choice([text(0, 12), "answer", 7, None])
    event = {"type": kind, "item": item}
    if rng.random() < 0.05:
        event["item"] = rng.choice(["x", None, []])
    return event


def jsonl_cases() -> list[dict[str, object]]:
    raws: list[tuple[bytes, int]] = []

    def encode(events, *, ascii_=True) -> bytes:
        return b"\n".join(json.dumps(e, ensure_ascii=ascii_).encode() for e in events)

    good = [
        {"type": "thread.started", "thread_id": THREAD},
        {"type": "turn.started"},
        {"type": "item.completed", "item": {"id": "m", "type": "agent_message", "text": "answer"}},
        {"type": "turn.completed", "usage": {}},
    ]
    raws += [
        (encode(good), 0),
        (encode(good) + b"\n", 0),
        (encode(good) + b"\n\n", 0),
        (encode(good), 1),
        (b"", 0),
        (b"\n", 0),
        (b"\xef\xbb\xbf" + encode(good), 0),
        (encode(good).replace(b"answer", b"\\ud800"), 0),
        (encode(good).replace(b'"answer"', b"NaN"), 0),
        (encode(good) + b"\n[]", 0),
        (encode(good) + b'\n{"type":7}', 0),
        (b"\xff\n" + encode(good), 0),
    ]
    kinds = ["thread.started", "turn.started", "item.started", "item.updated", "item.completed", "error", "turn.completed", "turn.failed"]
    for _ in range(700):
        terminal = rng.choice(["turn.completed", "turn.failed"])
        middle = [rng.choice(["item.started", "item.updated", "item.completed", "item.completed", "error"]) for _ in range(rng.randint(0, 5))]
        sequence = ["thread.started", "turn.started", *middle, terminal]
        if rng.random() < 0.2:
            i = rng.randrange(len(sequence))
            sequence[i] = rng.choice(kinds + ["protocol.drift"])
        if rng.random() < 0.05:
            sequence.insert(rng.randrange(len(sequence) + 1), rng.choice(kinds))
        events = [codex_event(k) for k in sequence]
        returncode = 0 if terminal == "turn.completed" else 1
        if rng.random() < 0.1:
            returncode = rng.choice([0, 1, 2, -9])
        raw = encode(events, ascii_=rng.random() < 0.5)
        if rng.random() < 0.05:
            raw += b"\n"
        raws.append((raw, returncode))
    raws += [
        (encode(good).replace(THREAD.encode(), b"\\ud800"), 0),
        (encode(good).replace(b'"turn.started"', b'"\\udc00"'), 0),
        (encode(good).replace(b'"m"', b'"\\ud800"'), 0),
    ]

    def candidate(raw, code):
        value = codex._parse_jsonl(raw, code)
        return {"thread_id": value.thread_id, "completed": value.completed, "text": value.text}

    return [{"input": [hexed(r), c], **attempt(lambda: candidate(r, c))} for r, c in raws]


def json_bytes_cases() -> list[dict[str, object]]:
    values = [{"b": 1, "a": "é😀"}, [], {}, " ", 1.0, -0.0, 1e300, 2**64, None, {"ok": True, "result": {"z": [1, 2]}}]
    values += [json_value() for _ in range(300)]
    return [{"input": v, **attempt(lambda: service._json_bytes(v).hex())} for v in values]


def result_body(operation: str = "op", episode: str = "episode-1", turn: str = "turn-1") -> dict[str, object]:
    return {
        "version": 1,
        "operation_id": operation,
        "episode_id": episode,
        "turn_id": turn,
        "outcome": "completed",
        "accepted_appends": 1,
        "termination_code": "turn-completed",
        "output_reference": "out",
        "continuation_reference": "cont",
        "cleanup": {"disposition": "clean", "code": "client-closed"},
    }


def terminal_cases() -> list[dict[str, object]]:
    frames: list[tuple[bytes, str | None, str | None, str | None]] = []

    def frame(value) -> bytes:
        return service._json_bytes(value) + b"\n"

    base = {"ok": True, "result": result_body()}
    frames += [
        (frame(base), None, None, None),
        (frame(base), "op", "episode-1", "turn-1"),
        (frame(base), "other", None, None),
        (frame(base), None, "episode-2", None),
        (frame(base), None, None, "turn-2"),
        (frame({"ok": False, "error": "runtime-failed"}), None, None, None),
        (frame({"ok": False, "error": "unknown"}), None, None, None),
        (frame(base)[:-1], None, None, None),
        (frame(base) + b"\n", None, None, None),
        (json.dumps(base).encode() + b"\n", None, None, None),
        (b"[" * 2000 + b"]" * 2000 + b"\n", None, None, None),
        (b"\xff\n", None, None, None),
        (b"NaN\n", None, None, None),
        (b'{"ok":true,"ok":true}\n', None, None, None),
    ]
    fields = list(result_body())
    for _ in range(400):
        result = result_body()
        for _ in range(rng.randint(0, 2)):
            name = rng.choice(fields + ["cleanup.disposition", "cleanup.code", "extra"])
            replacement = rng.choice(
                [
                    None,
                    0,
                    1,
                    2,
                    True,
                    1.0,
                    "",
                    "x" * 4097,
                    "cancelled",
                    "failed",
                    "unverified",
                    "not-created",
                    "bad code",
                    "episode-1",
                    "op",
                    [],
                    {},
                    text(1, 6),
                ]
            )
            if name.startswith("cleanup."):
                current = result.get("cleanup")
                cleanup = dict(current) if isinstance(current, dict) else {}
                cleanup[name.split(".")[1]] = replacement
                result["cleanup"] = cleanup
            elif name == "extra":
                result[text(1, 4)] = replacement
            elif rng.random() < 0.1:
                result.pop(name)
            else:
                result[name] = replacement
        envelope: object = {"ok": True, "result": result}
        if rng.random() < 0.1:
            envelope = {"ok": False, "error": rng.choice(sorted(service._ERRORS) + ["nope", 3])}
        elif rng.random() < 0.05:
            envelope = rng.choice([[], {"ok": True}, {"ok": True, "result": [], "x": 1}, {"ok": None, "result": result}])
        frames.append((frame(envelope), rng.choice([None, "op", "x"]), rng.choice([None, "episode-1"]), rng.choice([None, "turn-1", "turn-x"])))
    for name in ["operation_id", "episode_id", "turn_id", "output_reference", "continuation_reference"]:
        frames.append((frame({"ok": True, "result": {**result_body(), name: "x\ud800"}}), None, None, None))
    frames.append((frame({"ok": True, "result": {**result_body(), "cleanup": {"disposition": "clean", "code": "\udc00"}}}), None, None, None))
    frames.append((frame({"ok": False, "error": "\ud800"}), None, None, None))

    def parse(encoded, operation, episode, turn):
        return service._parse_terminal(
            encoded,
            operation_id=operation,
            episode_id=None if episode is None else EpisodeId(episode),
            turn_id=None if turn is None else TurnId(turn),
        )

    return [{"input": [hexed(f), o, e, t], **attempt(lambda: parse(f, o, e, t))} for f, o, e, t in frames]


# ---------------------------------------------------------------------------
# Claude


def claude_section() -> dict[str, object]:
    texts = [("Claude value", text(0, 10), rng.choice([4, 16, 256])) for _ in range(200)]
    uuids = [THREAD, THREAD.upper(), "{" + THREAD + "}", "00000000-0000-0000-0000-000000000000", "11111111-1111-6111-8111-111111111111", "11111111-1111-4111-c111-111111111111"]
    uuids += [uuid_like() for _ in range(300)]
    transcripts = [[{"a": 1}], [], [1], [{"b": "é", "a": [1.5, None]}], [{"x": float("nan")}], [{}] * 3, [{"a": "x" * 50}]]
    transcripts += [[json_value() if rng.random() < 0.15 else {text(0, 3): json_value() for _ in range(rng.randint(0, 3))} for _ in range(rng.randint(0, 4))] for _ in range(300)]
    bounds = lambda: rng.choice([(10_000, 4_000_000), (2, 4_000_000), (10_000, 40)])  # noqa: E731

    def encode(value, entries, total):
        return claude._encode_transcript(value, entries, total).hex()

    def decode(value, entries, total):
        return list(claude._decode_transcript(value, entries, total))

    encoded_cases = []
    for value in transcripts:
        e, t = bounds()
        encoded_cases.append({"input": [value, e, t], **attempt(lambda: encode(value, e, t))})

    decoded_inputs = [b'[{"a":1}]', b'[{"a": 1}]', b'[{"b":1,"a":2}]', b"[]", b"", b'[{"a":NaN}]', b'[{"a":"\\u00e9"}]', '[{"a":"é"}]'.encode(), b"\xff", b'[{"a":1},{"a":1}]', b'[{"a":1.0}]', b'[{"a":1e5}]']
    for value in transcripts:
        try:
            raw = json.dumps(value, separators=(",", ":"), ensure_ascii=False, sort_keys=True, allow_nan=True).encode()
        except (TypeError, ValueError):
            continue
        decoded_inputs.append(raw if rng.random() < 0.7 else raw.replace(b",", b", "))
    decoded_cases = []
    for raw in decoded_inputs:
        e, t = bounds()
        decoded_cases.append({"input": [hexed(raw), e, t], **attempt(lambda: decode(raw, e, t))})

    inputs = [{"a": 1}, {}, [], {"b": "é", "a": None}, {"x": float("inf")}, {"x": "y" * 9000}, 1, None]
    inputs += [json_value() for _ in range(200)]

    sanitize = [(v, rng.choice([4, 64, 1_000_000])) for v in ["plain", "\x1b[31mred\x1b[0m", "a\x00b", "\x85x", ""]]
    sanitize += [(text(0, 20), rng.choice([8, 64, 1_000_000])) for _ in range(200)]

    payloads = [(THREAD, "a" * 64, "project-key", b'[{"a":1}]'), (THREAD, "A" * 64, "k", b'[{"a":1}]'), (THREAD, "a" * 64, "k", b"[]"), (THREAD, "a" * 63, "k", b'[{"a":1}]')]
    payloads += [
        (uuid_like() if rng.random() < 0.3 else THREAD, rng.choice(["a" * 64, "0" * 64, mutate("f" * 64)]), rng.choice(["k", "", text(0, 6)]), rng.choice([b'[{"a":1}]', b'[{"a": 1}]', b"", b"[1]"]))
        for _ in range(100)
    ]

    # Lone surrogates, appended after the seeded draws so they never shift them.
    texts += [("Claude value", v, 256) for v in ["a\ud800", "\udc80"]]
    uuids += ["\ud800"]
    for value in [[{"a": "\ud800"}], [{"\udc00": 1}]]:
        encoded_cases.append({"input": [value, 10_000, 4_000_000], **attempt(lambda: encode(value, 10_000, 4_000_000))})
    for raw in [b'[{"a":"\\ud800"}]', b'[{"\\udc00":1}]', b'[{"a":"\xed\xa0\x80"}]']:
        decoded_cases.append({"input": [hexed(raw), 10_000, 4_000_000], **attempt(lambda: decode(raw, 10_000, 4_000_000))})
    inputs += [{"a": "\ud800"}, "\udc00"]
    sanitize += [("a\ud800", 64), ("\x1b[31m\udc80", 64)]
    payloads += [(THREAD, "a" * 64, "k\ud800", b'[{"a":1}]'), (THREAD, "a" * 64, "k", b'[{"a":"\\ud800"}]')]

    def payload(session, binding, key, transcript):
        value = claude.ClaudeContinuationPayloadV1(session, binding, key, transcript)
        return {"session_id": value.session_id, "project_binding": value.project_binding, "project_key": value.project_key}

    return {
        "text": [{"input": [n, v, m], **attempt(lambda: claude._text(v, n, m))} for n, v, m in texts],
        "uuid": [{"input": v, **attempt(lambda: claude._uuid(v))} for v in uuids],
        "encode_transcript": encoded_cases,
        "decode_transcript": decoded_cases,
        "canonical_input": [{"input": v, **attempt(lambda: claude._canonical_input(v).hex())} for v in inputs],
        "sanitize": [{"input": [v, m], **attempt(lambda: claude._sanitize(v, m))} for v, m in sanitize],
        "payload": [{"input": [s, b, k, hexed(t)], **attempt(lambda: payload(s, b, k, t))} for s, b, k, t in payloads],
    }


# ---------------------------------------------------------------------------
# Amp


class Event(dict):
    """An SDK event: a mapping whose compact JSON is its encoded size."""

    def model_dump_json(self) -> str:
        return json.dumps(self, separators=(",", ":"))


AMP_THREAD = "T-0123abcd-4567-89ef"


def amp_event(kind: str, thread: str):
    if kind == "init":
        return Event({"type": rng.choice(["system", "system", "system", "assistant"]), "subtype": rng.choice(["init", "init", "init", "other"]), "session_id": rng.choice([thread, thread, thread, "T-x", "bad", 7])})
    if kind == "result":
        is_error = rng.choice([False, False, True, True, None, 0])
        subtype = rng.choice(["success", "success", "error_during_execution", "error_max_turns", "other", ["success"]])
        event = {"type": "result", "subtype": subtype, "is_error": is_error, "session_id": thread}
        if rng.random() < 0.9:
            event["result"] = rng.choice([text(0, 12), "answer", 7, None, "x" * 80])
        return Event(event)
    event_type = rng.choice(["assistant", "user", "assistant", "tool", ["assistant"], None])
    return Event({"type": event_type, "session_id": rng.choice([thread, thread, thread, "T-other-1"]), "message": text(0, 8)})


def read_stream(config, continuation, events):
    stub = types.SimpleNamespace(_config=config, _continuation_thread_id=continuation)
    operation = amp._AmpRuntimeOperation
    for name in ("_admit_initial", "_admit_later", "_admit_terminal"):
        setattr(stub, name, functools.partial(getattr(operation, name), stub))

    async def source():
        for event in events:
            yield event

    try:
        candidate = asyncio.run(operation._read_stream(stub, source()))
    except RuntimeProtocolError as error:
        return {"error": error.code}
    except Exception:  # noqa: BLE001 - ``_run`` maps it to client-failed
        return {"error": "client-failed"}
    return {
        "ok": {
            "outcome": candidate.outcome.value,
            "accepted_appends": candidate.accepted_appends,
            "termination_code": candidate.termination_code,
            "thread_id": candidate.thread_id,
            "final_text": candidate.final_text,
            "provider_terminal": candidate.provider_terminal,
        }
    }


def amp_section() -> dict[str, object]:
    texts = [("Amp value", text(0, 10), rng.choice([4, 16, 256])) for _ in range(200)]
    threads = [AMP_THREAD, "T-abc", "T-abc-", "T-a-b", "t-a-b", "T--a", " T-a-b", "T-a-b" + "c" * 124]
    threads += [mutate(AMP_THREAD) for _ in range(200)]
    finals = [(text(0, 20), rng.choice([8, 64, 1_000_000])) for _ in range(200)]
    payload_data = [
        {"schema_version": 1, "thread_id": AMP_THREAD},
        {"schema_version": True, "thread_id": AMP_THREAD},
        {"schema_version": 1.0, "thread_id": AMP_THREAD},
        {"schema_version": 2, "thread_id": AMP_THREAD},
        {"schema_version": 1, "thread_id": "bad"},
        {"schema_version": 1},
        {"schema_version": 1, "thread_id": AMP_THREAD, "x": 1},
        [],
        None,
    ]
    payload_data += [{"schema_version": rng.choice([1, 1, 0, "1"]), "thread_id": rng.choice([AMP_THREAD, mutate(AMP_THREAD), 3])} for _ in range(60)]

    def from_data(data):
        return amp.AmpContinuationPayloadV1.from_data(data).to_data()

    options = []
    for _ in range(30):
        config = amp.AmpRuntimeConfig(
            project=rng.choice(["project", "p-é"]),
            mode=rng.choice(["low", "medium", "high", "ultra"]),
            visibility=rng.choice(["private", "unlisted", "workspace", "group"]),
            no_archive_after_execute=rng.random() < 0.5,
        )
        continuation = rng.choice([None, AMP_THREAD])
        stub = types.SimpleNamespace(_config=config, _continuation_thread_id=continuation)
        options.append(
            {
                "input": [config.project, config.mode, config.visibility, config.no_archive_after_execute, continuation],
                "ok": list(amp._AmpRuntimeOperation._execution_options(stub).items()),
            }
        )

    streams = []
    for _ in range(600):
        limits = rng.choice([(10_000, 1_000_000, 4_000_000, 1_000_000), (3, 1_000_000, 4_000_000, 1_000_000), (10_000, 90, 4_000_000, 1_000_000), (10_000, 1_000_000, 200, 1_000_000), (10_000, 1_000_000, 4_000_000, 6)])
        config = amp.AmpRuntimeConfig(project="project", max_events=limits[0], max_event_bytes=limits[1], max_total_event_bytes=limits[2], max_final_text_bytes=limits[3])
        continuation = rng.choice([None, None, AMP_THREAD, "T-other-1"])
        kinds = ["init", *[rng.choice(["message", "message", "result"]) for _ in range(rng.randint(0, 3))], "result"]
        if rng.random() < 0.1:
            kinds = kinds[: rng.randrange(len(kinds))]
        events = [amp_event(k, AMP_THREAD) for k in kinds]
        streams.append({"input": {"limits": list(limits), "continuation": continuation, "events": [dict(e) for e in events]}, **read_stream(config, continuation, events)})

    # Lone surrogates, appended after the seeded draws so they never shift them.
    texts += [("Amp value", v, 256) for v in ["a\ud800", "\udc80"]]
    threads += ["T-a\ud800"]
    finals += [("a\ud800", 64), ("\ud83d\ude00\udc00", 1_000_000)]
    payload_data += [{"schema_version": 1, "thread_id": "T-a\ud800"}]
    for final in ["\ud800", "ok\udc00"]:
        config = amp.AmpRuntimeConfig(project="project", max_events=10_000, max_event_bytes=1_000_000, max_total_event_bytes=4_000_000, max_final_text_bytes=1_000_000)
        events = [
            Event({"type": "system", "subtype": "init", "session_id": AMP_THREAD}),
            Event({"type": "result", "subtype": "success", "is_error": False, "session_id": AMP_THREAD, "result": final}),
        ]
        streams.append({"input": {"limits": [10_000, 1_000_000, 4_000_000, 1_000_000], "continuation": None, "events": [dict(e) for e in events]}, **read_stream(config, None, events)})

    return {
        "bounded_text": [{"input": [n, v, m], **attempt(lambda: amp._bounded_text(v, n, m))} for n, v, m in texts],
        "thread_id": [{"input": v, **attempt(lambda: amp._thread_id(v))} for v in threads],
        "safe_final_text": [{"input": [v, m], **attempt(lambda: amp._safe_final_text(v, m))} for v, m in finals],
        "payload_from_data": [{"input": d, **attempt(lambda: from_data(d))} for d in payload_data],
        "execution_options": options,
        "streams": streams,
    }


def main() -> None:
    corpus = {"seed": SEED, "codex": codex_section(), "claude": claude_section(), "amp": amp_section()}
    # Lone surrogates travel as WTF-8 (``surrogatepass``), which the port's
    # ``loadsBytes`` reads back exactly as ``json.loads`` would.
    encoded = json.dumps(corpus, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    Path(sys.argv[1]).write_bytes(encoded.encode("utf-8", "surrogatepass"))
    for host in ("codex", "claude", "amp"):
        print(host, {name: len(cases) for name, cases in corpus[host].items()})


if __name__ == "__main__":
    main()
