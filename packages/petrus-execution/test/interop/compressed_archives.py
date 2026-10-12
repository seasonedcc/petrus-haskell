"""The reference side of ArchiveSpec's compressed-archive group.

    compressed_archives.py

Prints, as JSON, reader fixtures (the shape of ``generate_archive_fixtures``'
``readers``: tarfile.open("r:*") + getmembers, validate_workspace_archive and
extract_workspace_archive) for archives compressed by every codec that
``tarfile.open(mode="r:*")`` reads, whole, split into several streams,
followed by trailing data, truncated and corrupted, plus an uncompressed
archive whose sparse map reads past its end (copyfileobj's partial writes).
"""

import bz2
import gzip
import hashlib
import json
import lzma
import os
import sys
import tarfile
from pathlib import Path

from compression import zstd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "fixtures"))

from generate_archive_fixtures import UMASK, finish, info, pad, raw_header, reader_fixtures, tar_with  # noqa: E402

CODECS = {
    "gz": lambda data: gzip.compress(data, mtime=0),
    "bz2": bz2.compress,
    "xz": lzma.compress,
    "lzma-alone": lambda data: lzma.compress(data, format=lzma.FORMAT_ALONE),
    "zst": zstd.compress,
}


def noise(seed: int, size: int) -> bytes:
    """Incompressible bytes, so compressed offsets track decompressed ones."""
    out = bytearray()
    counter = 0
    while len(out) < size:
        out += hashlib.sha256(b"%d:%d" % (seed, counter)).digest()
        counter += 1
    return bytes(out[:size])


def corrupt(data: bytes, at: int) -> bytes:
    return data[:at] + bytes(b ^ 0x55 for b in data[at:at + 16]) + data[at + 16:]


def cases() -> list[tuple[str, bytes]]:
    hello = b"hello world\n"
    simple = tar_with(tarfile.PAX_FORMAT, [(info("dir", tarfile.DIRTYPE, mode=0o755), None),
                                           (info("dir/file.txt", size=len(hello)), hello),
                                           (info("link", tarfile.SYMTYPE, linkname="dir/file.txt"), None),
                                           (info("hard", tarfile.LNKTYPE, linkname="dir/file.txt"), None)])
    big = noise(1, 300_000)
    large = tar_with(tarfile.PAX_FORMAT, [(info("big", size=len(big)), big),
                                          (info("dir", tarfile.DIRTYPE, mode=0o755), None),
                                          (info("dir/small", size=5), b"small")])
    result: list[tuple[str, bytes]] = []
    for name, compress in CODECS.items():
        whole = compress(simple)
        result += [
            (f"{name}-simple", whole),
            (f"{name}-multistream", compress(simple[:700]) + compress(simple[700:])),
            (f"{name}-trailing-garbage", whole + b"garbage!"),
            (f"{name}-trailing-zeros", whole + bytes(16)),
            (f"{name}-truncated-half", whole[: len(whole) // 2]),
            (f"{name}-truncated-tail", whole[:-4]),
            (f"{name}-of-garbage", compress(b"not a tar" * 100)),
            (f"{name}-empty", compress(b"")),
            (f"{name}-large", compress(large)),
            (f"{name}-large-truncated", compress(large)[: len(compress(large)) * 2 // 3]),
            (f"{name}-second-stream-truncated", whole + compress(simple)[:-4]),
        ]
        if name != "gz":
            # Bad data the decompressor reaches in its first 128 KiB of
            # output fails the opening; gzip's is a documented divergence.
            result.append((f"{name}-corrupt-first", corrupt(compress(large), 40)))
    # An uncompressed old-GNU sparse member whose map reads past the end of
    # the archive: copyfileobj writes the whole 16 KiB blocks it read.
    sparse = {386: b"%011o\0" % 0 + b"%011o\0" % 50_000, 483: b"%011o\0" % 50_000}
    after = noise(2, 20_000)
    result.append(("sparse-reads-past-end", finish(raw_header(b"sparse", b"S", 512, extra=sparse), pad(b"K" * 512),
                                                   raw_header(b"after", b"0", len(after)), pad(after))))
    return result


def main() -> None:
    os.umask(UMASK)
    sys.stdout.write(json.dumps(reader_fixtures(cases()), sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
