"""Print, as JSON, the class name and recorded failure text the pinned
reference gives the Python exceptions that have a Haskell counterpart.

Run with the reference's interpreter from the root of the pinned upstream
Petrus checkout (``DifferentialSpec`` does). For every ``errno`` the platform
knows: ``type(OSError(n, os.strerror(n))).__name__`` (CPython's subclass for
that errno, the drive span's ``error_type``) and
``firing_failure_text(OSError(n, os.strerror(n)))`` (``FiringFailed.error``
and ``firing_failed.error``); then the other mapped classes.
"""

from __future__ import annotations

import errno
import json
import os
import sys

from petrus.impetus.instance import firing_failure_text


def entry(error: BaseException) -> dict:
    return {"error_type": type(error).__name__, "text": firing_failure_text(error)}


def main() -> None:
    errnos = [{"errno": number, **entry(OSError(number, os.strerror(number)))} for number in sorted(errno.errorcode)]
    try:
        1 / 0
    except ZeroDivisionError as raised:
        division = raised
    others = {
        "user_error": entry(OSError("boom")),
        "keyboard_interrupt": entry(KeyboardInterrupt()),
        "divide_by_zero": entry(division),
        "exit_failure": entry(SystemExit(3)),
        "exit_success": entry(SystemExit(0)),
    }
    json.dump({"errnos": errnos, "others": others}, sys.stdout)


if __name__ == "__main__":
    main()
