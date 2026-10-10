"""Run the reference's CV5 Fabric demo with one split role played by Haskell.

    python fabric_demo_mixed.py --dsn DSN --haskell-role {parent,child,both} --haskell-exe PATH

Loads upstream/petrus/scripts/cv5-fabric-demo.py unchanged and replaces only
its ``start_role``, so the chosen role runs as ``PATH --internal-role`` (the
Haskell cv5-fabric-demo) with the same IMPETUS_DEMO_* environment. Everything
else — bootstrap, discovery, the offline pending count, the duplicate
request, the Python replay of the Haskell-written History, the crash resume,
the local run and the shape comparison — is the reference's own code, and so
are the printed lines.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
UPSTREAM = HERE.parents[3] / "upstream" / "petrus"


def load_demo():
    spec = importlib.util.spec_from_file_location("cv5_fabric_demo", UPSTREAM / "scripts" / "cv5-fabric-demo.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["cv5_fabric_demo"] = module
    spec.loader.exec_module(module)
    return module


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsn", required=True)
    parser.add_argument("--haskell-role", choices=("parent", "child", "both"), required=True)
    parser.add_argument("--haskell-exe", required=True)
    args = parser.parse_args()
    demo = load_demo()
    original = demo.start_role

    def start_role(dsn, role, parent, child, credential):
        if args.haskell_role not in (role, "both"):
            return original(dsn, role, parent, child, credential)
        env = {
            **os.environ,
            "IMPETUS_DEMO_DSN": dsn,
            "IMPETUS_DEMO_ROLE": role,
            "IMPETUS_DEMO_PARENT": parent,
            "IMPETUS_DEMO_CHILD": child,
            "IMPETUS_DEMO_CREDENTIAL": credential,
        }
        return subprocess.Popen(
            [args.haskell_exe, "--internal-role"],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    demo.start_role = start_role
    demo.run(args.dsn)


if __name__ == "__main__":
    main()
