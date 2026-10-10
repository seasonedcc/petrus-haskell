"""Create the deterministic workspace trees both benchmark harnesses read.

    python3 packages/petrus-execution/bench/make_workloads.py WORKDIR

Layout (contents are seeded pseudo-random bytes, so runs are repeatable):

    WORKDIR/many-small   10 000 files x 1 KiB in 100 subdirectories
    WORKDIR/medium       1 000 files x 64 KiB in 10 subdirectories
    WORKDIR/one-large    1 file x 256 MiB
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

WORKLOADS = {
    "many-small": (10_000, 1024, 100),
    "medium": (1_000, 64 * 1024, 10),
    "one-large": (1, 256 * 1024 * 1024, 1),
}


def main() -> None:
    root = Path(sys.argv[1])
    for name, (count, size, directories) in WORKLOADS.items():
        base = root / name
        if base.exists():
            continue
        generator = random.Random(name)
        for index in range(count):
            directory = base / f"d{index % directories:03d}"
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f"f{index:05d}.bin").write_bytes(generator.randbytes(size))
        print(f"created {base}")


if __name__ == "__main__":
    main()
