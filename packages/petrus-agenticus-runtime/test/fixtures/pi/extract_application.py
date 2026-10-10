"""Extract the JavaScript fixtures embedded in the reference test_pi_application.py verbatim.

The two protocol scripts are f-strings over ``delta = base64.b64encode(b"[]")``;
they are rendered with that exact value.

Usage: python extract_application.py <petrus>/tests/petrus/agenticus/runtime/test_pi_application.py test/fixtures/pi
"""

import ast
import base64
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
out = Path(sys.argv[2])
tree = ast.parse(source_path.read_text())
delta = base64.b64encode(b"[]").decode()
markers = {
    "application_coding.mjs": "export class ModelRuntime {",
    "application_core_guard.mjs": "if (observation === 'blocked') {",
    "application_core_projection.mjs": "const callId=`read-${prompts[0].content[0].text}`;",
    "application_ai.mjs": "export const createProvider=()=>{throw Error('network')};",
    "application_post_terminal.mjs": '"id":"late"',
    "application_post_abort.mjs": "let first=true;",
    "application_noncanonical.mjs": '"transcript":"W10=="',
}


def render(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        parts = []
        for value in node.values:
            if isinstance(value, ast.Constant):
                parts.append(value.value)
            elif isinstance(value, ast.FormattedValue) and isinstance(value.value, ast.Name) and value.value.id == "delta":
                parts.append(delta)
            else:
                return None
        return "".join(parts)
    return None


inner = {id(child) for node in ast.walk(tree) if isinstance(node, ast.JoinedStr) for child in node.values}
found = {}
for node in ast.walk(tree):
    if id(node) in inner:
        continue
    value = render(node)
    if value is None:
        continue
    for name, marker in markers.items():
        if marker in value:
            if name in found and found[name] != value:
                raise SystemExit(f"ambiguous fixture {name}")
            found[name] = value
missing = set(markers) - set(found)
if missing:
    raise SystemExit(f"missing fixtures {sorted(missing)}")
out.mkdir(parents=True, exist_ok=True)
for name, value in sorted(found.items()):
    (out / name).write_text(value)
    print(name, len(value))
