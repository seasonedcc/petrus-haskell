"""Extract the JavaScript fixtures embedded in the reference test_pi.py verbatim.

Usage: python extract.py <petrus>/tests/petrus/agenticus/runtime/test_pi.py test/fixtures/pi
"""

import ast
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
out = Path(sys.argv[2])
tree = ast.parse(source_path.read_text())
markers = {
    "framed_tool_sdk.mjs": "export async function createAgentSession(options) {\n  const state={messages:[]}; const listeners=[];",
    "subscription_sdk.mjs": 'const EXPECTED_AUTH="__EXPECTED_AUTH__"',
    "forged_known_tool_helper.mjs": 'id:"forged",method:"workspace_test"',
    "forged_unknown_tool_helper.mjs": 'method:"future_tool"',
    "wrong_auth_helper.mjs": "  __TERMINAL__\n});",
}
found = {}
for node in ast.walk(tree):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        for name, marker in markers.items():
            if marker in node.value:
                if name in found and found[name] != node.value:
                    raise SystemExit(f"ambiguous fixture {name}")
                found[name] = node.value
missing = set(markers) - set(found)
if missing:
    raise SystemExit(f"missing fixtures {sorted(missing)}")
out.mkdir(parents=True, exist_ok=True)
for name, value in sorted(found.items()):
    (out / name).write_text(value)
    print(name, len(value))
