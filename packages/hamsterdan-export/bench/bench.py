"""The reference side of the hamsterdan-export benchmark, in process.

Usage: ``python -I -B bench.py STATE_DIR OUT_ROOT REPOSITORY PULL_REQUEST``

Prints ``ready``, then for each line read from stdin runs
``hamsterdan.host.export.main`` once over STATE_DIR into a fresh
``OUT_ROOT/run-N`` (removed afterwards, outside the timed region), with
stdout and stderr captured, and prints that run's wall time in seconds.
``bench/Main.hs`` drives it one run at a time, alternating with its own
in-process runs, so both sides meet the same file-system state.
"""

from __future__ import annotations

import contextlib
import io
import shutil
import sys
import time
from pathlib import Path

from hamsterdan.host.export import main


def serve(state: str, out_root: Path, repository: str, pull_request: str) -> None:
    print("ready", flush=True)
    for index, _ in enumerate(sys.stdin):
        out = out_root / f"run-{index}"
        argv = ["--state-dir", state, "--out", str(out), "--repository", repository, "--pull-request", pull_request]
        sink_out, sink_err = io.StringIO(), io.StringIO()
        start = time.perf_counter()
        with contextlib.redirect_stdout(sink_out), contextlib.redirect_stderr(sink_err):
            code = main(argv)
        elapsed = time.perf_counter() - start
        if code != 0:
            raise SystemExit(f"export exited {code}: {sink_err.getvalue()}")
        shutil.rmtree(out)
        print(repr(elapsed), flush=True)


if __name__ == "__main__":
    state, out_root, repository, pull_request = sys.argv[1:5]
    serve(state, Path(out_root), repository, pull_request)
