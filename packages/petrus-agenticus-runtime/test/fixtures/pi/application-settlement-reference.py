"""The pinned reference's outcome for every application_settlement.mjs scenario.

Run by ``PiApplicationSpec`` with the pinned interpreter from
``upstream/petrus`` (its working directory):
``python -I -c 'runpy…' application-settlement-reference.py FIXTURE NODE TMP``.
Each scenario runs upstream's own ``pi_application._SubprocessClient.run``
over the forged helper, on the reference test module's ``Rig``, and records
``[exception class, settlement code, TypeError message or ""]``. The code is
the one ``PiApplicationRuntimeAdapter._execute`` assigns while the operation
is current: a ``RuntimeProtocolError`` keeps its code, any other exception
settles ``runtime-failed``. It prints ``{scenario: [...]}`` as JSON.
"""

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, "tests/petrus/agenticus/runtime")

import test_pi_application as fixtures  # noqa: E402

import petrus.agenticus.runtime.pi_application as app  # noqa: E402
from petrus.agenticus.hands.contract import ToolMethod  # noqa: E402
from petrus.agenticus.runtime.operation import RuntimeProtocolError  # noqa: E402

SCENARIOS = (
    "exit-timeout",
    "exit-nonzero",
    "type-list",
    "type-dict",
    "code-list",
    "code-dict",
    "code-list-extra",
    "method-list",
    "method-dict",
    "method-number",
    "method-list-unready",
    "method-list-long-id",
)


def outcome(fixture: str, node: str, tmp: Path, scenario: str) -> list[str]:
    helper = tmp / f"{scenario}.mjs"
    helper.write_text(fixture.replace("__SCENARIO__", scenario))
    rig = fixtures.Rig(tmp / scenario, "gondolin", fixtures.Plan())
    invocation = rig.invocation(scenario, (ToolMethod.WORKSPACE_READ,))
    private_root = tmp / f"private-{scenario}"
    private_root.mkdir(mode=0o700)
    client = app._SubprocessClient(  # noqa: SLF001
        node=node,
        coding_entrypoint="/unused/coding",
        core_entrypoint="/unused/core",
        ai_entrypoint="/unused/ai",
        helper=helper,
        private_root=private_root,
        config=rig.adapter._config,  # noqa: SLF001
        invocation=invocation,
        prior=None,
        api_key=fixtures.KEY.decode(),
    )
    try:
        client.run(rig.gateway, invocation, lambda: True, time.monotonic() + 2)
        result = ["completed", "turn-completed", ""]
    except RuntimeProtocolError as error:
        result = ["RuntimeProtocolError", error.code, ""]
    except Exception as error:  # noqa: BLE001 - _execute's own except Exception
        result = [type(error).__name__, "runtime-failed", str(error) if isinstance(error, TypeError) else ""]
    finally:
        client.close()
        rig.attachment.settle()
    return result


def main() -> None:
    fixture = Path(sys.argv[1]).read_text()
    node, tmp = sys.argv[2], Path(sys.argv[3])
    print(json.dumps({scenario: outcome(fixture, node, tmp, scenario) for scenario in SCENARIOS}))


if __name__ == "__main__":
    main()
