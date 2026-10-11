"""The reference side of ArchiveSpec's pax-number group: how tarfile reads pax number fields.

    pax_numbers.py OUT KEY HEX

Writes to OUT an archive whose member "n" (3 bytes) has a pax header setting KEY to the bytes
HEX, then prints tarfile's reading of OUT: [size, mtime, mtime's type, uid, gid] of each member.
"""

import io
import json
import sys
import tarfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "fixtures"))

from generate_archive_fixtures import finish, pad, pax_records, raw_header  # noqa: E402


def main() -> None:
    out, key, value = sys.argv[1:]
    records = pax_records([(key.encode(), bytes.fromhex(value))])
    data = finish(raw_header(b"././@PaxHeader", b"x", len(records)), pad(records), raw_header(b"n", b"0", 3), pad(b"abc"))
    Path(out).write_bytes(data)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        members = [[m.size, m.mtime, type(m.mtime).__name__, m.uid, m.gid] for m in archive.getmembers()]
    sys.stdout.write(json.dumps(members) + "\n")


if __name__ == "__main__":
    main()
