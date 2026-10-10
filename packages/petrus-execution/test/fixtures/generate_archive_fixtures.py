"""Generate differential fixtures for the Haskell workspace-archive codec.

Run from the repository root (needs the pinned upstream checkout):

    uv run --frozen --python 3.14.6 --project upstream/petrus python \
        packages/petrus-execution/test/fixtures/generate_archive_fixtures.py

It writes ``archive_fixtures-<platform>.json`` next to this script, where
``<platform>`` is ``platform.system().lower()`` (``darwin`` or ``linux``).
Everything is produced by upstream Petrus and CPython's ``tarfile`` so the
Haskell tests can assert byte-identical archives, identical member parsing,
identical validation outcomes, and identical extracted trees.

The reference's output depends on the host: CPython archives a symlink with
its ``lstat`` mode, which is ``0o777`` on Linux but follows the umask on macOS
(``0o755`` here), and extraction inherits the host filesystem's rules (APFS
refuses non-UTF-8 names).  So the fixtures are generated once per platform
and the Haskell suite compares against the file for the platform it runs on.
Regenerate the Linux file in a container, for example:

    docker run --rm -v "$PWD:/repo" -w /repo ubuntu:24.04 sh -c '
        apt-get update && apt-get install -y curl ca-certificates &&
        curl -LsSf https://astral.sh/uv/install.sh | sh &&
        UV_PROJECT_ENVIRONMENT=/tmp/venv ~/.local/bin/uv run --frozen \
            --python 3.14.6 --project upstream/petrus python \
            packages/petrus-execution/test/fixtures/generate_archive_fixtures.py'
"""

from __future__ import annotations

import base64
import gzip
import hashlib
import io
import json
import os
import platform
import stat
import struct
import sys
import tarfile
import tempfile
import zlib
from pathlib import Path

from petrus.motus.execution.archive import (
    extract_workspace_archive,
    validate_workspace_archive,
    workspace_archive,
)

HERE = Path(__file__).resolve().parent
UMASK = 0o022


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def zb64(data: bytes) -> str:
    """zlib-compressed base64: archives are mostly zero padding."""
    return base64.b64encode(zlib.compress(data, 9)).decode("ascii")


def fsbytes(name: str) -> bytes:
    return os.fsencode(name)


def content(seed: int, size: int) -> bytes:
    block = hashlib.sha256(str(seed).encode()).digest()
    return (block * (size // len(block) + 1))[:size]


# ---------------------------------------------------------------------------
# Workspaces: (name, entries).  Entries are created in order.


def workspace_cases() -> list[tuple[str, list[dict]]]:
    long99 = "n" * 99
    long100 = "m" * 100
    long101 = "k" * 101
    long150 = "q" * 150
    many = []
    for index in range(300):
        many.append({"path": f"bulk/{index:04d}-{'x' * (index % 7)}.txt", "type": "file", "mode": 0o644, "seed": index, "size": index * 13 % 700})
    return [
        ("empty", []),
        (
            "dotfiles",
            [
                {"path": ".env", "type": "file", "mode": 0o600, "seed": 1, "size": 17},
                {"path": ".git", "type": "dir", "mode": 0o755},
                {"path": ".git/config", "type": "file", "mode": 0o644, "seed": 2, "size": 40},
                {"path": "a.txt", "type": "file", "mode": 0o644, "seed": 3, "size": 5},
            ],
        ),
        (
            "nested-modes",
            [
                {"path": "src", "type": "dir", "mode": 0o755},
                {"path": "src/deep", "type": "dir", "mode": 0o700},
                {"path": "src/deep/er", "type": "dir", "mode": 0o775},
                {"path": "src/deep/er/x.py", "type": "file", "mode": 0o755, "seed": 4, "size": 1000},
                {"path": "src/run.sh", "type": "file", "mode": 0o4755, "seed": 5, "size": 30},
                {"path": "src/ro.txt", "type": "file", "mode": 0o444, "seed": 6, "size": 0},
                {"path": "src/empty-dir", "type": "dir", "mode": 0o755},
                {"path": "zero", "type": "file", "mode": 0o644, "seed": 7, "size": 0},
                {"path": "b511", "type": "file", "mode": 0o644, "seed": 8, "size": 511},
                {"path": "b512", "type": "file", "mode": 0o644, "seed": 9, "size": 512},
                {"path": "b513", "type": "file", "mode": 0o644, "seed": 10, "size": 513},
                {"path": "b100k", "type": "file", "mode": 0o640, "seed": 11, "size": 100000},
            ],
        ),
        (
            "hard-links",
            [
                {"path": "a", "type": "file", "mode": 0o644, "seed": 12, "size": 64},
                {"path": "c", "type": "dir", "mode": 0o755},
                {"path": "c/d", "type": "hardlink", "target": "a"},
                {"path": "b", "type": "hardlink", "target": "a"},
                {"path": "single", "type": "file", "mode": 0o644, "seed": 13, "size": 3},
            ],
        ),
        (
            "symlinks",
            [
                {"path": "target.txt", "type": "file", "mode": 0o644, "seed": 14, "size": 9},
                {"path": "dir", "type": "dir", "mode": 0o755},
                {"path": "dir/inner.txt", "type": "file", "mode": 0o644, "seed": 15, "size": 9},
                {"path": "rel", "type": "symlink", "target": "target.txt"},
                {"path": "abs", "type": "symlink", "target": "/etc/passwd"},
                {"path": "dangling", "type": "symlink", "target": "missing/file"},
                {"path": "to-dir", "type": "symlink", "target": "dir"},
                {"path": "to-dir-slash", "type": "symlink", "target": "dir/"},
                {"path": "up", "type": "symlink", "target": "../outside"},
                {"path": "dir/back", "type": "symlink", "target": "../target.txt"},
                {"path": "long-target", "type": "symlink", "target": "t/" * 60 + "end"},
                {"path": "unicode-target", "type": "symlink", "target": "café/ünï"},
            ],
        ),
        (
            "long-names",
            [
                {"path": long99, "type": "file", "mode": 0o644, "seed": 16, "size": 1},
                {"path": long100, "type": "file", "mode": 0o644, "seed": 17, "size": 2},
                {"path": long101, "type": "file", "mode": 0o644, "seed": 18, "size": 3},
                {"path": "d" * 99, "type": "dir", "mode": 0o755},
                {"path": "e" * 100, "type": "dir", "mode": 0o755},
                {"path": "dirs", "type": "dir", "mode": 0o755},
                {"path": "dirs/" + long150, "type": "file", "mode": 0o644, "seed": 19, "size": 4},
                {"path": "dirs/" + "r" * 90, "type": "dir", "mode": 0o755},
                {"path": "dirs/" + "r" * 90 + "/" + "s" * 90, "type": "file", "mode": 0o644, "seed": 20, "size": 5},
                {"path": "x" * 255, "type": "file", "mode": 0o644, "seed": 21, "size": 6},
            ],
        ),
        (
            "unicode-names",
            [
                {"path": "café.txt", "type": "file", "mode": 0o644, "seed": 22, "size": 10},
                {"path": "日本語", "type": "dir", "mode": 0o755},
                {"path": "日本語/ファイル.md", "type": "file", "mode": 0o644, "seed": 23, "size": 11},
                {"path": "🎉.md", "type": "file", "mode": 0o644, "seed": 24, "size": 12},
                {"path": "ü" * 60, "type": "file", "mode": 0o644, "seed": 25, "size": 13},
                {"path": "Ω-link", "type": "symlink", "target": "café.txt"},
                {"path": "plain", "type": "file", "mode": 0o644, "seed": 26, "size": 14},
            ],
        ),
        (
            "ascii-oddities",
            [
                {"path": "with space", "type": "file", "mode": 0o644, "seed": 27, "size": 1},
                {"path": "a=b", "type": "file", "mode": 0o644, "seed": 28, "size": 1},
                {"path": "line\nbreak", "type": "file", "mode": 0o644, "seed": 29, "size": 1},
                {"path": "tab\there", "type": "file", "mode": 0o644, "seed": 30, "size": 1},
                {"path": "q?mark", "type": "file", "mode": 0o644, "seed": 31, "size": 1},
                {"path": "back\\slash", "type": "file", "mode": 0o644, "seed": 32, "size": 1},
                {"path": "'quote\"", "type": "file", "mode": 0o644, "seed": 33, "size": 1},
            ],
        ),
        (
            "sort-order",
            [
                {"path": "a", "type": "dir", "mode": 0o755},
                {"path": "a/b", "type": "file", "mode": 0o644, "seed": 34, "size": 1},
                {"path": "a-b", "type": "file", "mode": 0o644, "seed": 35, "size": 1},
                {"path": "a.b", "type": "file", "mode": 0o644, "seed": 36, "size": 1},
                {"path": "a_b", "type": "file", "mode": 0o644, "seed": 37, "size": 1},
                {"path": "Q", "type": "file", "mode": 0o644, "seed": 38, "size": 1},
                {"path": "a0", "type": "file", "mode": 0o644, "seed": 39, "size": 1},
                {"path": "é", "type": "file", "mode": 0o644, "seed": 40, "size": 1},
                {"path": "z", "type": "file", "mode": 0o644, "seed": 41, "size": 1},
                {"path": "~", "type": "file", "mode": 0o644, "seed": 42, "size": 1},
            ],
        ),
        ("bulk", [{"path": "bulk", "type": "dir", "mode": 0o755}, *many]),
    ]


def build_workspace(root: Path, entries: list[dict]) -> None:
    for entry in entries:
        path = root / entry["path"]
        kind = entry["type"]
        if kind == "dir":
            path.mkdir()
        elif kind == "file":
            path.write_bytes(content(entry["seed"], entry["size"]))
        elif kind == "symlink":
            os.symlink(entry["target"], path)
        elif kind == "hardlink":
            os.link(root / entry["target"], path)
        else:
            raise AssertionError(kind)
    # Apply modes deepest-first so restrictive directory modes do not block.
    for entry in sorted(entries, key=lambda e: e["path"].count("/"), reverse=True):
        if entry["type"] in ("dir", "file"):
            os.chmod(root / entry["path"], entry["mode"])


def workspace_fixtures() -> list[dict]:
    fixtures = []
    for name, entries in workspace_cases():
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "ws"
            root.mkdir()
            build_workspace(root, entries)
            data = workspace_archive(root)
            # Restore permissions so cleanup works.
            for dirpath, dirnames, _ in os.walk(root):
                for dirname in dirnames:
                    full = Path(dirpath) / dirname
                    if not full.is_symlink():
                        os.chmod(full, 0o755)
        fixtures.append(
            {
                "name": name,
                "entries": entries,
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "archive_zb64": zb64(data),
            }
        )
    return fixtures


# ---------------------------------------------------------------------------
# Pure header fixtures: TarInfo.tobuf exactly as workspace_archive configures it.


def header_cases() -> list[dict]:
    names = [
        b"plain",
        b"n" * 100,
        b"n" * 101,
        b"caf\xc3\xa9",
        b"bad\xff\xfename",
        b"mixed\xc3\xa9\xff",
        b"\xed\xa0\x80surrogate-encoded",
        b"\xc0\xafoverlong",
        b"x" * 99 + b"\xc3\xa9",
        "日本".encode() * 40,
        b"q" * 9999,
    ]
    cases = []
    for name in names:
        cases.append({"name": name, "type": "file", "mode": 0o100644, "size": 1234})
        cases.append({"name": name, "type": "dir", "mode": 0o040755, "size": 0})
        cases.append({"name": b"link", "type": "symlink", "mode": 0o120777, "size": 0, "linkname": name})
        cases.append({"name": name, "type": "hardlink", "mode": 0o100600, "size": 0, "linkname": b"first" + name})
    cases.append({"name": b"setuid", "type": "file", "mode": 0o104755, "size": 0})
    cases.append({"name": b"big", "type": "file", "mode": 0o100644, "size": 2 * 1024**3})
    return cases


TYPES = {"file": tarfile.REGTYPE, "dir": tarfile.DIRTYPE, "symlink": tarfile.SYMTYPE, "hardlink": tarfile.LNKTYPE}


def header_fixtures() -> list[dict]:
    fixtures = []
    for case in header_cases():
        info = tarfile.TarInfo(os.fsdecode(case["name"]))
        info.type = TYPES[case["type"]]
        info.mode = case["mode"]
        info.size = case["size"]
        info.linkname = os.fsdecode(case.get("linkname", b""))
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        encoded = info.tobuf(tarfile.PAX_FORMAT, "utf-8", "surrogateescape")
        fixtures.append(
            {
                "name_b64": b64(case["name"]),
                "type": case["type"],
                "mode": case["mode"],
                "size": case["size"],
                "linkname_b64": b64(case.get("linkname", b"")),
                "header_zb64": zb64(encoded),
            }
        )
    return fixtures


# ---------------------------------------------------------------------------
# Reader fixtures: arbitrary archives, CPython's parse/validate/extract result.


def chksum(header: bytearray) -> bytearray:
    header[148:156] = b"        "
    value = sum(header)
    header[148:156] = b"%06o\0 " % value
    return header


def raw_header(name: bytes, typeflag: bytes, size: int = 0, linkname: bytes = b"", mode: int = 0o644,
               extra: dict[int, bytes] | None = None, size_field: bytes | None = None,
               mtime: int = 0) -> bytes:
    header = bytearray(512)
    header[0:len(name[:100])] = name[:100]
    header[100:108] = b"%07o\0" % mode
    header[108:116] = b"0000000\0"
    header[116:124] = b"0000000\0"
    header[124:136] = size_field if size_field is not None else b"%011o\0" % size
    header[136:148] = b"%011o\0" % mtime
    header[156:157] = typeflag
    header[157:157 + len(linkname[:100])] = linkname[:100]
    header[257:265] = b"ustar\x0000"
    for offset, value in (extra or {}).items():
        header[offset:offset + len(value)] = value
    return bytes(chksum(header))


def pad(data: bytes) -> bytes:
    return data + b"\0" * (-len(data) % 512)


def finish(*parts: bytes) -> bytes:
    body = b"".join(parts) + b"\0" * 1024
    return body + b"\0" * (-len(body) % 10240)


def pax_records(records: list[tuple[bytes, bytes]]) -> bytes:
    out = b""
    for key, value in records:
        base = len(key) + len(value) + 3
        p = 0
        while True:
            n = base + len(str(p))
            if n == p:
                break
            p = n
        out += str(p).encode() + b" " + key + b"=" + value + b"\n"
    return out


def tar_with(format: int, members: list[tuple[tarfile.TarInfo, bytes | None]], pax_headers=None) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=format, pax_headers=pax_headers) as archive:
        for info, data in members:
            archive.addfile(info, io.BytesIO(data) if data is not None else None)
    return output.getvalue()


def info(name: str, kind: bytes = tarfile.REGTYPE, size: int = 0, linkname: str = "", mode: int = 0o644,
         mtime: float = 0) -> tarfile.TarInfo:
    item = tarfile.TarInfo(name)
    item.type = kind
    item.size = size
    item.linkname = linkname
    item.mode = mode
    item.mtime = mtime
    return item


def reader_cases() -> list[tuple[str, bytes]]:
    cases: list[tuple[str, bytes]] = []
    hello = b"hello world\n"
    simple = tar_with(tarfile.PAX_FORMAT, [(info("dir", tarfile.DIRTYPE, mode=0o755), None),
                                           (info("dir/file.txt", size=len(hello)), hello),
                                           (info("link", tarfile.SYMTYPE, linkname="dir/file.txt"), None),
                                           (info("hard", tarfile.LNKTYPE, linkname="dir/file.txt"), None)])
    cases.append(("simple-pax", simple))
    cases.append(("simple-gzip", gzip.compress(simple, mtime=0)))
    cases.append(("gzip-truncated-tail", gzip.compress(simple, mtime=0)[:-6]))
    cases.append(("gzip-trailing-garbage", gzip.compress(simple, mtime=0) + b"garbage!"))
    cases.append(("gzip-of-garbage", gzip.compress(b"not a tar" * 100, mtime=0)))
    cases.append(("empty-bytes", b""))
    cases.append(("zero-record", b"\0" * 10240))
    cases.append(("one-zero-block", b"\0" * 512))
    cases.append(("garbage", b"x" * 512))
    cases.append(("short-garbage", b"x" * 100))
    cases.append(("truncated-header-after-member", simple[:1536] + b"\x01" * 100))
    cases.append(("truncated-data", simple[:512 * 3 + 5]))
    cases.append(("no-end-marker", simple[:512 * 4]))
    long_name = "L" * 120 + "/" + "f" * 30
    cases.append(("gnu-longname", tar_with(tarfile.GNU_FORMAT, [(info(long_name, size=3), b"abc"),
                                                                (info("sym", tarfile.SYMTYPE, linkname="T" * 140), None),
                                                                (info("D" * 120, tarfile.DIRTYPE), None)])))
    cases.append(("ustar-prefix", tar_with(tarfile.USTAR_FORMAT, [(info("p" * 80 + "/" + "n" * 80, size=1), b"z"),
                                                                  (info("q" * 80 + "/" + "d" * 50, tarfile.DIRTYPE), None)])))
    cases.append(("pax-global-and-mtime", tar_with(tarfile.PAX_FORMAT,
                                                   [(info("f", size=2, mtime=1000000.5), b"hi"),
                                                    (info("big-uid", size=0), b"")],
                                                   pax_headers={"comment": "global", "uid": "7"})))
    cases.append(("pax-unicode", tar_with(tarfile.PAX_FORMAT, [(info("ünïcödé/" + "é" * 70, size=1), b"u"),
                                                               (info("ünïcödé", tarfile.DIRTYPE), None)])))
    cases.append(("v7-dir-areg", finish(raw_header(b"olddir/", b"\0"), raw_header(b"olddir/f", b"\0", 2), pad(b"ab"))))
    cases.append(("unknown-type", finish(raw_header(b"weird", b"Z", 5), pad(b"12345"), raw_header(b"after", b"0", 1), pad(b"!"))))
    cases.append(("fifo", finish(raw_header(b"pipe", b"6"))))
    cases.append(("chardev", finish(raw_header(b"dev", b"3"))))
    cases.append(("contiguous", finish(raw_header(b"cont", b"7", 3), pad(b"xyz"))))
    cases.append(("bad-checksum-first", b"\x01" + raw_header(b"f", b"0")[1:] + b"\0" * 1024))
    bad_second = bytearray(raw_header(b"second", b"0"))
    bad_second[0] = ord("S")
    cases.append(("bad-checksum-second", finish(raw_header(b"first", b"0", 1), pad(b"1"), bytes(bad_second))))
    cases.append(("bad-octal-first", finish(raw_header(b"f", b"0", size_field=b"zzzzzzzzzzz\0"))))
    cases.append(("octal-spaces-and-prefix", finish(raw_header(b"f", b"0", size_field=b" 0o5        "), pad(b"12345"))))
    cases.append(("octal-underscore", finish(raw_header(b"f", b"0", size_field=b"0_5\0        "), pad(b"12345"))))
    cases.append(("base256-size", finish(raw_header(b"f", b"0", size_field=b"\x80" + b"\0" * 10 + b"\x03"), pad(b"abc"))))
    cases.append(("base256-negative-size-first", finish(raw_header(b"f", b"0", size_field=b"\xff" * 12))))
    cases.append(("base256-negative-size-second", finish(raw_header(b"a", b"0", 1), pad(b"1"), raw_header(b"f", b"0", size_field=b"\xff" * 12))))
    pax_bad = pax_records([(b"path", b"x")]).replace(b"10 ", b"99 ")
    cases.append(("pax-bad-record", finish(raw_header(b"././@PaxHeader", b"x", len(pax_bad)), pad(pax_bad), raw_header(b"x", b"0"))))
    cases.append(("pax-bad-record-second", finish(raw_header(b"ok", b"0"), raw_header(b"././@PaxHeader", b"x", len(pax_bad)), pad(pax_bad), raw_header(b"x", b"0"))))
    pax_size = pax_records([(b"size", b"3"), (b"path", b"renamed/"), (b"mtime", b"12.75"), (b"uid", b"abc"), (b"linkpath", b"lp")])
    cases.append(("pax-overrides", finish(raw_header(b"././@PaxHeader", b"x", len(pax_size)), pad(pax_size),
                                         raw_header(b"orig", b"0", 0), pad(b"abc"), raw_header(b"tail", b"0", 1), pad(b"t"))))
    pax_neg = pax_records([(b"size", b"-5")])
    cases.append(("pax-negative-size", finish(raw_header(b"a", b"0", 1), pad(b"1"), raw_header(b"././@PaxHeader", b"x", len(pax_neg)), pad(pax_neg), raw_header(b"neg", b"0"))))
    cases.append(("pax-negative-size-first", finish(raw_header(b"././@PaxHeader", b"x", len(pax_neg)), pad(pax_neg), raw_header(b"neg", b"0"))))
    cases.append(("pax-then-eof", raw_header(b"././@PaxHeader", b"x", len(pax_size)) + pad(pax_size)))
    pax_bin = b"21 hdrcharset=BINARY\n" + pax_records([(b"path", b"bin\xffname")])
    cases.append(("pax-binary", finish(raw_header(b"././@PaxHeader", b"x", len(pax_bin)), pad(pax_bin), raw_header(b"???", b"0", 1), pad(b"b"))))
    pax_unicode_size = pax_records([(b"size", "١٢".encode())])
    cases.append(("pax-unicode-digits", finish(raw_header(b"././@PaxHeader", b"x", len(pax_unicode_size)), pad(pax_unicode_size), raw_header(b"u", b"0"), pad(b"x" * 12))))
    gpax = pax_records([(b"path", b"global-name"), (b"mtime", b"5")])
    cases.append(("pax-global-path", finish(raw_header(b"pax_global_header", b"g", len(gpax)), pad(gpax),
                                            raw_header(b"one", b"0", 1), pad(b"1"), raw_header(b"two", b"5"))))
    # GNU old sparse: two regions, origsize 2048, 1024 bytes of data.
    sparse_extra = {386: b"%011o\0" % 0 + b"%011o\0" % 512 + b"%011o\0" % 1024 + b"%011o\0" % 512,
                    483: b"%011o\0" % 2048}
    cases.append(("gnu-sparse", finish(raw_header(b"sparse", b"S", 1024, extra=sparse_extra), pad(b"A" * 512 + b"B" * 512))))
    sparse_ext = {386: b"%011o\0" % 0 + b"%011o\0" % 512, 482: b"\x01", 483: b"%011o\0" % 4096}
    ext_block = bytearray(512)
    ext_block[0:24] = b"%011o\0" % 2048 + b"%011o\0" % 512
    cases.append(("gnu-sparse-extended", finish(raw_header(b"sparse2", b"S", 1024, extra=sparse_ext), bytes(ext_block), pad(b"C" * 512 + b"D" * 512))))
    cases.append(("gnu-sparse-extended-truncated", raw_header(b"sparse3", b"S", 0, extra=sparse_ext) + b"\0" * 100))
    pax01 = pax_records([(b"GNU.sparse.size", b"3000"), (b"GNU.sparse.map", b"0,10,1000,10"), (b"GNU.sparse.name", b"real-name")])
    cases.append(("pax-sparse-01", finish(raw_header(b"././@PaxHeader", b"x", len(pax01)), pad(pax01), raw_header(b"GNUSparseFile.0/x", b"0", 20), pad(b"E" * 10 + b"F" * 10))))
    pax01bad = pax_records([(b"GNU.sparse.map", b"0,zz")])
    cases.append(("pax-sparse-01-bad", finish(raw_header(b"././@PaxHeader", b"x", len(pax01bad)), pad(pax01bad), raw_header(b"y", b"0"))))
    pax00 = pax_records([(b"GNU.sparse.size", b"100"), (b"GNU.sparse.offset", b"0"), (b"GNU.sparse.numbytes", b"4"), (b"GNU.sparse.offset", b"50"), (b"GNU.sparse.numbytes", b"4")])
    cases.append(("pax-sparse-00", finish(raw_header(b"././@PaxHeader", b"x", len(pax00)), pad(pax00), raw_header(b"s00", b"0", 8), pad(b"GGGGHHHH"))))
    pax10 = pax_records([(b"GNU.sparse.major", b"1"), (b"GNU.sparse.minor", b"0"), (b"GNU.sparse.realsize", b"700"), (b"GNU.sparse.name", b"s10")])
    map10 = pad(b"2\n0\n5\n600\n5\n")
    cases.append(("pax-sparse-10", finish(raw_header(b"././@PaxHeader", b"x", len(pax10)), pad(pax10), raw_header(b"GNUSparseFile.0/s10", b"0", len(map10) + 10), map10 + pad(b"IIIIIJJJJJ"))))
    pax10bad = pax_records([(b"GNU.sparse.major", b"1"), (b"GNU.sparse.minor", b"0")])
    cases.append(("pax-sparse-10-no-newline", finish(raw_header(b"././@PaxHeader", b"x", len(pax10bad)), pad(pax10bad), raw_header(b"t", b"0", 512), b"9" * 512)))
    # Safety-gate cases.
    cases.append(("unsafe-dotdot", tar_with(tarfile.PAX_FORMAT, [(info("../escape", size=1), b"x")])))
    cases.append(("unsafe-absolute", tar_with(tarfile.PAX_FORMAT, [(info("/abs", size=1), b"x")])))
    cases.append(("unsafe-inner-dotdot", tar_with(tarfile.PAX_FORMAT, [(info("a/../../b", size=1), b"x")])))
    cases.append(("duplicate", tar_with(tarfile.PAX_FORMAT, [(info("a/b", size=1), b"x"), (info("a//./b", size=1), b"y")])))
    cases.append(("duplicate-dir", tar_with(tarfile.PAX_FORMAT, [(info("d", tarfile.DIRTYPE), None), (info("d/", tarfile.DIRTYPE), None)])))
    cases.append(("forbidden-root", tar_with(tarfile.PAX_FORMAT, [(info("secret/key", size=1), b"x")])))
    cases.append(("link-escape-symlink", tar_with(tarfile.PAX_FORMAT, [(info("d/l", tarfile.SYMTYPE, linkname="../../etc"), None)])))
    cases.append(("link-inner-dotdot", tar_with(tarfile.PAX_FORMAT, [(info("d/l", tarfile.SYMTYPE, linkname="../x"), None)])))
    cases.append(("link-absolute", tar_with(tarfile.PAX_FORMAT, [(info("l", tarfile.SYMTYPE, linkname="/etc/passwd"), None)])))
    cases.append(("hardlink-escape", tar_with(tarfile.PAX_FORMAT, [(info("h", tarfile.LNKTYPE, linkname="../x"), None)])))
    cases.append(("hardlink-missing-target", tar_with(tarfile.PAX_FORMAT, [(info("h", tarfile.LNKTYPE, linkname="nowhere"), None)])))
    cases.append(("hardlink-forward", tar_with(tarfile.PAX_FORMAT, [(info("h", tarfile.LNKTYPE, linkname="later"), None), (info("later", size=1), b"L")])))
    cases.append(("symlink-chain", tar_with(tarfile.PAX_FORMAT, [(info("real", size=4), b"data"), (info("s1", tarfile.SYMTYPE, linkname="real"), None),
                                                                 (info("s2", tarfile.SYMTYPE, linkname="s1"), None),
                                                                 (info("s1/through", size=1), b"t")])))
    cases.append(("symlink-dir-then-file", tar_with(tarfile.PAX_FORMAT, [(info("d", tarfile.DIRTYPE), None), (info("ln", tarfile.SYMTYPE, linkname="d"), None),
                                                                         (info("ln/f", size=2), b"ok")])))
    cases.append(("symlink-to-dest", tar_with(tarfile.PAX_FORMAT, [(info("dot", tarfile.SYMTYPE, linkname="."), None)])))
    cases.append(("symlink-self-loop", tar_with(tarfile.PAX_FORMAT, [(info("loop", tarfile.SYMTYPE, linkname="loop"), None), (info("loop/x", size=1), b"x")])))
    cases.append(("file-over-dir", tar_with(tarfile.PAX_FORMAT, [(info("d", tarfile.DIRTYPE), None), (info("d/x", size=1), b"x"), (info("d", size=1), b"y")])))
    cases.append(("dir-over-file", tar_with(tarfile.PAX_FORMAT, [(info("f", size=1), b"x"), (info("f/", tarfile.DIRTYPE), None)])))
    cases.append(("symlink-over-dir", tar_with(tarfile.PAX_FORMAT, [(info("d", tarfile.DIRTYPE), None), (info("d", tarfile.SYMTYPE, linkname="elsewhere"), None)])))
    cases.append(("modes", tar_with(tarfile.PAX_FORMAT, [(info("exec", size=1, mode=0o777), b"x"), (info("noexec", size=1, mode=0o666), b"x"),
                                                         (info("weird", size=1, mode=0o7070), b"x"), (info("zero", size=1, mode=0), b"x"),
                                                         (info("d", tarfile.DIRTYPE, mode=0o700), None),
                                                         (info("d2", tarfile.DIRTYPE, mode=0o777, mtime=1234), None),
                                                         (info("d2/f", size=1, mode=0o644, mtime=99), b"x")])))
    cases.append(("implicit-parents", tar_with(tarfile.PAX_FORMAT, [(info("p/q/r/file", size=3), b"abc")])))
    cases.append(("dot-names", tar_with(tarfile.PAX_FORMAT, [(info("./a", size=1), b"x"), (info(".", tarfile.DIRTYPE), None)])))
    cases.append(("empty-name", finish(raw_header(b"", b"0", 1), pad(b"e"))))
    cases.append(("bz2-magic", b"BZh91AY&SY" + b"\0" * 502))
    return cases


def describe_member(member: tarfile.TarInfo) -> dict:
    mtime = member.mtime
    return {
        "name_b64": b64(os.fsencode(member.name)),
        "linkname_b64": b64(os.fsencode(member.linkname)),
        "type_b64": b64(member.type),
        "mode": member.mode,
        "size": member.size,
        "mtime": mtime if isinstance(mtime, int) else None,
        "mtime_float": mtime if isinstance(mtime, float) else None,
        "offset": member.offset,
        "offset_data": member.offset_data,
        "sparse": [list(pair) for pair in member.sparse] if member.sparse is not None else None,
    }


def describe_error(error: BaseException, replacements: tuple[tuple[str, str], ...] = ()) -> dict:
    message = str(error) if not isinstance(error, KeyError) else error.args[0]
    for old, new in replacements:
        message = message.replace(old, new)
    return {"class": type(error).__name__, "message": message}


def stamp(st: os.stat_result) -> int | str:
    # Members carry small fixed mtimes; implicit parents get "now".
    return st.st_mtime_ns if st.st_mtime < 1_000_000_000 else "now"


def tree(root: Path) -> list[dict]:
    listing = []
    for dirpath, dirnames, filenames in os.walk(root):
        for name in sorted(dirnames + filenames):
            full = Path(dirpath) / name
            relative = os.fsencode(full.relative_to(root).as_posix())
            st = full.lstat()
            item = {"path_b64": b64(relative), "mode": stat.S_IMODE(st.st_mode)}
            if stat.S_ISLNK(st.st_mode):
                item["type"] = "symlink"
                item["target_b64"] = b64(os.fsencode(os.readlink(full)))
            elif stat.S_ISDIR(st.st_mode):
                item["type"] = "dir"
                item["mtime_ns"] = stamp(st)
            else:
                item["type"] = "file"
                item["mtime_ns"] = stamp(st)
                item["nlink"] = st.st_nlink
                item["sha256"] = hashlib.sha256(full.read_bytes()).hexdigest()
            listing.append(item)
    return sorted(listing, key=lambda item: item["path_b64"])


def reader_fixtures() -> list[dict]:
    fixtures = []
    for name, data in reader_cases():
        fixture: dict = {"name": name, "archive_zb64": zb64(data)}
        try:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
                fixture["members"] = [describe_member(m) for m in archive.getmembers()]
        except Exception as error:  # noqa: BLE001 - the class is the fixture
            fixture["members_error"] = describe_error(error)
        outcomes = {}
        for label, kwargs in (
            ("default", {}),
            ("no_links", {"allow_links": False}),
            ("forbidden_secret", {"forbidden_roots": frozenset({"secret"})}),
        ):
            try:
                validate_workspace_archive(data, **kwargs)
                outcomes[label] = None
            except Exception as error:  # noqa: BLE001
                outcomes[label] = describe_error(error)
        fixture["validate"] = outcomes
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "out"
            try:
                extract_workspace_archive(data, destination)
                fixture["extract"] = {"tree": tree(destination)}
            except Exception as error:  # noqa: BLE001
                replacements = (
                    (os.path.realpath(destination), "<DEST>"),
                    (str(destination), "<DEST>"),
                )
                fixture["extract"] = {
                    "error": describe_error(error, replacements),
                    "tree": tree(destination) if destination.exists() else None,
                }
        fixtures.append(fixture)
    return fixtures


def main() -> None:
    os.umask(UMASK)
    document = {
        "generator": "packages/petrus-execution/test/fixtures/generate_archive_fixtures.py",
        "python": sys.version.split()[0],
        "platform": platform.system(),
        "umask": UMASK,
        "workspaces": workspace_fixtures(),
        "headers": header_fixtures(),
        "readers": reader_fixtures(),
    }
    output = HERE / f"archive_fixtures-{platform.system().lower()}.json"
    output.write_text(json.dumps(document, indent=1, sort_keys=True, ensure_ascii=True) + "\n")
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
