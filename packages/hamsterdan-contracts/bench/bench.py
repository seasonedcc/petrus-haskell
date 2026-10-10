"""Python side of the hamsterdan-contracts benchmarks (same inputs as Main.hs).

    upstream/hamsterdan/.venv/bin/python packages/hamsterdan-contracts/bench/bench.py

(or ``uv run --project upstream/hamsterdan --frozen python ...``). Results and
the Haskell side are in RESULTS.md.

Prints the mean time per operation (best of 5 timeit repeats).
"""

from __future__ import annotations

import ast
import json
import timeit
from pathlib import Path

from pydantic import TypeAdapter

from hamsterdan.contracts.readiness_v5 import GateFact, Snapshot

inputs = json.loads((Path(__file__).parent / "inputs.json").read_text(encoding="utf-8"))
snapshot_bytes = inputs["snapshot"].encode()
gate_bytes = inputs["gate_fact"].encode()
snapshot_adapter = TypeAdapter(Snapshot)
gate_adapter = TypeAdapter(GateFact)
snapshot = snapshot_adapter.validate_json(snapshot_bytes)
gate = gate_adapter.validate_json(gate_bytes)
kind = inputs["entry_kind"]
entry_body = repr(gate.body)


def dumped(adapter, value) -> bytes:
    return json.dumps(adapter.dump_python(value, mode="json"), ensure_ascii=False, separators=(",", ":")).encode()


CASES = {
    "contract decode Snapshot (validate_json)": lambda: snapshot_adapter.validate_json(snapshot_bytes),
    "contract encode Snapshot (dump + json.dumps)": lambda: dumped(snapshot_adapter, snapshot),
    "contract decode GateFact (validate_json)": lambda: gate_adapter.validate_json(gate_bytes),
    "contract encode GateFact (dump + json.dumps)": lambda: dumped(gate_adapter, gate),
    "literal print dashboard entry (f'{kind}:{body}')": lambda: f"{kind}:{gate.body}",
    "literal print digest (sorted items repr)": lambda: f"{kind}:{sorted(gate.body.items())!r}",
    "literal parse dashboard entry (literal_eval)": lambda: ast.literal_eval(entry_body),
}


def main() -> None:
    for name, case in CASES.items():
        number = 20000
        best = min(timeit.repeat(case, number=number, repeat=5)) / number
        print(f"{name:55s} {best * 1e6:9.3f} us")


if __name__ == "__main__":
    main()
