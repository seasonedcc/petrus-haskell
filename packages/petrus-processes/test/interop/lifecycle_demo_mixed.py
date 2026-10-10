"""Run the reference's CV5.DS2 lifecycle demo with parts played by Haskell.

    python lifecycle_demo_mixed.py --dsn DSN [--haskell-child EXE] [--haskell-spawn-worker EXE]

Loads upstream/petrus/scripts/cv5-lifecycle-demo.py unchanged and replaces:

* ``run_child`` (with --haskell-child): the child host subprocess is
  ``EXE --internal-child`` (the Haskell cv5-lifecycle-demo) with the same
  IMPETUS_LIFECYCLE_* environment;
* ``SpawnActivity`` (with --haskell-spawn-worker): the Python parent
  Engine's ``process.spawn`` Activity is executed by ``EXE
  --internal-spawn-worker`` against the same registry tables, with the same
  parent credential and workspace key, so the reference provisioner's
  ``ensure_calls`` count includes the worker's.

Everything else, including every assertion and printed line, is the
reference's own ``run``.
"""

from __future__ import annotations

import argparse
import atexit
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UPSTREAM = HERE.parents[3] / "upstream" / "petrus"


def load_demo():
    spec = importlib.util.spec_from_file_location("cv5_lifecycle_demo", UPSTREAM / "scripts" / "cv5-lifecycle-demo.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["cv5_lifecycle_demo"] = module
    spec.loader.exec_module(module)
    return module


class WorkerSpawn:
    """A ``SpawnActivity`` stand-in that forwards to a spawn worker."""

    def __init__(self, exe: str, provisioner):
        self.provisioner = provisioner
        self.process = subprocess.Popen(
            [exe, "--internal-spawn-worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
        )
        atexit.register(self.stop)

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait()

    def __call__(self, invocation, *, context):
        request = {
            "dsn": self.provisioner.dsn,
            "parent": self.provisioner.parent,
            "parent_credential": self.provisioner.parent_credential,
            "workspace_key": self.provisioner.workspace_key.hex(),
            "invocation": {
                "activity": invocation.activity,
                "input": json.loads(json.dumps(_thaw(invocation.input))),
                "correlation": invocation.correlation,
                "idempotency": invocation.idempotency,
            },
        }
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        answer = json.loads(self.process.stdout.readline())
        self.provisioner.ensure_calls += answer.get("ensure_calls", 0)
        if "ok" not in answer:
            raise RuntimeError(f"spawn worker: {answer.get('error')}")
        return answer["ok"]


def _thaw(value):
    if hasattr(value, "items"):
        return {key: _thaw(item) for key, item in value.items()}
    if isinstance(value, tuple):
        return [_thaw(item) for item in value]
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsn", required=True)
    parser.add_argument("--haskell-child")
    parser.add_argument("--haskell-spawn-worker")
    args = parser.parse_args()
    demo = load_demo()
    if args.haskell_child:

        def run_child(dsn, parent, child, credential, outcome):
            env = {
                **os.environ,
                "IMPETUS_LIFECYCLE_DSN": dsn,
                "IMPETUS_LIFECYCLE_PARENT": parent,
                "IMPETUS_LIFECYCLE_CHILD": child,
                "IMPETUS_LIFECYCLE_CHILD_CREDENTIAL": credential,
                "IMPETUS_LIFECYCLE_OUTCOME": outcome,
            }
            process = subprocess.run(
                [args.haskell_child, "--internal-child"], env=env, capture_output=True, text=True, timeout=45
            )
            if process.returncode:
                raise RuntimeError(f"child process failed: {process.stdout}\n{process.stderr}")

        demo.run_child = run_child
    if args.haskell_spawn_worker:
        demo.SpawnActivity = lambda _registry, provisioner: WorkerSpawn(args.haskell_spawn_worker, provisioner)
    demo.run(args.dsn)


if __name__ == "__main__":
    main()
