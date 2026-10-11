"""Write the reference's JSON Schema of the Net definition and Net document.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-impetus/differential/json_schema.py

The script writes ``net_definition_v3.schema.json`` and
``net_document_v1.schema.json`` next to itself (or into the directory given
as the first argument): ``NetDefinitionV3.model_json_schema()`` and
``NetDocumentV1.model_json_schema()``, each as ``json.dumps(schema,
indent=2)`` and a newline. ``JsonSchemaSpec`` asserts that the Haskell
port's ``netDefinitionV3JsonSchema`` and ``netDocumentV1JsonSchema`` spell
the same bytes. Deterministic.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from petrus.impetus.net_definition import NetDefinitionV3
from petrus.impetus.net_document import NetDocumentV1


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
    for name, model in (("net_definition_v3", NetDefinitionV3), ("net_document_v1", NetDocumentV1)):
        text = json.dumps(model.model_json_schema(), indent=2) + "\n"
        (out / f"{name}.schema.json").write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
