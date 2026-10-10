"""Python counterparts of petrus-posix's benchmarks (see bench/Main.hs).

Run by scripts/bench with the pinned upstream environment; prints one
``name,mean_ns`` CSV line per benchmark, named like the Haskell ones.
"""

import fcntl
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "scripts"))
from bench_timing import report  # noqa: E402

from petrus.telemetry import max_rss_mb  # noqa: E402


def atomic(path: Path, data: bytes) -> None:
    # petrus.motus._execution.artifacts.ArtifactStore._atomic
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main() -> None:
    directory = os.path.realpath(tempfile.mkdtemp(prefix="petrus-posix-bench"))
    try:
        os.mkdir(os.path.join(directory, "real"))
        os.mkdir(os.path.join(directory, "real", "a"))
        Path(directory, "real", "file").write_bytes(b"x")
        os.symlink("real", os.path.join(directory, "link"))
        held = os.open(os.path.join(directory, "bench.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        root = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        other = os.path.join(directory, "other.lock")
        symlinked = os.path.join(directory, "link", "a", "..", "file")
        state = Path(directory, "state.json")
        payload = b"x" * 1024

        def try_unlock():
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(held, fcntl.LOCK_UN)

        def open_try_close():
            fd = os.open(other, os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.close(fd)

        report("flock.tryLock-unlock", try_unlock)
        report("flock.open-tryLock-close", open_try_close)
        report("path.resolve-symlinked", lambda: str(Path(symlinked).resolve()))
        report("path.expanduser-resolve", lambda: str(Path(symlinked).expanduser().resolve()))
        report("at.stat-nofollow", lambda: os.stat("link", dir_fd=root, follow_symlinks=False).st_ino)
        report("atomic.write-1KiB-fsync", lambda: atomic(state, payload))
        report("resource.max_rss_mb", max_rss_mb)
        os.close(held)
        os.close(root)
    finally:
        shutil.rmtree(directory)


if __name__ == "__main__":
    main()
