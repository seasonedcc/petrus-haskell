"""Generate the Pi native runtime differential corpus from the reference.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-runtime/differential/pi_corpus.py \
        ../../packages/petrus-agenticus-runtime/differential/pi_corpus.json \
        ../../packages/petrus-agenticus-runtime/differential/pi_reference_ledger.sqlite3

The reference's ``test_pi.py`` fixtures (``Rig``) are imported from
``tests/petrus/agenticus/runtime`` to build live invocations.

Sections:

* ``validation``: the protocol validators (``_uuid``, ``_text``,
  ``base64.b64decode(validate=True)``, ``_validate_native_auth``,
  ``_decode_native_auth``, ``_validate_session``, ``_strict_load``,
  ``_working_binding`` and ``PiContinuationPayloadV1``) over accepted and
  rejected inputs. Each case records the result or the ``{class, message}``
  refusal.
* ``frames``: exact wire bytes from ``_SubprocessClient._write`` (its stdin
  is replaced by a buffer), for ``start`` frames built by real clients over
  several prompts, priors, grants and credentials, and for ``tool_result``,
  ``abort`` and arbitrary frames, including refused ones.
* ``fingerprints``: ``pi_durable_work_fingerprint`` over identity changes.
* ``records``: ``PiOperationRecord`` construction over a settled base and
  mutations of one field (seeded, seed 9091).
* ``ledger``: a scripted ``SqlitePiOperationLedger`` session (every call's
  record or refusal), its exact ``sqlite_master`` and ``table_info`` rows,
  its raw rows and ``sqlite_sequence`` before and after ``recover``, and raw
  row mutations applied to the reference-written file before reopening it.
  The file written before ``recover`` is saved as
  ``pi_reference_ledger.sqlite3`` for the Haskell side to cross-open.
"""

from __future__ import annotations

import base64
import dataclasses
import io
import json
import random
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, "tests/petrus/agenticus/runtime")

import test_pi as fixtures  # noqa: E402

import petrus.agenticus.runtime.pi as pi  # noqa: E402
from petrus.agenticus.connection.custody import ConnectionIdentity  # noqa: E402
from petrus.agenticus.hands.contract import ToolMethod  # noqa: E402
from petrus.agenticus.runtime.operation import RuntimeCleanupDisposition, RuntimeOperationCleanup  # noqa: E402
from petrus.agenticus.runtime.pi_recovery import (  # noqa: E402
    PiOperationPhase,
    PiOperationRecord,
    SqlitePiOperationLedger,
)
from petrus.agenticus.runtime.result import RuntimeTurnSettlement  # noqa: E402
from petrus.agenticus.thread.continuation import Continuation, ContinuationState  # noqa: E402
from petrus.agenticus.thread.identity import ContinuationId, EpisodeId, ThreadId, TurnId  # noqa: E402
from petrus.agenticus.thread.lifecycle import TurnOutcome  # noqa: E402

SEED = 9091
SESSION = fixtures.SESSION
B64 = lambda value: base64.b64encode(value).decode()  # noqa: E731


def refusal(error: BaseException) -> dict[str, object]:
    return {"class": type(error).__name__, "message": str(error)}


def attempt(action) -> dict[str, object]:
    try:
        return {"ok": action()}
    except Exception as error:  # noqa: BLE001 - every refusal is corpus data
        return {"error": refusal(error)}


# ---------------------------------------------------------------------------
# Validation


def compact(value: object) -> str:
    """ASCII-escaped, so lone surrogates the reader accepts stay representable."""
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True)


def validation() -> list[dict[str, object]]:
    cases: list[dict[str, object]] = []

    def case(function: str, arguments: dict[str, object], action) -> None:
        cases.append({"function": function, "arguments": arguments, **attempt(action)})

    for value in [
        SESSION,
        fixtures.OTHER,
        "",
        " " + SESSION,
        SESSION.upper(),
        "11111111-1111-1111-8111-111111111111",
        "11111111-1111-6111-8111-111111111111",
        "11111111-1111-4111-c111-111111111111",
        "11111111111141118111111111111111",
        "{11111111-1111-4111-8111-111111111111}",
        "urn:uuid:11111111-1111-4111-8111-111111111111",
        "11111111-1111-4111-8111-11111111111",
        "11111111-1111-4111-8111-1111111111111",
        "11111111-1111-4111-8111-11111111111\u0661",
        "not-uuid",
    ]:
        case("uuid", {"value": value}, lambda value=value: pi._uuid(value))

    for value, maximum in [
        ("model", 256),
        ("", 256),
        (" model", 256),
        ("model\t", 256),
        ("mo\u0001del", 256),
        ("é" * 128, 256),
        ("é" * 129, 256),
        ("\u00a0model", 256),
        ("model\u2028", 256),
        ("x" * 36, 36),
        ("x" * 37, 36),
    ]:
        case("text", {"value": value, "maximum": maximum}, lambda value=value, maximum=maximum: pi._text(value, "Pi label", maximum))

    for value in ["", "YQ==", "YQ", "YQ=", "YQ===", "Y Q==", "YQ==\n", "YWJj", "YW-j", "YW_j", "////", "+/+/", "\u00e9", "Y\u0661==", "YR=="]:
        case("b64decode", {"value": value}, lambda value=value: B64(base64.b64decode(value, validate=True)))

    authorities = [
        (fixtures.AUTH, "anthropic"),
        (fixtures.OPENAI_AUTH, "openai-codex"),
        (fixtures.AUTH, "openai-codex"),
        (b'{"openai-codex":{"type":"oauth","access":"a","refresh":"r","expires":1}}', "openai-codex"),
        (b'{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":1.5}}', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":true}}', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":1e400}}', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":NaN}}', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"","refresh":"r","expires":1}}', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"a","refresh":"r"}}', "anthropic"),
        (b'{"anthropic":{"type":"api","access":"a","refresh":"r","expires":1}}', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"a","access":"b","refresh":"r","expires":1}}', "anthropic"),
        (b'{"anthropic":[]}', "anthropic"),
        (b'[{"anthropic":{}}]', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"\xc3\xa9","refresh":"r","expires":1}}', "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"\xff","refresh":"r","expires":1}}', "anthropic"),
        (b"", "anthropic"),
        (b"not-json", "anthropic"),
        (b'{"anthropic":{"type":"oauth","access":"a","refresh":"r","expires":1}} ', "anthropic"),
    ]
    for value, provider in authorities:
        for maximum in (len(value), max(len(value) - 1, 1), 1_000_000):
            case(
                "validate_native_auth",
                {"value": B64(value), "provider": provider, "maximum": maximum},
                lambda value=value, provider=provider, maximum=maximum: B64(
                    pi._validate_native_auth(value, provider, maximum)
                ),
            )

    canonical = B64(fixtures.AUTH)
    for value, maximum in [
        (canonical, len(fixtures.AUTH)),
        (canonical + "=", len(fixtures.AUTH) + 1),
        (B64(fixtures.AUTH + b"\0"), len(fixtures.AUTH) + 1),
        (canonical, len(fixtures.AUTH) - 1),
        (canonical[:-2], len(fixtures.AUTH)),
        (canonical.replace("e", "-", 1), len(fixtures.AUTH)),
        (" " + canonical, len(fixtures.AUTH)),
        (1, len(fixtures.AUTH)),
        (None, len(fixtures.AUTH)),
    ]:
        case(
            "decode_native_auth",
            {"value": value, "provider": "anthropic", "maximum": maximum},
            lambda value=value, maximum=maximum: B64(pi._decode_native_auth(value, "anthropic", maximum)),
        )

    header = fixtures.session()
    sessions = [
        header,
        header + b'{"type":"message"}\n',
        header + b'{"type":"message","body":"\xc3\xa9"}\n',
        b'{"type":"message"}\n' + header,
        header + header,
        header[:-1],
        header + b"\n",
        header + b"\r\n",
        header + b'{"type":"message"}\r\n',
        header + b"[]\n",
        header + b'{"a":1,"a":2}\n',
        header + b'{"a":NaN}\n',
        header + b'{"a":Infinity}\n',
        header + b'{"a":1e400}\n',
        header + b'{"a":"\xff"}\n',
        header + b'{"a":"\\ud800"}\n',
        header + b"\x0b\n",
        header + b'{"a":1}\x0b{"b":2}\n',
        header + b'{"a":1}\x1c\n',
        b'{"type":"session","version":3.0,"id":"' + SESSION.encode() + b'"}\n',
        b'{"type":"session","version":true,"id":"' + SESSION.encode() + b'"}\n',
        b'{"type":"session","version":3,"id":"' + fixtures.OTHER.encode() + b'"}\n',
        b"",
        b" " + header,
    ]
    for value in sessions:
        for maximum, events in [(4_000_000, 10_000), (len(value), 1), (max(len(value) - 1, 1), 10_000)]:
            case(
                "validate_session",
                {"value": B64(value), "session_id": SESSION, "maximum": maximum, "events": events},
                lambda value=value, maximum=maximum, events=events: B64(
                    pi._validate_session(value, SESSION, maximum, events)
                ),
            )

    for raw in [
        b"{}",
        b'{"a":1}',
        b'{"a":1,"a":1}',
        b'{"a":{"b":1,"b":2}}',
        b"[1,2,3]",
        b'"text"',
        b"1",
        b"-0",
        b"1.0",
        b"1e5",
        b"1E+2",
        b"-0.0",
        b"0.1",
        b"1e400",
        b"-1e400",
        b"123456789012345678901234567890",
        b"NaN",
        b"Infinity",
        b"-Infinity",
        b"nan",
        b'{"a":"\\u00e9\\ud83d\\ude00"}',
        b'{"a":"\xc3\xa9"}',
        b'{"a":"\\ud800"}',
        b'"\xff"',
        b' {"a":1} ',
        b'{"a":1} x',
        b'{"a":1}\n',
        b'{"a":01}',
        b"{'a':1}",
        b'{"a":[1,]}',
        b'{"a":"\t"}',
        b"\xef\xbb\xbf{}",
        b"",
        b"true",
        b"null",
    ]:
        case("strict_load", {"value": B64(raw)}, lambda raw=raw: compact(pi._strict_load(raw)))

    for path in ["/tmp/working", "/tmp/wörking", "/", "/tmp/a b/c"]:
        case("working_binding", {"value": path}, lambda path=path: pi._working_binding(Path(path)))

    binding = "d" * 64
    for session_id, working, body in [
        (SESSION, binding, header),
        (SESSION, "D" * 64, header),
        (SESSION, "d" * 63, header),
        (SESSION, "g" * 64, header),
        (SESSION, " " + "d" * 63, header),
        (fixtures.OTHER, binding, header),
        (SESSION.upper(), binding, header),
        (SESSION, binding, header + b'{"x":NaN}\n'),
    ]:
        case(
            "payload",
            {"session_id": session_id, "binding": working, "session": B64(body)},
            lambda session_id=session_id, working=working, body=body: B64(
                pi.PiContinuationPayloadV1(session_id, working, body).session_jsonl
            ),
        )
    return cases


# ---------------------------------------------------------------------------
# Frames


class Capture:
    def __init__(self) -> None:
        self.buffer = io.BytesIO()

    def write(self, value: bytes) -> int:
        return self.buffer.write(value)

    def flush(self) -> None:
        pass


def capture(client: pi._SubprocessClient, frame: dict[str, object]) -> dict[str, object]:
    sink = Capture()
    original = client._process.stdin
    client._process.stdin = sink  # type: ignore[assignment]
    try:
        client._write(frame)
        return {"ok": B64(sink.buffer.getvalue())}
    except Exception as error:  # noqa: BLE001
        return {"error": refusal(error)}
    finally:
        client._process.stdin = original


def client_for(rig, invocation, private_root: Path, *, prior=None, api_key=None, native_auth=None, config=None):
    return pi._SubprocessClient(
        node="/usr/bin/true",
        sdk_entrypoint="/ignored",
        helper=Path("/ignored"),
        private_root=private_root,
        config=config or rig.adapter._config,
        invocation=invocation,
        prior=prior,
        api_key=api_key,
        native_auth=native_auth,
        extension=None,
    )


def retire(client: pi._SubprocessClient) -> None:
    client._process.wait()
    for stream in (client._process.stdin, client._process.stdout):
        if stream is not None:
            stream.close()
    client._stderr.join(5)


def frames(root: Path) -> dict[str, object]:
    starts: list[dict[str, object]] = []
    prompts = [
        fixtures.PROMPT,
        "héllo ✓ 🙂",
        'quote " backslash \\ slash / newline \n tab \t',
        "\u2028\u2029\u007f\u0080\ufeff",
        "\u0001\u001f",
    ]
    capability_sets = [
        tuple(ToolMethod),
        (ToolMethod.WORKSPACE_READ,),
        (ToolMethod.WORKSPACE_TEST, ToolMethod.WORKSPACE_READ),
        (ToolMethod.WORKSPACE_WRITE, ToolMethod.WORKSPACE_SEARCH, ToolMethod.WORKSPACE_SHELL),
    ]
    index = 0
    for profile in ("api-key", "subscription"):
        rig = fixtures.Rig(root / f"start-{profile}", profile=profile)
        for capabilities in capability_sets:
            for prompt in prompts:
                for resumed in (False, True):
                    index += 1
                    invocation, _ = rig.invocation(f"start-{index}", capabilities=capabilities)
                    invocation = dataclasses.replace(invocation, prompt=prompt)
                    prior = (
                        pi.PiContinuationPayloadV1(
                            SESSION,
                            pi._working_binding(rig.adapter._config.working_directory),
                            fixtures.session(SESSION, {"body": "é ✓"}),
                        )
                        if resumed
                        else None
                    )
                    private_root = rig.adapter._config.runtime_root / f"start-{index}"
                    private_root.mkdir(mode=0o700)
                    client = client_for(
                        rig,
                        invocation,
                        private_root,
                        prior=prior,
                        api_key=fixtures.KEY.decode() if profile == "api-key" else None,
                        native_auth=fixtures.AUTH if profile == "subscription" else None,
                    )
                    config = rig.adapter._config
                    starts.append(
                        {
                            "provider": config.provider,
                            "model": config.model,
                            "cwd": str(config.working_directory),
                            "root": str(private_root),
                            "prompt": prompt,
                            "session_id": client._start["session_id"] if resumed else None,
                            "prior": B64(prior.session_jsonl) if prior else None,
                            "capabilities": [method.value for method in capabilities],
                            "api_key": client._start.get("api_key"),
                            "auth": client._start.get("auth"),
                            "frame": capture(client, client._start),
                        }
                    )
                    retire(client)
                    shutil.rmtree(private_root)

    rig = fixtures.Rig(root / "frames")
    invocation, _ = rig.invocation("frames")
    private_root = rig.adapter._config.runtime_root / "frames"
    private_root.mkdir(mode=0o700)
    client = client_for(rig, invocation, private_root, api_key=fixtures.KEY.decode())
    small = replace_frame_bound(rig, 64)
    small_client = client_for(rig, invocation, private_root, api_key=fixtures.KEY.decode(), config=small)
    values: list[object] = [
        {"type": "abort"},
        {"type": "tool_result", "id": "call-1", "result": {"version": 1, "ok": True, "error": None, "data": {"content": "marker"}}},
        {
            "type": "tool_result",
            "id": "call-é",
            "result": {"version": 1, "ok": False, "error": {"category": "capability", "message": "denied ✓"}, "data": None},
        },
        {"type": "tool_result", "id": "x", "result": {"floats": [0.1, 1.0, -0.0, 1e100, 1e-7, 123456789.125, 5e-324]}},
        {"type": "tool_result", "id": "x", "result": {"ints": [0, -1, 2**63, -(2**63) - 1, 10**30]}},
        {"type": "tool_result", "id": "x", "result": {"text": "\u0000\u001f\u007f\u2028\U0001f600\"\\/"}},
        {"type": "tool_result", "id": "x", "result": {"nested": [[[]], {}, [{"a": [None, True, False]}]]}},
        {"type": "tool_result", "id": "x", "result": {"nan": float("nan")}},
        {"type": "tool_result", "id": "x", "result": {"inf": float("inf")}},
        {"z": 1, "a": 2, "m": {"b": 1, "a": 2}},
    ]
    others = [{"frame": value, "result": capture(client, value)} for value in values]
    bounded = [
        {"frame": value, "maximum": 64, "result": capture(small_client, value)}
        for value in [
            {"type": "abort"},
            {"type": "tool_result", "id": "x" * 30, "result": None},
            {"type": "tool_result", "id": "x" * 29, "result": None},
            {"type": "tool_result", "id": "é" * 15, "result": None},
        ]
    ]
    for each in (client, small_client):
        retire(each)
    shutil.rmtree(private_root)
    return {"starts": starts, "others": others, "bounded": bounded}


def replace_frame_bound(rig, maximum: int) -> pi.PiRuntimeConfig:
    """A config copy with a tiny frame bound, past the constructor's checks."""
    config = dataclasses.replace(rig.adapter._config)
    object.__setattr__(config, "max_frame_bytes", maximum)
    return config


# ---------------------------------------------------------------------------
# Fingerprints


def fingerprints(root: Path) -> list[dict[str, object]]:
    working, private = root / "fp-working", root / "fp-private"
    working.mkdir()
    private.mkdir(mode=0o700)
    configs = {
        "api-key": pi.PiRuntimeConfig("provider", "model", working, private),
        "gondolin": pi.PiRuntimeConfig("provider", "model", working, private, territory_profile="gondolin"),
        "cc-patch": pi.PiRuntimeConfig("anthropic", "claude-sonnet-4-5", working, private, cc_patch=True),
        "other-model": pi.PiRuntimeConfig("provider", "model-2", working, private),
    }
    identity = ConnectionIdentity("connection", "provider", "account", "api-key")
    continuation = Continuation(
        ContinuationId("continuation"),
        ThreadId("thread"),
        pi.PI_CONTINUATION_DESCRIPTOR,
        "pi-continuation-é",
        ContinuationState.IN_USE,
    )
    cases: list[dict[str, object]] = []
    variants = [
        ("api-key", "episode", "turn", fixtures.PROMPT, identity, None),
        ("api-key", "episode", "turn", fixtures.PROMPT, identity, continuation),
        ("gondolin", "episode", "turn", fixtures.PROMPT, identity, None),
        ("cc-patch", "episode", "turn", fixtures.PROMPT, ConnectionIdentity("c", "anthropic", "a", "cc-patch-subscription"), None),
        ("other-model", "episode", "turn", fixtures.PROMPT, identity, None),
        ("api-key", "episode-2", "turn", fixtures.PROMPT, identity, None),
        ("api-key", "episode", "turn-2", fixtures.PROMPT, identity, None),
        ("api-key", "episode", "turn", "héllo ✓ 🙂", identity, None),
        ("api-key", "episode", "turn", "", identity, None),
        ("api-key", "episode", "turn", "nul\0", identity, None),
        ("api-key", "episode", "turn", "x" * (64 * 1024), identity, None),
        ("api-key", "episode", "turn", "é" * (32 * 1024 + 1), identity, None),
        ("api-key", "episode", "turn", fixtures.PROMPT, ConnectionIdentity("connection-é", "provider", "account", "api-key"), None),
    ]
    for config_name, episode, turn, prompt, connection, cont in variants:
        cases.append(
            {
                "config": config_name,
                "episode_id": episode,
                "turn_id": turn,
                "prompt": prompt,
                "connection": [connection.connection_id, connection.provider, connection.account_fingerprint, connection.profile],
                "continuation": None
                if cont is None
                else [cont.id.value, cont.thread.value, cont.state_reference],
                **attempt(
                    lambda config_name=config_name, episode=episode, turn=turn, prompt=prompt, connection=connection, cont=cont: (
                        pi.pi_durable_work_fingerprint(
                            configs[config_name], EpisodeId(episode), TurnId(turn), prompt, connection, cont
                        )
                    )
                ),
            }
        )
    return cases


# ---------------------------------------------------------------------------
# Records and the ledger


def record_data(record: PiOperationRecord) -> dict[str, object]:
    return {
        "operation_id": record.operation_id,
        "fingerprint": record.fingerprint,
        "episode_id": record.episode_id.value,
        "turn_id": record.turn_id.value,
        "sequence": record.sequence,
        "phase": record.phase.value,
        "outcome": None if record.outcome is None else record.outcome.value,
        "accepted_appends": record.accepted_appends,
        "termination_code": record.termination_code,
        "output_reference": record.output_reference,
        "continuation_reference": record.continuation_reference,
        "cleanup": record.cleanup.value,
        "cleanup_code": record.cleanup_code,
        "acknowledged": record.acknowledged,
    }


def record_from(data: dict[str, object]) -> PiOperationRecord:
    return PiOperationRecord(
        data["operation_id"],  # type: ignore[arg-type]
        data["fingerprint"],  # type: ignore[arg-type]
        EpisodeId(data["episode_id"]),  # type: ignore[arg-type]
        TurnId(data["turn_id"]),  # type: ignore[arg-type]
        data["sequence"],  # type: ignore[arg-type]
        PiOperationPhase(data["phase"]),
        None if data["outcome"] is None else TurnOutcome(data["outcome"]),
        data["accepted_appends"],  # type: ignore[arg-type]
        data["termination_code"],  # type: ignore[arg-type]
        data["output_reference"],  # type: ignore[arg-type]
        data["continuation_reference"],  # type: ignore[arg-type]
        RuntimeCleanupDisposition(data["cleanup"]),
        data["cleanup_code"],  # type: ignore[arg-type]
        data["acknowledged"],  # type: ignore[arg-type]
    )


FINGERPRINT = "0123456789abcdef" * 4
SETTLED = {
    "operation_id": "operation",
    "fingerprint": FINGERPRINT,
    "episode_id": "episode",
    "turn_id": "turn",
    "sequence": 1,
    "phase": "settled",
    "outcome": "completed",
    "accepted_appends": 1,
    "termination_code": "turn-completed",
    "output_reference": "pi-turn-operation",
    "continuation_reference": "pi-continuation-operation",
    "cleanup": "clean",
    "cleanup_code": "cleanup-verified",
    "acknowledged": True,
}
EXECUTING = {
    **SETTLED,
    "phase": "executing",
    "outcome": None,
    "accepted_appends": None,
    "termination_code": None,
    "output_reference": None,
    "continuation_reference": None,
    "cleanup": "unverified",
    "cleanup_code": "cleanup-uncertain",
    "acknowledged": False,
}
WEIRD: dict[str, list[object]] = {
    "operation_id": ["", " operation", "operation\n", "o" * 256, "o" * 257, "é" * 128, "é" * 129, "op\u0085"],
    "fingerprint": [
        "",
        "0" * 63,
        "0" * 65,
        "G" * 64,
        "ABCDEF" + "0" * 58,
        " " + "0" * 62 + " ",
        "+" + "0" * 63,
        "-" + "0" * 63,
        "0x" + "0" * 62,
        "0_" + "0" * 62,
        "\u0661" * 64,
        "\uff10" * 64,
        "\u0663" + "0" * 63,
        "_" + "0" * 63,
        "0" * 62 + "__",
    ],
    "sequence": [0, -1, 2, 2**62],
    "accepted_appends": [None, 0, -1, 7],
    "termination_code": [None, "", "Turn-Completed", "turn completed", "x" * 64, "x" * 65, "a-b_c.d"],
    "outcome": [None, "failed", "cancelled", "indeterminate"],
    "output_reference": [None, "", "ref"],
    "continuation_reference": [None, "", "ref"],
    "cleanup": ["unverified", "not-created"],
    "cleanup_code": ["", "cleanup-uncertain", "Cleanup", "c" * 65],
    "acknowledged": [False, True],
    "phase": ["executing", "settled"],
}


def records() -> list[dict[str, object]]:
    rng = random.Random(SEED)
    cases: list[dict[str, object]] = []
    for base_name, base in (("settled", SETTLED), ("executing", EXECUTING)):
        cases.append({"base": base_name, "path": None, "value": None, **attempt(lambda base=base: record_data(record_from(base)))})
        for key, values in WEIRD.items():
            for value in values:
                mutated = {**base, key: value}
                cases.append(
                    {"base": base_name, "path": key, "value": value, **attempt(lambda mutated=mutated: record_data(record_from(mutated)))}
                )
        for _ in range(40):
            mutated = dict(base)
            for key in rng.sample(sorted(WEIRD), 2):
                mutated[key] = rng.choice(WEIRD[key])
            cases.append(
                {"base": base_name, "mutation": mutated, **attempt(lambda mutated=mutated: record_data(record_from(mutated)))}
            )
    return cases


def settlement(episode: str, turn: str, outcome: str, appends: int, code: str, output, continuation):
    return RuntimeTurnSettlement(EpisodeId(episode), TurnId(turn), TurnOutcome(outcome), appends, code, output, continuation)


def cell(value: object) -> object:
    if value is None:
        return None
    if isinstance(value, int):
        return {"int": value}
    if isinstance(value, str):
        return {"text": value}
    return {"other": repr(value)}


def dump(path: Path) -> dict[str, object]:
    database = sqlite3.connect(path)
    try:
        return {
            "master": [
                [cell(value) for value in row]
                for row in database.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name")
            ],
            "table_info": [[cell(value) for value in row] for row in database.execute("PRAGMA table_info(pi_operations)")],
            "rows": [[cell(value) for value in row] for row in database.execute("SELECT * FROM pi_operations ORDER BY sequence")],
            "sequence": [[cell(value) for value in row] for row in database.execute("SELECT name, seq FROM sqlite_sequence")],
            "journal_mode": database.execute("PRAGMA journal_mode").fetchone()[0],
        }
    finally:
        database.close()


SCRIPT: list[dict[str, object]] = [
    {"op": "admit", "id": "op-a", "fingerprint": "a" * 64, "episode": "episode-a", "turn": "turn-a"},
    {"op": "admit", "id": "op-b", "fingerprint": "b" * 64, "episode": "episode-b", "turn": "turn-b"},
    {"op": "admit", "id": "op-a", "fingerprint": "c" * 64, "episode": "episode-x", "turn": "turn-x"},
    {"op": "admit", "id": "op-c", "fingerprint": "c" * 64, "episode": "episode-c", "turn": "turn-c"},
    {"op": "admit", "id": "op-é", "fingerprint": "d" * 64, "episode": "episode-é", "turn": "turn-é"},
    {"op": "admit", "id": " bad", "fingerprint": "d" * 64, "episode": "episode", "turn": "turn"},
    {"op": "admit", "id": "op-bad-fingerprint", "fingerprint": "z" * 64, "episode": "episode", "turn": "turn"},
    {"op": "lookup", "id": "op-a"},
    {"op": "lookup", "id": "absent"},
    {"op": "lookup", "id": ""},
    {"op": "acknowledge", "id": "op-a"},
    {"op": "upgrade", "id": "op-a", "cleanup": ["op-a", "clean", "cleanup-verified", False]},
    {"op": "settle", "id": "op-a", "settlement": ["episode-a", "turn-a", "completed", 1, "turn-completed", "pi-turn-op-a", "pi-continuation-op-a"]},
    {"op": "settle", "id": "op-a", "settlement": ["episode-a", "turn-a", "completed", 1, "turn-completed", "pi-turn-op-a", "pi-continuation-op-a"]},
    {"op": "settle", "id": "op-a", "settlement": ["episode-a", "turn-a", "failed", 0, "provider-failed", None, None]},
    {"op": "settle", "id": "op-b", "settlement": ["episode-x", "turn-b", "failed", 0, "provider-failed", None, None]},
    {"op": "settle", "id": "op-b", "settlement": ["episode-b", "turn-b", "failed", 0, "provider-failed", None, None]},
    {"op": "settle", "id": "absent", "settlement": ["episode-b", "turn-b", "failed", 0, "provider-failed", None, None]},
    {"op": "upgrade", "id": "op-a", "cleanup": ["op-b", "clean", "cleanup-verified", False]},
    {"op": "upgrade", "id": "op-a", "cleanup": ["op-a", "unverified", "cleanup-uncertain", False]},
    {"op": "upgrade", "id": "op-a", "cleanup": ["op-a", "unverified", "cleanup-other", False]},
    {"op": "upgrade", "id": "op-a", "cleanup": ["op-a", "clean", "cleanup-verified", True]},
    {"op": "upgrade", "id": "op-a", "cleanup": ["op-a", "clean", "cleanup-verified", False]},
    {"op": "upgrade", "id": "op-a", "cleanup": ["op-a", "not-created", "cleanup-verified", False]},
    {"op": "upgrade", "id": "op-b", "cleanup": ["op-b", "not-created", "runtime-not-created", False]},
    {"op": "watermark"},
    {"op": "acknowledge", "id": "op-a"},
    {"op": "acknowledge", "id": "op-a"},
    {"op": "watermark"},
    {"op": "acknowledge", "id": "op-b"},
    {"op": "watermark"},
    {"op": "settle", "id": "op-é", "settlement": ["episode-é", "turn-é", "cancelled", 0, "cancelled", None, None]},
    {"op": "records"},
]
RECOVER_SCRIPT: list[dict[str, object]] = [
    {"op": "recover"},
    {"op": "recover"},
    {"op": "records"},
    {"op": "watermark"},
    {"op": "upgrade", "id": "op-c", "cleanup": ["op-c", "clean", "cleanup-verified", False]},
    {"op": "acknowledge", "id": "op-c"},
    {"op": "acknowledge", "id": "op-é"},
    {"op": "watermark"},
    {"op": "records"},
]


def run(ledger: SqlitePiOperationLedger, step: dict[str, object]) -> dict[str, object]:
    op = step["op"]
    if op == "admit":
        return attempt(
            lambda: record_data(
                ledger.admit(step["id"], step["fingerprint"], EpisodeId(step["episode"]), TurnId(step["turn"]))  # type: ignore[arg-type]
            )
        )
    if op == "lookup":
        return attempt(lambda: None if (found := ledger.lookup(step["id"])) is None else record_data(found))  # type: ignore[arg-type]
    if op == "settle":
        return attempt(lambda: record_data(ledger.settle(step["id"], settlement(*step["settlement"]))))  # type: ignore[arg-type,misc]
    if op == "upgrade":
        operation, disposition, code, erased = step["cleanup"]  # type: ignore[misc]
        return attempt(
            lambda: record_data(
                ledger.upgrade_cleanup(
                    step["id"],  # type: ignore[arg-type]
                    RuntimeOperationCleanup(operation, RuntimeCleanupDisposition(disposition), code, erased),
                )
            )
        )
    if op == "acknowledge":
        return attempt(lambda: record_data(ledger.acknowledge(step["id"])))  # type: ignore[arg-type]
    if op == "watermark":
        return attempt(ledger.watermark)
    if op == "records":
        return attempt(lambda: [record_data(record) for record in ledger.records()])
    if op == "recover":
        return attempt(lambda: [record_data(record) for record in ledger.recover()])
    raise AssertionError(op)


ROW_MUTATIONS: list[tuple[str, list[object]]] = [
    ("UPDATE pi_operations SET phase = 'bogus' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET outcome = 'bogus' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET cleanup = 'bogus' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET cleanup_code = 'Bogus' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET fingerprint = 'short' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET accepted_appends = NULL WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET accepted_appends = -1 WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET accepted_appends = '1' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET accepted_appends = 1.5 WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET termination_code = NULL WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET output_reference = '' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET episode_id = '' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET turn_id = ' turn' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET phase = 'executing' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET operation_id = 'op-a ' WHERE operation_id = 'op-a'", []),
    ("UPDATE pi_operations SET fingerprint = ? WHERE operation_id = 'op-a'", ["\u0661" * 64]),
    ("UPDATE pi_operations SET fingerprint = ? WHERE operation_id = 'op-a'", [b"a" * 64]),
    ("UPDATE pi_operations SET operation_id = ? WHERE operation_id = 'op-a'", [b"op-a"]),
    ("DELETE FROM pi_operations WHERE operation_id = 'op-b'", []),
    ("UPDATE pi_operations SET sequence = 9 WHERE operation_id = 'op-c'", []),
]


def mutate(reference: Path, root: Path) -> list[dict[str, object]]:
    cases = []
    for index, (sql, parameters) in enumerate(ROW_MUTATIONS):
        directory = root / f"mutation-{index}"
        directory.mkdir(mode=0o700)
        path = directory / "operations.sqlite3"
        shutil.copyfile(reference, path)
        path.chmod(0o600)
        database = sqlite3.connect(path, isolation_level=None)
        database.execute(sql, parameters)
        database.close()
        ledger = SqlitePiOperationLedger(path)
        try:
            cases.append(
                {
                    "sql": sql,
                    "parameters": [
                        {"blob": B64(value)} if isinstance(value, bytes) else cell(value) for value in parameters
                    ],
                    "lookup": run(ledger, {"op": "lookup", "id": "op-a"}),
                    "records": run(ledger, {"op": "records"}),
                }
            )
        finally:
            ledger.close()
    return cases


def ledger(root: Path, reference_out: Path) -> dict[str, object]:
    directory = root / "ledger"
    path = directory / "operations.sqlite3"
    ledger = SqlitePiOperationLedger(path)
    first = [{"step": step, "result": run(ledger, step)} for step in SCRIPT]
    ledger.close()
    before = dump(path)
    shutil.copyfile(path, reference_out)
    mutations = mutate(path, root)
    reopened = SqlitePiOperationLedger(path)
    second = [{"step": step, "result": run(reopened, step)} for step in RECOVER_SCRIPT]
    reopened.close()
    return {
        "script": first,
        "dump": before,
        "recover_script": second,
        "recovered_dump": dump(path),
        "mutations": mutations,
    }


def main() -> None:
    out, reference = Path(sys.argv[1]), Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        corpus = {
            "seed": SEED,
            "validation": validation(),
            "frames": frames(root / "frames"),
            "fingerprints": fingerprints(root),
            "records": records(),
            "ledger": ledger(root, reference),
        }
    out.write_text(json.dumps(corpus, indent=1, ensure_ascii=True, allow_nan=True) + "\n")


if __name__ == "__main__":
    main()
