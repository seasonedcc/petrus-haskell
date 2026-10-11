"""Upstream (Python) side of the petrus-execution benchmarks.

Run with the upstream virtualenv from the repository root (see
``bench/RESULTS.md``):

    upstream/petrus/.venv/bin/python packages/petrus-execution/bench/python_bench.py \
        WORKDIR packages/petrus-execution/test/fixtures/fake_gondolin.mjs

Set PETRUS_BENCH_ONLY=<workload> to run a single archive workload.
Prints one JSON object per line: {"name", "median_ms", "min_ms", "runs"}.
The workloads and iteration counts mirror ``bench/Main.hs`` exactly.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import statistics
import sys
import tempfile
import time
from pathlib import Path

from petrus.motus._execution.gondolin import GondolinEnvironment
from petrus.motus.execution import Command, EnvironmentSpec
from petrus.motus.execution.archive import extract_workspace_archive, validate_workspace_archive, workspace_archive
from petrus.motus.execution.providers import LocalProcessEnvironment

RUNS = {"many-small": 7, "medium": 7, "one-large": 7}
HANDSHAKES = 1000
EXECUTIONS = 50
SPAWNS = 100


def report(name: str, samples: list[float], runs: int) -> None:
    print(
        json.dumps(
            {"name": name, "median_ms": statistics.median(samples) * 1000, "min_ms": min(samples) * 1000, "runs": runs}
        ),
        flush=True,
    )


def timed(action) -> float:
    started = time.perf_counter()
    action()
    return time.perf_counter() - started


def archive_benchmarks(workdir: Path) -> None:
    only = os.environ.get("PETRUS_BENCH_ONLY")
    for name, runs in RUNS.items():
        if only and only != name:
            continue
        source = workdir / name
        data = workspace_archive(source)
        pack = [timed(lambda: hashlib.sha256(workspace_archive(source)).hexdigest()) for _ in range(runs)]
        report(f"archive/{name}/pack+sha256", pack, runs)
        validate = [timed(lambda: validate_workspace_archive(data)) for _ in range(runs)]
        report(f"archive/{name}/validate", validate, runs)
        extract = []
        for index in range(runs):
            target = workdir / f"extract-py-{name}-{index}"
            extract.append(timed(lambda: extract_workspace_archive(data, target)))
            shutil.rmtree(target)
        report(f"archive/{name}/extract", extract, runs)


def process_benchmarks() -> None:
    import subprocess

    def run() -> None:
        subprocess.run(("/usr/bin/true",), capture_output=True, timeout=5, check=True)

    run()
    samples = [timed(run) for _ in range(SPAWNS)]
    report("process/run-captured", samples, SPAWNS)


def local_benchmarks() -> None:
    """``LocalProcessEnvironment.execute`` in an attached territory: the cwd
    containment checks, the spawn of ``sh`` in the territory, and collecting
    its output."""
    environment = LocalProcessEnvironment()
    lease = environment.create("bench", EnvironmentSpec())
    try:
        with tempfile.TemporaryDirectory(prefix="petrus-lb-") as temporary:
            source = Path(temporary)
            (source / "input").write_text("host")
            archive = workspace_archive(source)
        attachment = environment.attach(lease, archive, "digest")
        command = Command(("/bin/sh", "-c", "/bin/cat input"))
        environment.execute(attachment, command)
        samples = [timed(lambda: environment.execute(attachment, command)) for _ in range(EXECUTIONS)]
        report("local/execute", samples, EXECUTIONS)
    finally:
        environment.destroy(lease)


def sidecar_benchmarks(fake_sdk: str) -> None:
    root = Path(tempfile.mkdtemp(prefix="petrus-gb-", dir="/tmp"))
    try:
        environment = GondolinEnvironment(root / "g", sdk_module=fake_sdk, lease_ttl=900)
        lease = environment.provision("bench", EnvironmentSpec(image="fake-image"))
        try:
            record = environment._read(environment._directory("bench"))
            assert record is not None
            for _ in range(20):
                GondolinEnvironment._request(record, {"action": "handshake"})
            samples = [timed(lambda: GondolinEnvironment._request(record, {"action": "handshake"})) for _ in range(HANDSHAKES)]
            report("sidecar/handshake-round-trip", samples, HANDSHAKES)
            source = root / "workspace"
            source.mkdir()
            attachment = environment.attach(lease, workspace_archive(source), "digest")
            command = Command(("/bin/sh", "-c", "true"))
            environment.execute(attachment, command)
            samples = [timed(lambda: environment.execute(attachment, command)) for _ in range(EXECUTIONS)]
            report("sidecar/execute-round-trip", samples, EXECUTIONS)
        finally:
            environment.destroy(lease)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main() -> None:
    workdir = Path(sys.argv[1])
    archive_benchmarks(workdir)
    process_benchmarks()
    local_benchmarks()
    if len(sys.argv) > 2:
        sidecar_benchmarks(str(Path(sys.argv[2]).resolve()))


if __name__ == "__main__":
    main()
