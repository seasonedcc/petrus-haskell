"""The reference side of the hamsterdan-operator benchmark, in process.

Usage: ``python -I -B bench.py WORKLOADS.json``

``bench/Main.hs`` writes WORKLOADS.json: for each workload the scripted
answers of its fake runner, keyed by the space-joined command line (the
nth call of a command line gets the nth answer, the last one repeating).
This script prints ``ready``, then for each line read from stdin:

* ``check NAME``: runs workload NAME once and prints its result as
  ``json.dumps(result, sort_keys=True)``, which ``bench/Main.hs`` compares
  with its own before timing anything;
* ``run NAME``: runs workload NAME once and prints its wall time in seconds.

The workloads:

* ``inspect``: ``operator.inspect`` with the hero-review checks;
* ``authority``: ``operator.inspect_authority`` (``collaboration-clear``);
* ``refs``: ``operator._parse_setup_refs`` over a large ref projection;
* ``setup``: ``operator.qualification_setup`` along its whole success path
  with a fake setup runner. Its two input files are written, and the spent
  marker removed, before each run, outside the timed region.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

from hamsterdan import operator


def scripted(answers: dict[str, list[str]]):
    calls: dict[str, int] = {}

    def answer(key: str) -> str:
        values = answers[key]
        index = calls.get(key, 0)
        calls[key] = index + 1
        return values[min(index, len(values) - 1)]

    return answer


def runner(answers: dict[str, list[str]]):
    answer = scripted(answers)

    def run(command, cwd=None):
        return subprocess.CompletedProcess(command, 0, answer(" ".join(command)), "")

    return run


def setup_runner(answers: dict[str, list[str]]):
    answer = scripted(answers)

    def run(command, cwd, env, input_bytes):
        return subprocess.CompletedProcess(command, 0, answer(" ".join(command)).encode(), b"")

    return run


def workload(name: str, spec: dict):
    if name == "inspect":
        return lambda: operator.inspect(7, runner(spec["answers"]), expect_hero_review=True)
    if name == "authority":
        return lambda: operator.inspect_authority(9, "collaboration-clear", runner(spec["answers"]))
    if name == "refs":
        raw = spec["raw"].encode()
        return lambda: operator._parse_setup_refs(raw)
    if name == "setup":
        private = Path(spec["private"])

        def run():
            return operator.qualification_setup(
                private / "credential", private / "target.json", private / "push-spent",
                runner=setup_runner(spec["answers"]),
            )

        return run
    raise SystemExit(f"unknown workload {name}")


def prepare(name: str, spec: dict) -> None:
    if name != "setup":
        return
    private = Path(spec["private"])
    (private / "push-spent").unlink(missing_ok=True)
    for file, content in (("credential", spec["credential"]), ("target.json", spec["target"])):
        path = private / file
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(content)
        os.chmod(path, 0o600)


def main() -> None:
    workloads = json.loads(Path(sys.argv[1]).read_text())
    print("ready", flush=True)
    for line in sys.stdin:
        command, name = line.split()
        spec = workloads[name]
        prepare(name, spec)
        run = workload(name, spec)
        if command == "check":
            print(json.dumps(run(), sort_keys=True), flush=True)
            continue
        start = time.perf_counter()
        run()
        elapsed = time.perf_counter() - start
        print(repr(elapsed), flush=True)


if __name__ == "__main__":
    main()
