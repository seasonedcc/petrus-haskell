"""The reference side of ProviderAnswersSpec: what upstream makes of a provider's answer.

    docker OPERATION      DockerEnvironment().lookup(OPERATION), with `docker` from PATH
    request SOCKET        GondolinEnvironment._request over the Unix socket SOCKET
    read DIRECTORY        GondolinEnvironment._read(DIRECTORY)

Prints one JSON line: {"lease": [lease_id, state]} or {"lease": null}, {"response": ...},
{"registry": ...}, or {"raised": [the exception's classes, most derived first], "message": str(e)}.
"""

import json
import sys
from pathlib import Path

from petrus.motus._execution.gondolin import GondolinEnvironment
from petrus.motus._execution.providers import DockerEnvironment


def answer(command: str, argument: str) -> dict:
    if command == "docker":
        lease = DockerEnvironment().lookup(argument)
        return {"lease": None if lease is None else [lease.lease_id, lease.state.value]}
    if command == "request":
        record = {"lease_id": "lease", "boot_token": "token", "socket": argument}
        return {"response": GondolinEnvironment._request(record, {"action": "status"})}
    if command == "read":
        return {"registry": GondolinEnvironment._read(Path(argument))}
    raise SystemExit(f"unknown command {command!r}")


def main() -> None:
    command, argument = sys.argv[1:]
    try:
        result = answer(command, argument)
    except Exception as error:
        classes = [cls.__name__ for cls in type(error).__mro__ if issubclass(cls, Exception)]
        result = {"raised": classes, "message": str(error)}
    sys.stdout.write(json.dumps(result, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
