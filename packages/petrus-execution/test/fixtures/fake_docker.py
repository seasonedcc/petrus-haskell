#!/usr/bin/env python3
"""A hermetic stand-in for the subset of the ``docker`` CLI Petrus drives.

State lives under ``$DOCKER_FAKE_STATE`` (a directory).  Containers are
records in ``state.json``; each container's filesystem is a host directory
whose ``workspace`` child stands in for ``/workspace``.  ``docker exec`` runs
the requested argv on the host in its own session, so cancellation and
timeouts exercise real process groups.  Semantics mirrored from Docker:

* ``kill --signal TERM`` reaches only PID 1, which (as ``sh``) ignores it;
* ``kill`` (SIGKILL) and ``stop`` end every exec and leave the container
  stopped (inspect ``State.Running`` false), ``rm --force`` removes it;
* an exec killed by a signal exits ``128 + signal``.

Fault injection (all optional, read from the environment):

* ``DOCKER_FAKE_FAIL=<subcommand>:<n>`` makes the n-th and later calls of
  that subcommand fail with exit status 1;
* ``DOCKER_FAKE_RM_NOOP=1`` makes ``rm`` succeed without removing;
* ``DOCKER_FAKE_BIND=1`` gives new containers a bind mount;
* ``DOCKER_FAKE_RUN_UNLABELED=1`` makes ``run`` drop the operation label;
* ``DOCKER_FAKE_LOG=<path>`` appends ``{"argv", "env"}`` JSON lines.
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import uuid
from contextlib import contextmanager
from pathlib import Path

STATE = Path(os.environ["DOCKER_FAKE_STATE"])
ATTACH = "rm -rf /workspace && mkdir /workspace && tar -xf - -C /workspace"
EXPORT = ["tar", "-cf", "-", "-C", "/workspace", "."]


@contextmanager
def state():
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / "lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = STATE / "state.json"
        data = json.loads(path.read_text()) if path.exists() else {"containers": {}, "calls": {}}
        yield data
        temporary = STATE / "state.json.tmp"
        temporary.write_text(json.dumps(data))
        temporary.replace(path)


def fail(message: str, code: int = 1) -> None:
    sys.stderr.write(message + "\n")
    sys.exit(code)


def injected(subcommand: str) -> None:
    rule = os.environ.get("DOCKER_FAKE_FAIL", "")
    with state() as data:
        count = data["calls"].get(subcommand, 0) + 1
        data["calls"][subcommand] = count
    for item in filter(None, rule.split(",")):
        name, _, threshold = item.partition(":")
        if name == subcommand and count >= int(threshold or "1"):
            fail(f"fake docker: injected {subcommand} failure")


def filesystem(container: str) -> Path:
    return STATE / "fs" / container


def kill_execs(record: dict, sig: int) -> None:
    for group in record.get("execs", []):
        try:
            os.killpg(group, sig)
        except ProcessLookupError:
            pass


def guest_path(container: str, path: str) -> Path:
    if path == "/workspace" or path.startswith("/workspace/"):
        return filesystem(container) / path.lstrip("/")
    fail(f"fake docker: unsupported guest path {path!r}")
    raise AssertionError


def command_ps(args: list[str]) -> None:
    label = None
    while args:
        flag = args.pop(0)
        if flag == "--filter":
            label = args.pop(0)[len("label="):]
    key, _, value = (label or "").partition("=")
    with state() as data:
        for container, record in data["containers"].items():
            if label is None or record["labels"].get(key) == value:
                print(container[:12])


def resolve(data: dict, reference: str) -> str | None:
    matches = [name for name in data["containers"] if name.startswith(reference)]
    return matches[0] if len(matches) == 1 else None


def command_inspect(args: list[str]) -> None:
    with state() as data:
        container = resolve(data, args[0])
        if container is None:
            fail(f"Error: No such object: {args[0]}")
        record = data["containers"][container]
    print(
        json.dumps(
            [
                {
                    "Id": container,
                    "Mounts": record["mounts"],
                    "State": {"Running": record["running"]},
                    "Config": {"Labels": record["labels"], "Image": record["image"]},
                }
            ]
        )
    )


def command_run(args: list[str]) -> None:
    labels = {}
    positional = []
    while args:
        flag = args.pop(0)
        if flag == "--label":
            key, _, value = args.pop(0).partition("=")
            labels[key] = value
        elif flag in ("--workdir", "--entrypoint"):
            args.pop(0)
        elif flag == "--detach":
            pass
        else:
            positional.append(flag)
            positional.extend(args)
            break
    container = uuid.uuid4().hex + uuid.uuid4().hex
    if os.environ.get("DOCKER_FAKE_RUN_UNLABELED"):
        labels.pop("run.petrus.operation", None)
    (filesystem(container) / "workspace").mkdir(parents=True)
    mounts = [{"Type": "bind", "Source": "/host", "Destination": "/host"}] if os.environ.get("DOCKER_FAKE_BIND") else []
    with state() as data:
        data["containers"][container] = {
            "labels": labels,
            "running": True,
            "image": positional[0],
            "mounts": mounts,
            "execs": [],
        }
    print(container)


def command_exec(args: list[str]) -> None:
    workdir = "/workspace"
    names = []
    while args[0].startswith("-"):
        flag = args.pop(0)
        if flag == "--workdir":
            workdir = args.pop(0)
        elif flag == "--env":
            names.append(args.pop(0))
    reference, argv = args[0], args[1:]
    with state() as data:
        container = resolve(data, reference)
        if container is None:
            fail(f"Error response from daemon: No such container: {reference}")
        if not data["containers"][container]["running"]:
            fail(f"Error response from daemon: container {container} is not running")
    workspace = filesystem(container) / "workspace"
    if argv == ["sh", "-c", ATTACH]:
        shutil.rmtree(workspace, ignore_errors=True)
        workspace.mkdir()
        with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as archive:
            archive.extractall(workspace)
        return
    if argv == EXPORT:
        with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.GNU_FORMAT) as archive:
            archive.add(workspace, arcname=".")
        return
    environment = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOSTNAME": container[:12]}
    environment.update({name: os.environ[name] for name in names if name in os.environ})
    process = subprocess.Popen(argv, cwd=guest_path(container, workdir), env=environment, start_new_session=True)
    with state() as data:
        record = data["containers"].get(container)
        if record is None or not record["running"]:
            os.killpg(process.pid, signal.SIGKILL)
        else:
            record["execs"].append(process.pid)
    code = process.wait()
    with state() as data:
        record = data["containers"].get(container)
        if record is not None and process.pid in record["execs"]:
            record["execs"].remove(process.pid)
    sys.exit(code if code >= 0 else 128 - code)


def command_kill(args: list[str]) -> None:
    sig = "KILL"
    if args[0] == "--signal":
        args.pop(0)
        sig = args.pop(0)
    with state() as data:
        container = resolve(data, args[0])
        if container is None:
            fail(f"Error response from daemon: No such container: {args[0]}")
        record = data["containers"][container]
        if not record["running"]:
            fail(f"Error response from daemon: cannot kill container: {args[0]}: container {container} is not running")
        if sig in ("KILL", "9", "SIGKILL"):
            kill_execs(record, signal.SIGKILL)
            record["running"] = False
    print(args[0])


def command_stop(args: list[str]) -> None:
    with state() as data:
        container = resolve(data, args[0])
        if container is None:
            fail(f"Error response from daemon: No such container: {args[0]}")
        record = data["containers"][container]
        kill_execs(record, signal.SIGKILL)
        record["running"] = False
    print(args[0])


def command_rm(args: list[str]) -> None:
    reference = [arg for arg in args if not arg.startswith("-")][0]
    if os.environ.get("DOCKER_FAKE_RM_NOOP"):
        print(reference)
        return
    with state() as data:
        container = resolve(data, reference)
        if container is None:
            fail(f"Error response from daemon: No such container: {reference}")
        kill_execs(data["containers"].pop(container), signal.SIGKILL)
    shutil.rmtree(filesystem(container), ignore_errors=True)
    print(reference)


def main() -> None:
    args = sys.argv[1:]
    log = os.environ.get("DOCKER_FAKE_LOG")
    if log:
        with open(log, "a") as handle:
            handle.write(json.dumps({"argv": args, "env": dict(os.environ)}) + "\n")
    subcommand = args.pop(0)
    injected(subcommand)
    handlers = {
        "ps": command_ps,
        "inspect": command_inspect,
        "run": command_run,
        "exec": command_exec,
        "kill": command_kill,
        "stop": command_stop,
        "rm": command_rm,
        "info": lambda _args: print("fake docker"),
    }
    if subcommand not in handlers:
        fail(f"fake docker: unsupported subcommand {subcommand!r}")
    handlers[subcommand](args)


if __name__ == "__main__":
    main()
