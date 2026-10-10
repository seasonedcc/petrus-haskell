"""Continue (or start) a corpus custody session over an existing installation.

    custody_interop.py CORPUS SEED WORKDIR START STOP

Runs steps ``[START, STOP)`` of the corpus session with seed ``SEED`` against
the installation under ``WORKDIR`` with the reference implementation, resuming
whatever another implementation left there, and prints one record per step as
JSON (the same records ``custody_corpus.py`` stores).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from custody_corpus import run_steps


def main() -> None:
    corpus_path, seed, workdir, start, stop = sys.argv[1:]
    corpus = json.loads(Path(corpus_path).read_text())
    session = next(item for item in corpus["sessions"] if item["seed"] == int(seed))
    records = run_steps(Path(workdir), session["steps"], int(start), int(stop))
    print(json.dumps(records, sort_keys=True))


if __name__ == "__main__":
    main()
