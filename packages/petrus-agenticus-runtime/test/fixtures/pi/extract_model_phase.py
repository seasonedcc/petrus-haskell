"""Extract the JavaScript fixture embedded in the reference test_pi_model_phase.py verbatim.

Usage: python extract_model_phase.py <petrus>/tests/petrus/agenticus/runtime/test_pi_model_phase.py test/fixtures/pi
"""

import ast
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
out = Path(sys.argv[2])
tree = ast.parse(source_path.read_text())
markers = {"model_phase_coding.mjs": "export const convertToLlm=messages=>messages;"}
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
