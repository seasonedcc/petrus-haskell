"""The pinned reference's settlement of every ``raise:<scenario>`` stream.

Run by ``AmpSpec`` with the pinned interpreter from ``upstream/petrus``:
``python -I -c 'runpy…' amp-raising-reference.py FIXTURE_ROOT`` where
FIXTURE_ROOT is ``test/fixtures/amp`` (the fake ``amp_sdk``). Each scenario
is one Turn through upstream's own ``AmpRuntimeAdapter`` and its official
``execute``; it prints ``{scenario: [outcome, accepted_appends,
termination_code, cleanup_code]}`` as JSON.
"""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, sys.argv[1])

import amp_sdk  # noqa: E402

from petrus.agenticus.attachment.episode import EpisodeAttachment  # noqa: E402
from petrus.agenticus.catalog.descriptor import CapabilityDescriptor, DescriptorIdentity, DescriptorKind  # noqa: E402
from petrus.agenticus.catalog.resolution import ResolutionSnapshot  # noqa: E402
from petrus.agenticus.connection.custody import ConnectionIdentity, ConnectionStatus, ConnectionView  # noqa: E402
from petrus.agenticus.runtime import amp  # noqa: E402
from petrus.agenticus.runtime.installation import ProbeDisposition  # noqa: E402
from petrus.agenticus.runtime.profiles import AMP_A1  # noqa: E402
from petrus.agenticus.thread.identity import EpisodeId, TurnId  # noqa: E402

HOST_FENCED_EFFECT = CapabilityDescriptor(
    DescriptorIdentity(DescriptorKind.EFFECT, "host.fenced", 1),
    frozenset({"effect.host-fenced"}),
)


class Store:
    def __init__(self):
        self.values = {}

    def store(self, operation_id, payload):
        reference = f"amp-continuation-{operation_id}"
        self.values[reference] = payload
        return reference

    def load(self, state_reference):
        return self.values[state_reference]

    def store_turn(self, operation_id, *values):
        reference = f"amp-turn-{operation_id}"
        self.values[reference] = values
        return reference


def main():
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
    results = {}
    with tempfile.TemporaryDirectory(prefix="petrus-amp-raising-") as raw:
        cli = Path(raw) / "amp"
        cli.write_text(
            "#!/bin/sh\n"
            f'if [ "$1" = --version ]; then echo "{amp.AMP_CLI_VERSION} (reference)"; '
            'else echo "--orb-execute --project --stream-json"; fi\n'
        )
        cli.chmod(0o755)
        os.environ["AMP_CLI_PATH"] = str(cli)
        for n, name in enumerate(amp_sdk.SCENARIOS):
            store = Store()
            adapter = amp.AmpRuntimeAdapter(amp.AmpRuntimeConfig(f"raise:{name}"), amp.AmpContinuationCodec(store), store)
            assert adapter.probe().disposition is ProbeDisposition.READY
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
            settlement = operation.wait(30)
            cleanup = operation.close()
            results[name] = [
                settlement.outcome.value,
                settlement.accepted_appends,
                settlement.termination_code,
                cleanup.code,
            ]
    print(json.dumps(results))


main()
