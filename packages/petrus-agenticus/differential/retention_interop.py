"""The reference's half of the live territory-custody ledger interop.

Run with the pinned interpreter from the upstream checkout's root
(``RetentionInteropSpec`` does):

    retention_interop.py write DIR
        Write ``DIR/territories.db`` with the reference ``SqliteTerritoryCustody``
        over a real ``LocalProcessEnvironment``: one record in every phase a
        ledger holds durably (releasing, retained, claiming, attached,
        retiring, retired), a retained record that expires before the reader's
        clock, and a retained record whose capability column was corrupted
        after it was written. Print the reference's own reading of it (the
        ``read`` output below, at clock 20) as JSON.

    retention_interop.py read PATH CLOCK
        Open a ledger (written by either language) with clock CLOCK and print,
        as JSON: ``lookup()`` of every row's custody id (each phase's record,
        or the ``StorageError`` its decoding raises), ``records()`` (or its
        error), then ``recover()`` (or its error), then ``records()`` again.

The ledger's directory must be private (0700) and the file 0600, as the
reference requires.
"""

from __future__ import annotations

import json
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

from petrus.agenticus.attachment._retention import SqliteTerritoryCustody
from petrus.agenticus.attachment.binding import MotusAttachmentBinding
from petrus.agenticus.attachment.episode import EpisodeAttachment
from petrus.agenticus.catalog.descriptor import CapabilityDescriptor, DescriptorIdentity, DescriptorKind
from petrus.agenticus.catalog.resolution import ResolutionSnapshot
from petrus.agenticus.connection.storage import StorageError
from petrus.agenticus.thread.identity import EpisodeId
from petrus.motus.execution import EnvironmentSpec
from petrus.motus.execution.archive import workspace_archive
from petrus.motus.execution.providers import LocalProcessEnvironment


def snapshot(suffix: str) -> ResolutionSnapshot:
    return ResolutionSnapshot(
        1,
        tuple(
            CapabilityDescriptor(DescriptorIdentity(kind, f"{kind.value}-{suffix}", 1), frozenset(), ())
            for kind in (DescriptorKind.RUNTIME, DescriptorKind.HANDS, DescriptorKind.TERRITORY)
        ),
    )


def attachment(root: Path, provider: LocalProcessEnvironment, suffix: str) -> EpisodeAttachment:
    source = root / f"source-{suffix}"
    source.mkdir()
    (source / "canary.txt").write_text(f"interop {suffix}")
    binding = MotusAttachmentBinding.open(
        provider,
        f"operation-{suffix}",
        EnvironmentSpec(),
        workspace_archive_bytes=workspace_archive(source),
        input_digest="initial",
    )
    return EpisodeAttachment(
        episode_id=EpisodeId(f"episode-{suffix}"),
        snapshot=snapshot(suffix),
        binding=binding,
        attachment_id=f"attachment-{suffix}",
        attachment_epoch=3,
        deadline=100,
    )


def record_json(record) -> dict[str, object]:
    return {
        "custody_id": record.custody_id,
        "owner_id": record.owner_id,
        "generation": record.generation,
        "phase": record.phase.value,
        "source": [record.source.episode_id, record.source.attachment_id, record.source.attachment_epoch],
        "lease": [
            record.lease.operation_id,
            record.lease.provider,
            record.lease.lease_id,
            sorted(record.lease.capabilities),
        ],
        "retain_until": repr(float(record.retain_until)),
        "archive": None if record.archive is None else record.archive.hex(),
        "archive_digest": record.archive_digest,
        "target": [record.target_episode_id, record.target_attachment_id, record.target_epoch],
        "cleanup": None if record.cleanup is None else record.cleanup.value,
    }


def outcome(action) -> dict[str, object]:
    try:
        return {"records": [record_json(record) for record in action()]}
    except StorageError as error:
        return {"error": str(error)}


def lookup(custody, custody_id: str) -> dict[str, object]:
    try:
        return {"record": record_json(custody.lookup(custody_id))}
    except StorageError as error:
        return {"error": str(error)}


def read(path: Path, clock: float) -> dict[str, object]:
    database = sqlite3.connect(path)
    try:
        identities = [row[0] for row in database.execute("SELECT custody_id FROM territory_custody ORDER BY custody_id")]
    finally:
        database.close()
    custody = SqliteTerritoryCustody(path, clock=lambda: clock)
    try:
        return {
            "lookups": [{"custody_id": custody_id, **lookup(custody, custody_id)} for custody_id in identities],
            "before": outcome(custody.records),
            "recovered": outcome(custody.recover),
            "after": outcome(custody.records),
        }
    finally:
        custody.close()


def write(directory: Path) -> dict[str, object]:
    path = directory / "territories.db"
    now = [10.0]
    custody = SqliteTerritoryCustody(path, clock=lambda: now[0])
    provider = LocalProcessEnvironment()
    root = Path(tempfile.mkdtemp(prefix="retention-interop-"))
    try:
        custody.begin_release("custody-releasing", "host-one", attachment(root, provider, "releasing"), retain_until=50)
        custody.release("custody-retained", "host-one", attachment(root, provider, "retained"), retain_until=50)
        custody.release("custody-expiring", "host-one", attachment(root, provider, "expiring"), retain_until=15.5)
        custody.release("custody-corrupt", "host-one", attachment(root, provider, "corrupt"), retain_until=50)
        for suffix in ("attached", "claiming"):
            custody.release(f"custody-{suffix}", "host-one", attachment(root, provider, suffix), retain_until=50.5)
            custody.reclaim(
                f"custody-{suffix}",
                "host-one",
                provider,
                episode_id=EpisodeId(f"episode-{suffix}-successor"),
                snapshot=snapshot(f"{suffix}-successor"),
                attachment_id=f"attachment-{suffix}-successor",
                deadline=100,
            )
        custody.release("custody-retired", "host-one", attachment(root, provider, "retired"), retain_until=50)
        custody.retire("custody-retired", "host-one", provider)
        custody.release("custody-retiring", "host-one", attachment(root, provider, "retiring"), retain_until=12.25)
        now[0] = 13.0
        try:
            custody.reclaim(
                "custody-retiring",
                "host-one",
                provider,
                episode_id=EpisodeId("episode-retiring-successor"),
                snapshot=snapshot("retiring-successor"),
                attachment_id="attachment-retiring-successor",
                deadline=100,
            )
        except StorageError as error:
            assert str(error) == "territory custody expired before reclaim", error
        else:
            raise AssertionError("an expired reclaim must fail")
        custody.close()
        # A crash between the durable claim and the attachment: what a
        # second writer then finds. And a column corrupted behind the ledger.
        with sqlite3.connect(path) as database:
            database.execute("UPDATE territory_custody SET phase='claiming' WHERE custody_id='custody-claiming'")
            database.execute("UPDATE territory_custody SET capabilities='not-json' WHERE custody_id='custody-corrupt'")
        for lease in [provider.lookup(f"operation-{suffix}") for suffix in ("releasing", "retained", "expiring", "corrupt", "attached", "claiming", "retiring")]:
            if lease is not None:
                provider.destroy(lease)
    finally:
        shutil.rmtree(root)
    copy = directory / "reader" / "territories.db"
    copy.parent.mkdir(mode=0o700)
    shutil.copyfile(path, copy)
    copy.chmod(0o600)
    return read(copy, 20.0)


def main() -> None:
    command = sys.argv[1]
    if command == "write":
        result = write(Path(sys.argv[2]))
    elif command == "read":
        result = read(Path(sys.argv[2]), float(sys.argv[3]))
    else:
        raise SystemExit(f"unknown command {command!r}")
    json.dump(result, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
