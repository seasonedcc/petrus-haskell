"""Time the reference Pi A2 host on the workload of ``bench/PiA2Bench.hs``.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-runtime/bench/python_pi_a2.py

Each line prints the median per-operation time over 7 batches, after one
warm-up call.
"""

from __future__ import annotations

import itertools
import statistics
import tempfile
import time
from hashlib import sha256
from pathlib import Path

from petrus.agenticus.connection.custody import ConnectionIdentity
from petrus.agenticus.connection.key import KeyErasureEvidence
from petrus.agenticus.hands.contract import ToolMethod
from petrus.agenticus.runtime.pi_a2_host import (
    PiA2DirectAuthority,
    PiA2RuntimeHostConfig,
    PiA2RuntimePolicy,
    PiA2RuntimeStart,
    PiA2ScriptedTurn,
    _compose_pi_a2_scripted_client_runtime,
    _pi_a2_durable_fingerprint,
    _ScriptedClient,
)
from petrus.agenticus.thread.identity import EpisodeId, TurnId
from petrus.agenticus.thread.lifecycle import TurnOutcome
from petrus.motus.execution.archive import workspace_archive


class Keys:
    """Reversible stand-in keys shared with the twin."""

    def seal(self, context, plaintext: bytearray) -> bytes:
        return b"sealed:" + bytes(plaintext)

    def open(self, context, ciphertext: bytes) -> bytearray:
        return bytearray(ciphertext[7:])

    def erase(self, connection_id: str) -> KeyErasureEvidence:
        return KeyErasureEvidence(connection_id, True)


class Forever:
    """An unbounded ``_ScriptedFactory``."""

    def create(self, **kwargs):
        return _ScriptedClient(PiA2ScriptedTurn("answer"), kwargs["prior"])


def start_for(archive: bytes, name: str) -> PiA2RuntimeStart:
    digest = sha256(archive).hexdigest()
    return PiA2RuntimeStart(
        name,
        EpisodeId(f"episode-{name}"),
        TurnId(f"turn-{name}"),
        "prompt",
        archive,
        digest,
        f"bench-tree-{digest}",
        PiA2RuntimePolicy(frozenset(ToolMethod), frozenset({"output.txt"}), 8),
    )


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
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        (root / "working").mkdir()
        (root / "working" / "input.txt").write_text("input")
        archive = workspace_archive(root / "working")
        config = PiA2RuntimeHostConfig(
            state_root=root / "state",
            working_directory=root / "working",
            provider="anthropic",
            model="claude-sonnet-4-5",
            host_id="bench-host",
            capabilities=frozenset(ToolMethod),
            allowed_argv=frozenset({("/usr/bin/true",)}),
            test_command=("/usr/bin/true",),
            max_tool_calls=8,
            attachment_timeout=20,
            command_timeout=5,
            credential_ttl=30,
            wall_timeout=10,
            cancellation_grace=1,
        )
        authority = PiA2DirectAuthority(
            ConnectionIdentity("direct", "anthropic", "account", "api-key"),
            Keys(),
            lambda: bytearray(b"bench-api-key"),
        )
        start = start_for(archive, "operation")
        inner = "a" * 64
        timed("pi-a2-fingerprint", lambda: _pi_a2_durable_fingerprint(config, start, inner), per_batch=2000)
        host = _compose_pi_a2_scripted_client_runtime(config=config, authority=authority, client_factory=Forever())
        host.scripted_readiness()
        counter = itertools.count()

        def scripted_turn() -> None:
            operation = host.start(start_for(archive, f"op-{next(counter)}"))
            settlement = operation.wait(5)
            operation.close()
            assert settlement.outcome is TurnOutcome.COMPLETED, settlement

        try:
            timed("pi-a2-scripted-turn", scripted_turn, per_batch=20)
        finally:
            host.close()


if __name__ == "__main__":
    main()
