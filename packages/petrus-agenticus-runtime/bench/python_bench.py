"""Whole Codex, Claude, Amp and Pi Turns on the pinned reference hosts, and
the Codex A3 runtime service's round trip.

The twins of ``bench/TurnsBench.hs`` and ``bench/PiTurnsBench.hs``. Run by scripts/bench and
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
* ``codex-a3-service-turn``: the A3 lane end to end over its host-local
  runtime service: open a Gondolin Motus territory (the fake Gondolin SDK
  ``test/fixtures/codex/fake_gondolin_codex.mjs``, whose guest commands run on
  the host) and its Episode Attachment, probe the guest ``codex``, start the
  service on a fresh private state directory under the platform's temporary
  directory (``TMPDIR``, else ``/tmp``; the Unix socket path in it must stay
  within 104 bytes on macOS, 108 on Linux): its fence and SQLite replay
  ledger; send one request through the Worker-side Activity client over the
  Unix socket (the service records the operation, runs one Codex Turn with
  the same custody as ``codex-turn``, stores and replies the terminal), close
  the service, remove its state directory, and settle the attachment.
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
* ``pi-native-turn``: the native A2 adapter: open a Local Motus territory,
  its Episode Attachment, the Hands gateway and a grant, then ``start``
  (custody materialization, ``pi_helper.mjs`` under real ``node`` over the
  fake SDK ``test/fixtures/pi/framed_tool_sdk.mjs``: one ``workspace_read``
  through the gateway, the session file and the candidate), ``wait``,
  ``close``, and settle the attachment.
* ``pi-a5-turn``: the A5 application adapter on a ``gondolin`` territory (a
  Local Motus provider whose leases report ``gondolin``, as the reference's
  tests do): ``pi_application_helper.mjs`` over the fake
  ``application_coding.mjs``, ``application_core_projection.mjs`` and
  ``application_ai.mjs``, one ``workspace_read`` through the gateway, then
  ``wait``, ``close`` and settle.
* ``pi-model-phase-turn``: one model-phase Activity call: custody
  materialization, ``pi_model_phase_helper.mjs`` over the fake
  ``model_phase_coding.mjs`` (one public stream, five tool declarations),
  candidate validation, admission, release and publication.

The Pi rows use the reference tests' fake custody (one READ lease per
Turn), and assign the adapters' installation the way those tests do
(``_installation``, ``_node``, ...): the helpers run for real, but no
installed SDK is probed.

The connection keys are reversible stand-ins on both sides, so the cipher is
not measured.
"""

from __future__ import annotations

import itertools
import json
import os
import shutil
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
from petrus.agenticus.program.agent_net import (  # noqa: E402
    MODEL_PHASE_ACTIVITY,
    LoopState,
    ModelSettlement,
    StopReason,
)
from petrus.agenticus.runtime import amp, claude, codex, pi  # noqa: E402
from petrus.agenticus.runtime._codex_gondolin_service import (  # noqa: E402
    _ACTIVITY,
    _CodexGondolinActivityClient,
    _CodexGondolinRuntimeService,
)
from petrus.agenticus.runtime import pi_application as app  # noqa: E402
from petrus.agenticus.runtime import pi_model_phase as phase  # noqa: E402
from petrus.agenticus.runtime.installation import InstalledComponent, ProbeDisposition, RuntimeInstallation  # noqa: E402
from petrus.agenticus.runtime.profiles import (  # noqa: E402
    AMP_A1,
    CLAUDE_A2_LOCAL,
    CODEX_A2_LOCAL,
    CODEX_A3_GONDOLIN,
    PI_APPLICATION_A5_GONDOLIN,
    PI_NATIVE_A2_LOCAL,
)
from petrus.agenticus.thread.identity import EpisodeId, TurnId  # noqa: E402
from petrus.agenticus.thread.lifecycle import TurnOutcome  # noqa: E402
from petrus.motus.activity import ActivityInvocation, ExecutionPolicy  # noqa: E402
from petrus.motus.execution import EnvironmentCapability, EnvironmentSpec  # noqa: E402
from petrus.motus.execution.archive import workspace_archive  # noqa: E402
from petrus.motus.execution.gondolin import GondolinEnvironment  # noqa: E402
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


def fake_codex(root: Path, version: str) -> Path:
    """The fake ``codex`` CLI at ``version``, written to ``root``."""
    executable = root / "codex"
    template = (FIXTURES / "codex" / "fake_codex.py").read_text()
    executable.write_text(template.replace("__PYTHON__", sys.executable).replace("__VERSION__", version))
    executable.chmod(0o755)
    return executable


def codex_custody(root: Path) -> tuple[AgentConnectionCustody, SqliteConnectionStorage]:
    """Real custody over a SQLite ledger with the ``codex-bench`` connection authorized."""
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
    return custody, storage


def codex_turn(root: Path):
    fake_codex(root, codex.CODEX_VERSION)
    os.environ["PATH"] = os.pathsep.join([str(root), os.environ.get("PATH", "")])
    custody, storage = codex_custody(root)
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
# Codex A3 runtime service


class ActivityContext:
    attempt_id = "activity-attempt"
    epoch = "1"
    claimant = "host"

    def heartbeat(self, *, details=None) -> object:
        return details


def codex_a3_service_turn(root: Path):
    executable = fake_codex(root, codex.CODEX_GONDOLIN_VERSION)
    architecture = root / "fake-uname"
    architecture.write_text("#!/bin/sh\nprintf aarch64\n")
    architecture.chmod(0o755)
    sdk = root / "fake-gondolin-codex.mjs"
    sdk.write_text(
        (FIXTURES / "codex" / "fake_gondolin_codex.mjs")
        .read_text()
        .replace("__CODEX__", json.dumps(str(executable)))
        .replace("__UNAME__", json.dumps(str(architecture)))
        .replace("__STARTED__", json.dumps(str(root / "fake-codex-command-started")))
    )
    custody, storage = codex_custody(root)
    store = Store("codex")
    adapter = codex.CodexGondolinRuntimeAdapter(
        codex.CodexRuntimeConfig("host-1", credential_ttl=10, command_timeout=10, cancellation_grace=2),
        codex.CodexContinuationCodec(store),
        store,
        custody,
    )
    provider = GondolinEnvironment(root / "gondolin", sdk_module=str(sdk), lease_ttl=30)
    spec = EnvironmentSpec(
        image="fake-image",
        required_capabilities=frozenset(
            {
                EnvironmentCapability.VM.value,
                EnvironmentCapability.MICROVM.value,
                EnvironmentCapability.PRIVATE_FILE_TRANSFER.value,
            }
        ),
    )
    selected = ResolutionSnapshot(
        1,
        (
            CODEX_A3_GONDOLIN,
            codex.CODEX_CONNECTION_CAPABILITIES,
            codex.CODEX_PROGRAM_CAPABILITIES,
            codex.CODEX_COLLOCATED_HANDS,
            codex.CODEX_GONDOLIN_TERRITORY,
            codex.CODEX_CONTINUATION_CAPABILITIES,
            HOST_FENCED_EFFECT,
        ),
    )
    token = "t" * 32
    client = _CodexGondolinActivityClient()
    context = ActivityContext()
    source = root / "workspace"
    source.mkdir()
    (source / "public-input.txt").write_text("public-workspace-canary")
    archive = workspace_archive(source)
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
        assert adapter.probe(attachment).disposition is ProbeDisposition.READY
        connection = custody.connection("codex-bench")
        state = Path(tempfile.mkdtemp(prefix="petrus-a3-"))
        endpoint = state / "runtime.sock"
        service = _CodexGondolinRuntimeService(
            endpoint, state / "runtime-ledger.db", token, adapter, connection, attachment
        )
        service.start()
        try:
            coordinates = attachment.coordinates()
            os.environ["PETRUS_CODEX_GONDOLIN_ENDPOINT"] = str(endpoint)
            os.environ["PETRUS_CODEX_GONDOLIN_TOKEN"] = token
            result = client(
                ActivityInvocation(
                    _ACTIVITY,
                    input={
                        "version": 1,
                        "episode_id": attachment.episode_id.to_data(),
                        "turn_id": f"turn-{n}",
                        "prompt": "first",
                        "attachment_id": coordinates.attachment_id,
                        "attachment_epoch": coordinates.attachment_epoch,
                        "connection_id": connection.identity.connection_id,
                        "authority_epoch": connection.authority_epoch,
                        "state_version": connection.state_version,
                        "continuation": None,
                    },
                    policy=ExecutionPolicy(),
                    idempotency=f"operation-{n}",
                ),
                context=context,
            )
        finally:
            try:
                service.close()
            finally:
                shutil.rmtree(state)
        assert result["outcome"] == "completed" and result["cleanup"]["disposition"] == "clean", result
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


# ---------------------------------------------------------------------------
# Pi


class PiHome:
    def __init__(self, secret: bytes) -> None:
        self.secret = secret

    def read(self) -> bytes:
        return self.secret

    def replace(self, value: bytes) -> None:
        pass


class PiCustody:
    """The reference tests' fake custody: one READ lease per Turn over a fixed secret."""

    def __init__(self, secret: bytes) -> None:
        self.secret = secret

    def materialize(self, connection_id, host_id, *, mode, ttl, operation_id) -> Materialization:
        fence = AttachmentFence("credential", "lease", connection_id, host_id, 1, 3, 4)
        return Materialization(fence, mode, time.monotonic() + ttl, PiHome(self.secret))

    def activate(self, materialization, *, operation_id) -> None:
        raise AssertionError("activate")

    def admit_result(self, fence: AttachmentFence, *, operation_id: str) -> AdmissionResult:
        return AdmissionResult(operation_id, "result", fence.attachment_id)

    def checkpoint(self, materialization, *, operation_id):
        raise AssertionError("checkpoint")

    def release(self, materialization: Materialization, *, operation_id: str) -> ReleaseResult:
        return ReleaseResult(
            operation_id, CleanupEvidence(materialization.fence.attachment_id, True, False, len(self.secret))
        )


def pi_view(provider: str) -> ConnectionView:
    return ConnectionView(
        ConnectionIdentity("connection", provider, "account", "api-key"), ConnectionStatus.READY, 3, 4, None
    )


def node_executable() -> str:
    node = shutil.which("node")
    if node is None:
        raise SystemExit("pi-*-turn benchmarks need node on PATH")
    return node


def pi_native_turn(root: Path):
    working, private = root / "working", root / "private"
    working.mkdir()
    private.mkdir(mode=0o700)
    private.chmod(0o700)
    store = Store("pi")
    adapter = pi.PiRuntimeAdapter(
        pi.PiRuntimeConfig(
            "provider",
            "model",
            working,
            private,
            host_id="host-1",
            credential_ttl=10,
            wall_timeout=30,
            cancellation_grace=2,
        ),
        pi.PiContinuationCodec(store),
        store,
        PiCustody(b"pi-key-canary-never-render"),
    )
    adapter._installation = RuntimeInstallation(
        adapter.descriptor.identity,
        1,
        (InstalledComponent("pi-coding-agent", pi.PI_SDK_VERSION, pi.PI_SDK_SOURCE),),
        "bench",
        "bench",
    )
    adapter._node = node_executable()
    adapter._sdk_entrypoint = str(FIXTURES / "pi" / "framed_tool_sdk.mjs")
    adapter._factory = pi._SubprocessFactory(Path(pi.__file__).with_name("pi_helper.mjs"))
    selected = ResolutionSnapshot(
        1,
        (
            PI_NATIVE_A2_LOCAL,
            pi.PI_CONNECTION_CAPABILITIES,
            pi.PI_PROGRAM_CAPABILITIES,
            pi.PI_COLLOCATED_HANDS,
            pi.PI_LOCAL_TERRITORY,
            pi.PI_CONTINUATION_CAPABILITIES,
            HOST_FENCED_EFFECT,
        ),
    )
    source = root / "workspace"
    source.mkdir()
    (source / "marker.txt").write_text("marker")
    archive = workspace_archive(source)
    provider = LocalProcessEnvironment()
    view = pi_view("provider")
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
            pi.PiRuntimeInvocation(
                f"operation-{n}",
                episode,
                TurnId(f"turn-{n}"),
                "prompt",
                view,
                attachment,
                gateway,
                grant.grant_epoch,
            )
        )
        completed(operation.wait(30))
        assert operation.close().verified
        settled(attachment)

    return turn, lambda: None


class ApplicationStore:
    """Application Continuations and steps kept in memory."""

    def __init__(self) -> None:
        self.values: dict[str, object] = {}

    def store(self, operation_id: str, payload) -> str:
        reference = f"pi-application-continuation-{operation_id}"
        self.values[reference] = payload
        return reference

    def load(self, state_reference: str):
        return self.values[state_reference]

    def store_turn(self, operation_id: str, payload) -> str:
        return f"pi-application-turn-{operation_id}"


def pi_a5_turn(root: Path):
    working, runtime = root / "working", root / "runtime"
    working.mkdir()
    runtime.mkdir(mode=0o700)
    runtime.chmod(0o700)
    store = ApplicationStore()
    adapter = app.PiApplicationRuntimeAdapter(
        app.PiApplicationRuntimeConfig(
            "anthropic",
            "claude-sonnet-4-5",
            "gondolin",
            working,
            runtime,
            host_id="host-1",
            wall_timeout=30,
            cancellation_grace=2,
        ),
        app.PiApplicationContinuationCodec(store),
        store,
        PiCustody(b"credential-canary"),
    )
    adapter._installation = RuntimeInstallation(
        adapter.descriptor.identity, 1, (InstalledComponent("pi-agent-core", "0.83.0", "bench"),), "bench", "bench"
    )
    adapter._node = node_executable()
    adapter._coding = str(FIXTURES / "pi" / "application_coding.mjs")
    adapter._core = str(FIXTURES / "pi" / "application_core_projection.mjs")
    adapter._ai = str(FIXTURES / "pi" / "application_ai.mjs")
    adapter._factory = app._SubprocessFactory(Path(app.__file__).with_name("pi_application_helper.mjs"))
    selected = ResolutionSnapshot(
        1,
        (
            PI_APPLICATION_A5_GONDOLIN,
            app.PI_APPLICATION_CONNECTION_CAPABILITIES,
            app.PI_APPLICATION_PROGRAM_CAPABILITIES,
            app.PI_APPLICATION_HANDS,
            CapabilityDescriptor(
                DescriptorIdentity(DescriptorKind.TERRITORY, "motus.gondolin", 1), frozenset({"territory.gondolin"})
            ),
            app.PI_APPLICATION_CONTINUATION_CAPABILITIES,
            HOST_FENCED_EFFECT,
        ),
    )
    source = root / "workspace"
    source.mkdir()
    (source / "message.txt").write_text("before")
    archive = workspace_archive(source)
    view = pi_view("anthropic")
    counter = itertools.count()

    def turn() -> None:
        n = next(counter)
        # The reference tests' provider double, one per Attachment as there:
        # production Motus lifecycle and workspace, with the lease and the
        # provider reporting the qualified provider name.
        provider = LocalProcessEnvironment()
        binding = MotusAttachmentBinding.open(
            provider, f"territory-{n}", EnvironmentSpec(), workspace_archive_bytes=archive, input_digest=f"input-{n}"
        )
        object.__setattr__(binding.execution.lease, "provider", "gondolin")
        object.__setattr__(binding._lease, "provider", "gondolin")
        provider.provider = "gondolin"
        provider._leases[binding.lease_identity.operation_id] = binding._lease
        episode = EpisodeId(f"episode-{n}")
        attachment = EpisodeAttachment(
            episode_id=episode,
            snapshot=selected,
            binding=binding,
            attachment_id=f"attachment-{n}",
            deadline=time.monotonic() + 30,
        )
        gateway = attachment.gateway(MotusWorkspaceAdapter(provider, binding.execution, test_command=("/bin/true",)))
        grant = attachment.grants().open((ToolMethod.WORKSPACE_READ,), deadline=attachment.deadline, max_calls=8)
        operation = adapter.start(
            app.PiApplicationRuntimeInvocation(
                f"operation-{n}",
                episode,
                TurnId(f"turn-{n}"),
                "observation",
                view,
                attachment,
                gateway,
                grant.grant_epoch,
            )
        )
        completed(operation.wait(30))
        assert operation.close().verified
        settled(attachment)

    return turn, lambda: None


class PhaseOperations:
    def __init__(self) -> None:
        self.published = 0

    def load_continuation(self, reference):
        raise KeyError(reference)

    def publish(self, operation_id, output, continuation):
        self.published += 1
        return phase.PiModelPhasePublication(f"output-{operation_id}", f"continuation-{operation_id}")


class RealPhaseFactory:
    """The reference test's ``RealFactory``: the subprocess client, no probe."""

    def create(self, **kwargs):
        return phase._SubprocessFactory().create(**kwargs)


class PhaseContext:
    attempt_id = "attempt"

    def heartbeat(self, **_) -> None:
        return None


def pi_model_phase_turn(root: Path):
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    runtime.chmod(0o700)
    adapter = phase.PiModelPhaseAdapter(
        phase.PiModelPhaseConfig("anthropic", "claude-sonnet-4-5", "host-1", runtime, "episode", "turn", timeout=30),
        pi_view("anthropic"),
        PiCustody(b"credential-canary"),
        PhaseOperations(),
        node=node_executable(),
        sdk_entrypoint=str(FIXTURES / "pi" / "model_phase_coding.mjs"),
        client_factory=RealPhaseFactory(),
    )
    state = LoopState("episode", "turn", 1, 4, 0, 8, None, None, 1, ("workspace_read", "workspace_test"), ())
    context = PhaseContext()
    counter = itertools.count()

    def turn() -> None:
        n = next(counter)
        result = adapter(
            ActivityInvocation(MODEL_PHASE_ACTIVITY, input=state.to_data(), idempotency=f"operation-{n}"),
            context=context,
        )
        assert ModelSettlement.from_data(result).stop is StopReason.STOP

    return turn, lambda: None


def main() -> None:
    """Run every row, or only the rows named on the command line."""
    selected = set(sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="petrus-turns-bench-") as raw:
        root = Path(raw).resolve()
        for name, build in (
            ("codex-turn", codex_turn),
            ("codex-a3-service-turn", codex_a3_service_turn),
            ("claude-turn", claude_turn),
            ("amp-turn", amp_turn),
            ("pi-native-turn", pi_native_turn),
            ("pi-a5-turn", pi_a5_turn),
            ("pi-model-phase-turn", pi_model_phase_turn),
        ):
            if selected and name not in selected:
                continue
            directory = root / name
            directory.mkdir()
            turn, close = build(directory)
            try:
                report(name, turn)
            finally:
                close()


if __name__ == "__main__":
    main()
