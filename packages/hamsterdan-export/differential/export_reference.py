"""The reference side of the hamsterdan-export differential tests.

Two modes, both run with the pinned upstream interpreter
(``scripts/upstream-python hamsterdan``):

``fixture ROOT NAME``
    Build the upstream test suite's own state directory
    (``tests/unit/host/test_export.py``'s ``state_dir`` and ``deliveries``
    helpers) under ROOT for the named variant, so the port is compared on
    exactly the fixtures the reference's tests use.

``run``
    Read a JSON list of cases from stdin, each ``{"cwd": ..., "argv":
    [...], "columns": ...}``, run ``hamsterdan.host.export.main(argv)`` for
    each in-process from that working directory, and print a JSON list of
    ``{"code", "stdout", "stderr"}``. An uncaught exception reports the
    last entry of its traceback (``traceback.format_exception_only``: the
    exception line, then the notes Python attached to it, such as
    ``json.dumps``'s ``when serializing ...``) and exit status 1, as the
    interpreter would. Standard output and error encode as the
    interpreter's do in a UTF-8 locale (strict, and ``backslashreplace``),
    and an argument holds an undecodable byte as ``surrogateescape``
    decodes it (``"\\udcff"``), as ``sys.argv`` does.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve()
UPSTREAM = HERE.parents[3] / "upstream" / "hamsterdan"
sys.path.insert(0, str(UPSTREAM / "tests" / "unit" / "host"))

import test_export as upstream  # noqa: E402

from hamsterdan.host.export import agent_operation_id, main  # noqa: E402


def fixture(root: Path, name: str) -> None:
    root.mkdir(parents=True, exist_ok=True)
    if name == "default":
        upstream.state_dir(root)
    elif name == "sessionless":
        upstream.state_dir(
            root,
            sessionless=frozenset(
                {agent_operation_id(upstream.REVIEW_OPERATION, 1), agent_operation_id(upstream.MUTATION_OPERATION, 1)}
            ),
        )
    elif name == "orphan":
        upstream.state_dir(root, bodies=(agent_operation_id(upstream.REVIEW_OPERATION, 1), "pi:" + "a" * 64))
    elif name == "repeated":
        repeated = [record for record in upstream._history() if record.get("activity") == "git_gate"]
        repeated[0] = {**repeated[0], "occurrence": 8, "instant": 9}
        upstream.state_dir(root, history=[*upstream._history(), *repeated])
    elif name == "newer":
        upstream.state_dir(
            root, history=[*upstream._history(), upstream._record("SomethingNewer", occurrence=9, instant=9, detail="x")]
        )
    elif name.startswith("omit-"):
        upstream.state_dir(root, omit=frozenset({name.removeprefix("omit-")}))
    elif name == "deliveries":
        upstream.state_dir(root)
        upstream.deliveries(
            root,
            {
                f"{upstream.ADMITTED_DELIVERY}-pull_request.json": upstream.raw_delivery(
                    upstream.ADMITTED_DELIVERY, "pull_request", "opened"
                ),
                f"{upstream.ADMITTED_DELIVERY}-pull_request-original-99.json": upstream.raw_delivery(
                    upstream.ADMITTED_DELIVERY, "pull_request", "opened"
                ),
                f"{upstream.OTHER_PR_DELIVERY}-workflow_run.json": upstream.raw_delivery(
                    upstream.OTHER_PR_DELIVERY, "workflow_run", "completed"
                ),
                "_deliveries-index.json": [{"guid": upstream.ADMITTED_DELIVERY}],
            },
        )
    else:
        raise SystemExit(f"unknown fixture {name}")


def stdio(errors: str) -> io.TextIOWrapper:
    """A stream encoding as the interpreter's own: stdout strict UTF-8
    (a lone surrogate raises ``UnicodeEncodeError`` at the ``print``),
    stderr UTF-8 with ``backslashreplace``."""
    return io.TextIOWrapper(io.BytesIO(), encoding="utf-8", errors=errors, write_through=True)


def written(stream: io.TextIOWrapper) -> str:
    stream.flush()
    return stream.buffer.getvalue().decode("utf-8")


def run_case(case: dict[str, object]) -> dict[str, object]:
    out, err = stdio("strict"), stdio("backslashreplace")
    previous = os.getcwd()
    columns = case.get("columns")
    if columns is None:
        os.environ.pop("COLUMNS", None)
    else:
        os.environ["COLUMNS"] = str(columns)
    os.chdir(str(case["cwd"]))
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = main(list(case["argv"]))
            except SystemExit as exit_:
                code = exit_.code if isinstance(exit_.code, int) else 1
            except Exception as error:  # noqa: BLE001 - the interpreter's own report
                err.write("".join(traceback.format_exception_only(error)))
                code = 1
    finally:
        os.chdir(previous)
    return {"code": code, "stdout": written(out), "stderr": written(err)}


def run() -> None:
    cases = json.load(sys.stdin)
    json.dump([run_case(case) for case in cases], sys.stdout)


if __name__ == "__main__":
    if sys.argv[1] == "fixture":
        fixture(Path(sys.argv[2]), sys.argv[3])
    elif sys.argv[1] == "run":
        run()
    else:
        raise SystemExit(f"unknown mode {sys.argv[1]}")
