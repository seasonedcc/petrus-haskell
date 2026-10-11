"""Whole Codex, Claude and Amp Turns on the pinned reference hosts.

The twins of ``bench/TurnsBench.hs``. Run by scripts/bench and
scripts/bench-compare with the pinned interpreter
(``scripts/upstream-python``), from ``upstream/petrus``. Prints one
``name,nanoseconds`` line per benchmark (scripts/bench_timing.py), named like
the Haskell benchmarks.

Each row takes one Turn through the reference's own adapter, against the same
fakes the Haskell side uses (``test/fixtures``), with a fresh operation id
every call:

* ``codex-turn``: open a Local Motus territory and its Episode Attachment,
  ``start`` (real ``AgentConnectionCustody`` over a SQLite ledger: materialize
  and activate; the fake ``codex`` CLI and the private helper's ``collect``
  run as subprocesses; checkpoint and admission), ``wait``, ``close``, and
  settle the attachment (archive export and lease cleanup).
* ``claude-turn``: open a Local Motus territory, its Episode Attachment, the
  Hands gateway and a grant, then ``start`` (custody materialization, the
  official ``ClaudeSDKClient`` of the fake ``claude_agent_sdk``: its
  PreToolUse hook twice, one ``workspace_read`` through the gateway, the
  session store's ``append``, three messages), ``wait``, ``close``, and settle
  the attachment.
* ``amp-turn``: an Episode Attachment over the provider-managed binding, then
  ``start`` (the official ``execute`` of the fake ``amp_sdk``: ``system/init``,
  an assistant event and the ``success`` result), ``wait``, ``close``, and
  settle the attachment.

The connection keys are reversible stand-ins on both sides, so the cipher is
not measured.
"""

from __future__ import annotations

import itertools
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parent
FIXTURES = PACKAGE / "test" / "fixtures"
sys.path.insert(0, str(PACKAGE.parent.parent / "scripts"))
sys.path[1:1] = [str(FIXTURES / "amp"), str(FIXTURES / "claude")]
from bench_timing import report  # noqa: E402

from petrus.agenticus.attachment.binding import MotusAttachmentBinding  # noqa: E402
from petrus.agenticus.attachment.episode import EpisodeAttachment  # noqa: E402
from petrus.agenticus.catalog.descriptor import CapabilityDescriptor, DescriptorIdentity, DescriptorKind  # noqa: E402
from petrus.agenticus.catalog.resolution import ResolutionSnapshot  # noqa: E402
from petrus.agenticus.connection.custody import (  # noqa: E402
    AgentConnectionCustody,
    AttachmentFence,
    ConnectionIdentity,
    ConnectionStatus,
    ConnectionView,
    LeaseMode,
    Materialization,
    OpaqueState,
    AdmissionResult,
    CleanupEvidence,
    ReleaseResult,
)
from petrus.agenticus.connection.key import KeyErasureEvidence  # noqa: E402
from petrus.agenticus.connection.materialization import PrivateFileMaterializer  # noqa: E402
from petrus.agenticus.connection.storage import SqliteConnectionStorage  # noqa: E402
from petrus.agenticus.hands.contract import ToolMethod  # noqa: E402
from petrus.agenticus.hands.workspace import MotusWorkspaceAdapter  # noqa: E402
from petrus.agenticus.runtime import amp, claude, codex  # noqa: E402
from petrus.agenticus.runtime.installation import ProbeDisposition  # noqa: E402
from petrus.agenticus.runtime.profiles import AMP_A1, CLAUDE_A2_LOCAL, CODEX_A2_LOCAL  # noqa: E402
from petrus.agenticus.thread.identity import EpisodeId, TurnId  # noqa: E402
from petrus.agenticus.thread.lifecycle import TurnOutcome  # noqa: E402
from petrus.motus.execution import EnvironmentCapability, EnvironmentSpec  # noqa: E402
from petrus.motus.execution.archive import workspace_archive  # noqa: E402
from petrus.motus.execution.providers import LocalProcessEnvironment  # noqa: E402

HOST_FENCED_EFFECT = CapabilityDescriptor(
    DescriptorIdentity(DescriptorKind.EFFECT, "host.fenced", 1),
    frozenset({"effect.host-fenced"}),
)
AUTH = b"bench-auth-state"


class Keys:
    """Reversible stand-in keys shared with the twin."""

    def seal(self, context, plaintext: bytearray) -> bytes:
        return b"sealed:" + bytes(plaintext)

    def open(self, context, ciphertext: bytes) -> bytearray:
        return bytearray(ciphertext[7:])

    def erase(self, connection_id: str) -> KeyErasureEvidence:
        return KeyErasureEvidence(connection_id, True)


class Store:
    """Continuations and Turns kept in memory, keyed by operation."""

    def __init__(self, prefix: str) -> None:
        self.prefix = prefix
        self.values: dict[str, object] = {}

    def store(self, operation_id: str, payload) -> str:
        reference = f"{self.prefix}-continuation-{operation_id}"
        self.values[reference] = payload
        return reference

    def load(self, state_reference: str):
        return self.values[state_reference]

    def store_turn(self, operation_id: str, *values) -> str:
        reference = f"{self.prefix}-turn-{operation_id}"
        self.values[reference] = values
        return reference


def completed(settlement) -> None:
    assert settlement.outcome is TurnOutcome.COMPLETED, settlement


def settled(attachment: EpisodeAttachment) -> None:
    assert attachment.settle(drain_timeout=5).settlement.verified


# ---------------------------------------------------------------------------
# Codex


def codex_turn(root: Path):
    executable = root / "codex"
    template = (FIXTURES / "codex" / "fake_codex.py").read_text()
    executable.write_text(template.replace("__PYTHON__", sys.executable).replace("__VERSION__", codex.CODEX_VERSION))
    executable.chmod(0o755)
    os.environ["PATH"] = os.pathsep.join([str(root), os.environ.get("PATH", "")])
    installation = root / "installation"
    installation.mkdir(mode=0o700)
    storage = SqliteConnectionStorage(installation / "connections.sqlite3")
    custody = AgentConnectionCustody(
        storage, Keys(), PrivateFileMaterializer(installation / "materialized"), clock=time.monotonic
    )
    custody.enroll_host("host-1", operation_id="enroll-codex-host")
    custody.authorize(
        ConnectionIdentity("codex-bench", "codex", "safe-account", "file-auth"),
        OpaqueState(AUTH),
        operation_id="authorize-codex",
    )
    store = Store("codex")
    adapter = codex.CodexRuntimeAdapter(
        codex.CodexRuntimeConfig("host-1", credential_ttl=10, command_timeout=10, cancellation_grace=1),
        codex.CodexContinuationCodec(store),
        store,
        custody,
    )
    assert adapter.probe().disposition is ProbeDisposition.READY
    selected = ResolutionSnapshot(
        1,
        (
            CODEX_A2_LOCAL,
            codex.CODEX_CONNECTION_CAPABILITIES,
            codex.CODEX_PROGRAM_CAPABILITIES,
            codex.CODEX_COLLOCATED_HANDS,
            codex.CODEX_LOCAL_TERRITORY,
            codex.CODEX_CONTINUATION_CAPABILITIES,
            HOST_FENCED_EFFECT,
        ),
    )
    source = root / "workspace"
    source.mkdir()
    archive = workspace_archive(source)
    spec = EnvironmentSpec(required_capabilities=frozenset({EnvironmentCapability.PRIVATE_FILE_TRANSFER.value}))
    provider = LocalProcessEnvironment()
    counter = itertools.count()

    def turn() -> None:
        n = next(counter)
        binding = MotusAttachmentBinding.open(
            provider, f"territory-{n}", spec, workspace_archive_bytes=archive, input_digest=f"input-{n}"
        )
        attachment = EpisodeAttachment(
            episode_id=EpisodeId(f"episode-{n}"),
            snapshot=selected,
            binding=binding,
            attachment_id=f"attachment-{n}",
            deadline=time.monotonic() + 30,
        )
        operation = adapter.start(
            codex.CodexRuntimeInvocation(
                f"operation-{n}",
                attachment.episode_id,
                TurnId(f"turn-{n}"),
                "first",
                custody.connection("codex-bench"),
                attachment,
            )
        )
        completed(operation.wait(30))
        assert operation.close().verified
        settled(attachment)

    return turn, storage.close


# ---------------------------------------------------------------------------
# Claude


class ClaudeHome:
    def read(self) -> bytes:
        return b"sk-ant-api03-bench"


class ClaudeCustody:
    """The reference test's fake custody: one READ lease per Turn."""

    def view(self) -> ConnectionView:
        return ConnectionView(
            ConnectionIdentity("claude-connection", "claude", "safe-account", "api-key"),
            ConnectionStatus.READY,
            3,
            4,
            None,
        )

    def materialize(self, connection_id, host_id, *, mode, ttl, operation_id) -> Materialization:
        fence = AttachmentFence("connection-attachment", "connection-lease", connection_id, host_id, 1, 3, 4)
        return Materialization(fence, LeaseMode.READ, time.monotonic() + ttl, ClaudeHome())

    def admit_result(self, fence: AttachmentFence, *, operation_id: str) -> AdmissionResult:
        return AdmissionResult(operation_id, "result", fence.attachment_id)

    def release(self, materialization: Materialization, *, operation_id: str) -> ReleaseResult:
        return ReleaseResult(operation_id, CleanupEvidence(materialization.fence.attachment_id, True, False, 18))


def claude_turn(root: Path):
    working = root / "project"
    working.mkdir()
    runtime_root = root / "runtime"
    runtime_root.mkdir(mode=0o700)
    runtime_root.chmod(0o700)
    store = Store("claude")
    custody = ClaudeCustody()
    adapter = claude.ClaudeRuntimeAdapter(
        claude.ClaudeRuntimeConfig(
            "claude-sonnet-4-5",
            working,
            runtime_root,
            host_id="host-1",
            credential_ttl=10,
            wall_timeout=30,
            cancellation_grace=5,
        ),
        claude.ClaudeContinuationCodec(store),
        store,
        custody,
    )
    assert adapter.probe().disposition is ProbeDisposition.READY
    selected = ResolutionSnapshot(
        1,
        (
            CLAUDE_A2_LOCAL,
            claude.CLAUDE_CONNECTION_CAPABILITIES,
            claude.CLAUDE_PROGRAM_CAPABILITIES,
            claude.CLAUDE_COLLOCATED_HANDS,
            claude.CLAUDE_LOCAL_TERRITORY,
            claude.CLAUDE_CONTINUATION_CAPABILITIES,
            HOST_FENCED_EFFECT,
        ),
    )
    source = root / "workspace"
    source.mkdir()
    (source / "marker.txt").write_text("workspace-marker")
    archive = workspace_archive(source)
    provider = LocalProcessEnvironment()
    counter = itertools.count()

    def turn() -> None:
        n = next(counter)
        binding = MotusAttachmentBinding.open(
            provider, f"territory-{n}", EnvironmentSpec(), workspace_archive_bytes=archive, input_digest=f"input-{n}"
        )
        episode = EpisodeId(f"episode-{n}")
        attachment = EpisodeAttachment(
            episode_id=episode,
            snapshot=selected,
            binding=binding,
            attachment_id=f"attachment-{n}",
            deadline=time.monotonic() + 30,
        )
        gateway = attachment.gateway(MotusWorkspaceAdapter(provider, binding.execution, test_command=("/bin/true",)))
        grant = attachment.grants().open(
            tuple(ToolMethod),
            writable_paths=("output.txt",),
            allowed_argv=(("/bin/true",),),
            deadline=attachment.deadline,
            max_calls=16,
        )
        operation = adapter.start(
            claude.ClaudeRuntimeInvocation(
                f"operation-{n}",
                episode,
                TurnId(f"turn-{n}"),
                "prompt",
                custody.view(),
                attachment,
                gateway,
                grant.grant_epoch,
            )
        )
        completed(operation.wait(30))
        assert operation.close().verified
        settled(attachment)

    return turn, lambda: None


# ---------------------------------------------------------------------------
# Amp


def amp_turn(root: Path):
    cli = root / "amp"
    cli.write_text(
        "#!/bin/sh\n"
        f'if [ "$1" = --version ]; then echo "{amp.AMP_CLI_VERSION} (bench)"; '
        'else echo "--orb-execute --project --stream-json"; fi\n'
    )
    cli.chmod(0o755)
    os.environ["AMP_CLI_PATH"] = str(cli)
    store = Store("amp")
    adapter = amp.AmpRuntimeAdapter(amp.AmpRuntimeConfig("bench/project"), amp.AmpContinuationCodec(store), store)
    assert adapter.probe().disposition is ProbeDisposition.READY
    selected = ResolutionSnapshot(
        1,
        (
            AMP_A1,
            amp.AMP_CONNECTION_CAPABILITIES,
            amp.AMP_PROGRAM_CAPABILITIES,
            amp.AMP_PROVIDER_MANAGED_HANDS,
            amp.AMP_PROVIDER_MANAGED_TERRITORY,
            amp.AMP_CONTINUATION_CAPABILITIES,
            HOST_FENCED_EFFECT,
        ),
    )
    connection = ConnectionView(
        ConnectionIdentity("amp-connection", "amp", "safe-account-fingerprint", "platform-managed"),
        ConnectionStatus.READY,
        3,
        4,
        None,
    )
    counter = itertools.count()

    def turn() -> None:
        n = next(counter)
        episode = EpisodeId(f"episode-{n}")
        attachment = EpisodeAttachment(
            episode_id=episode,
            snapshot=selected,
            binding=amp.AmpProviderManagedBinding(),
            attachment_id=f"attachment-{n}",
            deadline=time.monotonic() + 30,
        )
        operation = adapter.start(
            amp.AmpRuntimeInvocation(f"operation-{n}", episode, TurnId(f"turn-{n}"), "prompt", connection, attachment)
        )
        completed(operation.wait(30))
        assert operation.close().verified
        settled(attachment)

    return turn, lambda: None


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="petrus-turns-bench-") as raw:
        root = Path(raw).resolve()
        for name, build in (("codex-turn", codex_turn), ("claude-turn", claude_turn), ("amp-turn", amp_turn)):
            directory = root / name
            directory.mkdir()
            turn, close = build(directory)
            try:
                report(name, turn)
            finally:
                close()


if __name__ == "__main__":
    main()
