"""Generate ``substrate_fixtures.json`` from upstream's ArtifactStore and Timeline.

Every expected byte comes from running the upstream implementation
(``petrus.motus._execution.artifacts`` / ``.timeline``), so the Haskell
suite proves byte-identical persisted metadata, Timeline lines, redaction
and telemetry mirroring.

Run from the repository root:

    upstream/petrus/.venv/bin/python packages/petrus-execution/test/fixtures/generate_substrate_fixtures.py
"""

from __future__ import annotations

import json
import logging
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from petrus.motus._execution import timeline as timeline_module
from petrus.motus._execution.artifacts import ArtifactStore, ProducerCorrelation
from petrus.motus._execution.timeline import TelemetryTimelineHandler, Timeline, TimelineEvent

TARGET = Path(__file__).with_name("substrate_fixtures.json")

ARTIFACTS = [
    (b"portable result", "text/plain", "evidence", ("operation", "local-process", "opaque")),
    (b"", "application/x-tar", "handoff", ("op", "docker", "id")),
    (bytes(range(256)), "application/octet-stream; q=\"1\"", "café \U0001f600", ("opé", "gondolin", "lease\\id")),
]

KEYS = [
    "",
    "secret",
    "SECRET_KEY",
    "github_token",
    "Password",
    "credentials",
    "Authorization",
    "auth_headers",
    "authheader",
    "auth-Headers",
    "auth\nheaders",
    "auth__headers",
    "cookie",
    "private_key",
    "privatekey",
    "private--key",
    "process_env",
    "process.env",
    "reasoning",
    "safe",
    "note",
    "tok",
    "ıd_token",
    "paſſword",
    "KEY",
    "privateKey",
]

VALUES = [
    "plain text",
    "Bearer raw",
    "bearer   abc.def~ghi+jkl/mno=pqr-stu tail",
    "BEARER\tTOKEN123",
    "Bearer ",
    "Bearer\n",
    "xbearer token",
    "credential sk-or-secretvalue must not survive",
    "sk-or-abc",
    "sk-abcdefgh",
    "sk-abcdefg",
    "sk-or-abcdefg",
    "ghp_12345678",
    "GHS_ABCDEFGHIJ more",
    "gho_short",
    "ghx_12345678",
    "github_pat_ABCDEFGH_12345",
    "GitHub_PAT_abcdefgh",
    "two sk-11111111 and ghu_22222222 secrets",
    "Bearer abc",
    "Bearer ſK",
    "sk-ſſſſſſſſ",
    "café \U0001f600",
]

METADATA = [
    {"nested": {"password": "raw", "safe": "visible"}, "auth_headers": {"Authorization": "Bearer raw"}},
    {"list": ["Bearer abc", {"token": 1}, [None, True, 1.5, "ghp_12345678"]], "count": 3, "ratio": 0.1},
    {"unicode": "café \U0001f600  ", "empty": {}, "none": None, "big": 10**30},
]

TELEMETRY = [
    {
        "event": "impetus_worker_activity_finished",
        "instance": "instance-1",
        "occurrence": 9,
        "attempt": "attempt-1",
        "epoch": 2,
        "worker": "worker-1",
        "outcome": "completed",
        "authorization": "Bearer secret-value",
        "note": "credential sk-or-secretvalue must not survive",
        "ts": 1,
    },
    {"event": "safe"},
    {"event": "x_started", "status": "running", "run_id": None, "queue": "", "net": True, "head": 1.5},
    {"event": "x_failed", "outcome": None, "operation": {"a": [1, "b"]}, "repository": [1, 2]},
    {"event": "x_heartbeat", "ts": "t", "lease_id": "l", "metadata_only": {"cookie": "c"}},
    {"event": "x_claimed", "outcome": 3, "event_extra": "e"},
    {"event": 5},
    ["event", "list"],
]

TIMES = [
    datetime(2026, 10, 10, 12, 34, 56, 123456, tzinfo=UTC),
    datetime(2026, 1, 2, 3, 4, 5, tzinfo=UTC),
    datetime(999, 12, 31, 23, 59, 59, 1, tzinfo=UTC),
]


def artifact_cases(root: Path) -> list[dict]:
    store = ArtifactStore(root)
    cases = []
    for data, media_type, retention, producer in ARTIFACTS:
        reference = store.put(data, media_type=media_type, retention_class=retention, producer=ProducerCorrelation(*producer))
        metadata = (root / reference.digest[:2] / f"{reference.digest}.json").read_bytes()
        cases.append(
            {
                "data_hex": data.hex(),
                "media_type": media_type,
                "retention_class": retention,
                "producer": list(producer),
                "digest": reference.digest,
                "metadata": metadata.decode(),
            }
        )
    return cases


def event_lines(root: Path) -> list[dict]:
    cases = []
    for index, (observed, metadata) in enumerate(zip(TIMES, METADATA)):
        path = root / f"timeline-{index}.jsonl"
        event = TimelineEvent(
            f"event-{index}",
            "execution.finished",
            1,
            "worker",
            1,
            observed,
            "execute",
            "succeeded",
            {"operation_id": "op", "token": "abc", "note": "Bearer xyz"},
            ("cause", "café"),
            metadata,
            "short-lived",
        )
        Timeline(path).append(event)
        cases.append(
            {
                "event_id": event.event_id,
                "observed_at": observed.isoformat(),
                "metadata": metadata,
                "line": path.read_text(),
            }
        )
    return cases


def telemetry_cases(root: Path) -> list[dict]:
    cases = []
    for index, payload in enumerate(TELEMETRY):
        path = root / f"telemetry-{index}.jsonl"
        handler = TelemetryTimelineHandler(Timeline(path))
        message = json.dumps(payload)
        handler.emit(logging.LogRecord("impetus.telemetry", logging.INFO, __file__, 1, message, (), None))
        record = json.loads(path.read_text()) if path.exists() else None
        if record is not None:
            del record["event_id"], record["observed_at"]
        cases.append({"message": message, "record": record})
    return cases


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        fixtures = {
            "artifacts": artifact_cases(root / "artifacts"),
            "secret_keys": [{"key": key, "secret": bool(timeline_module._SECRET.search(key))} for key in KEYS],
            "secret_values": [
                {"value": value, "redacted": timeline_module._SECRET_VALUE.sub("[REDACTED]", value)} for value in VALUES
            ],
            "events": event_lines(root),
            "telemetry": telemetry_cases(root),
            "phases": {
                kind: timeline_module._phase(kind)
                for kind in ("a_started", "a_finished", "a_accepted", "a_claimed", "a_heartbeat", "a_completed",
                             "a_failed", "a_destroyed", "started", "a_started_x", "")
            },
        }
    TARGET.write_text(json.dumps(fixtures, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
