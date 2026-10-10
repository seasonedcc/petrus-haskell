"""Time the reference Pi native runtime hot paths on the workload of ``bench/PiBench.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_pi.py

Each line prints the median per-operation time over 7 batches, after one
warm-up call.
"""

from __future__ import annotations

import base64
import itertools
import json
import statistics
import tempfile
import time
from pathlib import Path

import petrus.agenticus.runtime.pi as pi
from petrus.agenticus.connection.custody import ConnectionIdentity
from petrus.agenticus.runtime.operation import RuntimeCleanupDisposition, RuntimeOperationCleanup
from petrus.agenticus.runtime.pi_recovery import SqlitePiOperationLedger
from petrus.agenticus.runtime.result import RuntimeTurnSettlement
from petrus.agenticus.thread.identity import EpisodeId, TurnId
from petrus.agenticus.thread.lifecycle import TurnOutcome

CORPUS = Path(__file__).resolve().parent.parent / "differential" / "pi_corpus.json"
SESSION_ID = "11111111-1111-4111-8111-111111111111"
TOOL_CALL = b'{"type":"tool_call","id":"call-1","method":"workspace_read","params":{"path":"README.md"}}'
SESSION = (
    b'{"type":"session","version":3,"id":"' + SESSION_ID.encode() + b'"}\n'
    + b"".join(
        b'{"type":"message","id":"m' + str(i).encode()
        + b'","role":"assistant","content":[{"type":"text","text":"hello \\u00e9 world"}]}\n'
        for i in range(1, 200)
    )
)


def start_frame() -> dict[str, object]:
    """The resumed, all-tools api-key ``start`` frame of the corpus, as sent."""
    corpus = json.loads(CORPUS.read_text())
    raw = base64.b64decode(corpus["frames"]["starts"][1]["frame"]["ok"])
    return json.loads(raw)


def encode(frame: dict[str, object]) -> bytes:
    """``_SubprocessClient._write``'s encoding."""
    return json.dumps(frame, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode() + b"\n"


def fingerprint() -> str:
    return pi.pi_durable_work_fingerprint(
        CONFIG,
        EpisodeId("episode"),
        TurnId("turn"),
        "pi-prompt-canary-never-render",
        ConnectionIdentity("connection", "provider", "account", "api-key"),
        None,
    )


def ledger_cycle(ledger: SqlitePiOperationLedger, counter: itertools.count) -> None:
    n = next(counter)
    operation = f"op-{n}"
    episode, turn = EpisodeId("episode"), TurnId(f"turn-{n}")
    ledger.admit(operation, "a" * 64, episode, turn)
    ledger.settle(
        operation,
        RuntimeTurnSettlement(episode, turn, TurnOutcome.COMPLETED, 1, "turn-completed", "output", "continuation"),
    )
    ledger.upgrade_cleanup(
        operation, RuntimeOperationCleanup(operation, RuntimeCleanupDisposition.CLEAN, "cleanup-verified", False)
    )
    ledger.acknowledge(operation)
    assert ledger.lookup(operation) is not None


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


CONFIG: pi.PiRuntimeConfig


def main() -> None:
    global CONFIG
    frame = start_frame()
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        (root / "working").mkdir()
        (root / "private").mkdir(mode=0o700)
        CONFIG = pi.PiRuntimeConfig("provider", "model", root / "working", root / "private")
        ledger = SqlitePiOperationLedger(root / "ledger" / "operations.sqlite3")
        counter = itertools.count()
        try:
            timed("pi-start-frame-encode", lambda: encode(frame), per_batch=2000)
            timed("pi-tool-call-decode", lambda: pi._strict_load(TOOL_CALL), per_batch=20000)
            timed("pi-session-validate", lambda: pi._validate_session(SESSION, SESSION_ID, 4_000_000, 10_000))
            timed("pi-fingerprint", fingerprint, per_batch=2000)
            timed("pi-ledger-cycle", lambda: ledger_cycle(ledger, counter))
        finally:
            ledger.close()


if __name__ == "__main__":
    main()
