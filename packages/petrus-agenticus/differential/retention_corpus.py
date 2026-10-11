"""Generate the territory-custody (retention) differential corpus from the reference.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus/differential/retention_corpus.py \
        ../../packages/petrus-agenticus/differential

It writes two files:

* ``retention_fixture.db``: a custody ledger written by the reference
  ``SqliteTerritoryCustody`` over a real ``LocalProcessEnvironment``. It
  holds one record in each reachable phase (releasing, retained, attached,
  retiring, retired). The Haskell ledger must open it and decode every row
  to the values recorded below.
* ``retention_corpus.json``, with these sections:

  * ``schema``: ``sqlite_master`` (type, name, tbl_name, sql) and
    ``PRAGMA table_info`` of a fresh ledger. The Haskell ledger's must be
    byte-identical.
  * ``fixture_records``: the reference's decoding of every fixture row.
  * ``rows``: seeded mutations of valid rows. Each mutated row was
    inserted into a real ``territory_custody`` table and read back, so
    column affinity applies. Each entry records the typed values read back,
    the reference ``_decode`` outcome (the record, or the storage error
    message), and the ``_salvage_corrupt`` phase.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import random
import shutil
import sqlite3
import sys
import tempfile
import uuid
from pathlib import Path

from petrus.agenticus.attachment._retention import SqliteTerritoryCustody, TerritoryCustodyPhase
from petrus.agenticus.attachment.binding import MotusAttachmentBinding
from petrus.agenticus.attachment.episode import EpisodeAttachment
from petrus.agenticus.catalog.descriptor import CapabilityDescriptor, DescriptorIdentity, DescriptorKind
from petrus.agenticus.catalog.resolution import ResolutionSnapshot
from petrus.agenticus.connection.storage import StorageError
from petrus.agenticus.thread.identity import EpisodeId
from petrus.motus.execution import EnvironmentSpec
from petrus.motus.execution.archive import workspace_archive
from petrus.motus.execution.providers import LocalProcessEnvironment

SEED = 6062
CLOCK = 10.0


def _snapshot(suffix: str) -> ResolutionSnapshot:
    return ResolutionSnapshot(
        1,
        tuple(
            CapabilityDescriptor(DescriptorIdentity(kind, f"{kind.value}-{suffix}", 1), frozenset(), ())
            for kind in (DescriptorKind.RUNTIME, DescriptorKind.HANDS, DescriptorKind.TERRITORY)
        ),
    )


def _attachment(root: Path, provider: LocalProcessEnvironment, operation: str, suffix: str) -> EpisodeAttachment:
    source = root / f"source-{suffix}"
    source.mkdir()
    (source / "canary.txt").write_text(f"fixture {suffix}")
    binding = MotusAttachmentBinding.open(
        provider,
        operation,
        EnvironmentSpec(),
        workspace_archive_bytes=workspace_archive(source),
        input_digest="initial",
    )
    return EpisodeAttachment(
        episode_id=EpisodeId(f"episode-{suffix}"),
        snapshot=_snapshot(suffix),
        binding=binding,
        attachment_id=f"attachment-{suffix}",
        attachment_epoch=3,
        deadline=100,
    )


def typed(value: object) -> dict[str, object]:
    if value is None:
        return {"t": "null"}
    if isinstance(value, bytes):
        return {"t": "blob", "hex": value.hex()}
    if isinstance(value, int):
        return {"t": "int", "v": value}
    if isinstance(value, float):
        return {"t": "real", "v": repr(value)}
    if isinstance(value, str):
        return {"t": "text", "v": value}
    raise TypeError(type(value))


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


def fixture(directory: Path, scratch: Path) -> list[dict[str, object]]:
    provider = LocalProcessEnvironment()
    root = scratch / "fixture-root"
    root.mkdir()
    ledger_dir = scratch / "ledger"
    path = ledger_dir / "territories.db"
    custody = SqliteTerritoryCustody(path, clock=lambda: CLOCK)

    releasing = _attachment(root, provider, "operation-releasing", "releasing")
    custody.begin_release("custody-releasing", "host-one", releasing, retain_until=50)

    retained = _attachment(root, provider, "operation-retained", "retained")
    custody.release("custody-retained", "host-one", retained, retain_until=50)

    attached = _attachment(root, provider, "operation-attached", "attached")
    custody.release("custody-attached", "host-one", attached, retain_until=50.5)
    custody.reclaim(
        "custody-attached",
        "host-one",
        provider,
        episode_id=EpisodeId("episode-successor"),
        snapshot=_snapshot("successor"),
        attachment_id="attachment-successor",
        deadline=100,
    )

    retired = _attachment(root, provider, "operation-retired", "retired")
    custody.release("custody-retired", "host-one", retired, retain_until=50)
    custody.retire("custody-retired", "host-one", provider)

    retiring = _attachment(root, provider, "operation-retiring", "retiring")
    custody.release("custody-retiring", "host-one", retiring, retain_until=12.25)
    custody._set_phase("custody-retiring", TerritoryCustodyPhase.RETAINED, TerritoryCustodyPhase.RETIRING)  # noqa: SLF001

    records = [record_json(record) for record in custody.records()]
    custody.close()
    shutil.copyfile(path, directory / "retention_fixture.db")
    for operation in ("operation-releasing", "operation-retained", "operation-attached", "operation-retiring"):
        lease = provider.lookup(operation)
        if lease is not None:
            provider.destroy(lease)
    return records


def schema(scratch: Path) -> dict[str, object]:
    path = scratch / "schema" / "territories.db"
    SqliteTerritoryCustody(path).close()
    with sqlite3.connect(path) as database:
        master = database.execute("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY rowid").fetchall()
        info = database.execute("PRAGMA table_info(territory_custody)").fetchall()
    return {"sqlite_master": [list(row) for row in master], "table_info": [list(row) for row in info]}


ARCHIVE = b"archive-bytes"
DIGEST = hashlib.sha256(ARCHIVE).hexdigest()
CAPS = '["command-cancellation","process-group","workspace"]'
BASES = {
    "retained": [
        "custody-x", "host-one", 1, "retained", "episode-a", "attachment-a", 3, "operation-x", "local",
        "lease-x", CAPS, 50.0, ARCHIVE, DIGEST, None, None, None, None,
    ],
    "attached": [
        "custody-y", "host-one", 2, "attached", "episode-a", "attachment-a", 3, "operation-y", "local",
        "lease-y", "[]", 50.0, ARCHIVE, DIGEST, "episode-b", "attachment-b", 4, None,
    ],
    "retired": [
        "custody-z", "host-one", 1, "retired", "episode-a", "attachment-a", 3, "operation-z", "local",
        "lease-z", '["workspace"]', 0.0, None, None, None, None, None, "clean",
    ],
}
TEXT_EDGES: list[object] = [
    "", " x", "x ", "\u3000x", "x\x01", "x\x7f", "x" * 256, "x" * 257, "é" * 128, "é" * 129, "ok", "12", "1.5",
    None, 0, -1, 1, 7, 1.5, math.inf, b"bytes", b"",
]
CAPABILITY_EDGES: list[object] = [
    "[]", '["a"]', '["b","a"]', '{"a":1}', "[1]", "not-json", '["", "a"]', '[" a"]', '"x"', "NaN", "[null]",
    '["a","a"]', "[\"\\u00e9\"]", "[]   ", " []", "[true]", '[["a"]]', b"[]", 3,
]
PHASE_EDGES: list[object] = [phase.value for phase in TerritoryCustodyPhase] + ["bogus", "RETAINED", 1, None]
CLEANUP_EDGES: list[object] = ["clean", "not-created", "unverified", "bogus", "", 0, b"clean"]
INT_EDGES: list[object] = [0, -1, 1, 2, 3, 4, 5, 2**40, 1.5, 2.0, "3", "x", b"\x01", None]
NUMBER_EDGES: list[object] = [0, 50, 50.5, -1.0, math.inf, -math.inf, "50", "soon", b"\x00", 1e308]
BLOB_EDGES: list[object] = [None, ARCHIVE, b"", b"other", "text-archive", 5]
DIGEST_EDGES: list[object] = [None, DIGEST, hashlib.sha256(b"").hexdigest(), hashlib.sha256(b"other").hexdigest(), "x", "", 5]


def column_edges(index: int) -> list[object]:
    if index == 10:
        return CAPABILITY_EDGES
    if index == 3:
        return PHASE_EDGES
    if index == 17:
        return CLEANUP_EDGES
    if index in (2, 6, 16):
        return INT_EDGES
    if index == 11:
        return NUMBER_EDGES
    if index == 12:
        return BLOB_EDGES
    if index == 13:
        return DIGEST_EDGES
    return TEXT_EDGES


def mutated_rows(rng: random.Random) -> list[tuple[str, list[object]]]:
    cases: list[tuple[str, list[object]]] = []
    for base_name, base in BASES.items():
        cases.append((base_name, list(base)))
        for index in range(18):
            for value in column_edges(index):
                row = list(base)
                row[index] = value
                cases.append((base_name, row))
    for _ in range(400):
        base_name = rng.choice(list(BASES))
        row = list(BASES[base_name])
        for index in rng.sample(range(18), rng.randint(2, 4)):
            row[index] = rng.choice(column_edges(index))
        cases.append((base_name, row))
    return cases


def readback(database: sqlite3.Connection, row: list[object]) -> tuple[object, ...] | None:
    database.execute("DELETE FROM territory_custody")
    try:
        database.execute(f"INSERT INTO territory_custody VALUES ({', '.join('?' * 18)})", row)
    except sqlite3.IntegrityError:
        return None
    result = database.execute("SELECT * FROM territory_custody").fetchone()
    assert result is not None
    return tuple(result)


def rows(scratch: Path) -> list[dict[str, object]]:
    rng = random.Random(SEED)
    path = scratch / "rows" / "territories.db"
    custody = SqliteTerritoryCustody(path, clock=lambda: CLOCK)
    database = custody._database  # noqa: SLF001 - the reference's own connection and table
    salvage_writes: list[tuple[str, tuple[object, ...]]] = []
    custody._write = lambda sql, parameters, expected_rows=None: salvage_writes.append((sql, parameters))  # type: ignore[method-assign]  # noqa: SLF001
    output = []
    seen = set()
    for base_name, row in mutated_rows(rng):
        read = readback(database, row)
        if read is None:
            continue
        key = json.dumps([typed(value) for value in read])
        if key in seen:
            continue
        seen.add(key)
        try:
            outcome: dict[str, object] = {"record": record_json(SqliteTerritoryCustody._decode(read))}  # noqa: SLF001
        except StorageError as error:
            outcome = {"error": str(error)}
        salvage_writes.clear()
        phase = custody._salvage_corrupt(read)  # noqa: SLF001
        output.append({"base": base_name, "row": [typed(value) for value in read], **outcome, "salvage": phase.value})
    custody.close()
    return output


def _seeded_uuid4(rng: random.Random = random.Random(SEED)) -> uuid.UUID:
    """``uuid.uuid4`` drawn from a seeded stream, so the fixture's lease ids
    (``LocalProcessEnvironment`` mints them with ``uuid.uuid4()``) and so the
    whole fixture are reproducible byte for byte."""
    return uuid.UUID(int=rng.getrandbits(128), version=4)


def main() -> None:
    uuid.uuid4 = _seeded_uuid4
    directory = Path(sys.argv[1])
    scratch = Path(tempfile.mkdtemp(prefix="retention-corpus-"))
    os.chmod(scratch, 0o700)
    try:
        corpus = {
            "seed": SEED,
            "schema": schema(scratch),
            "fixture_records": fixture(directory, scratch),
            "rows": rows(scratch),
        }
    finally:
        shutil.rmtree(scratch)
    (directory / "retention_corpus.json").write_text(json.dumps(corpus, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
