"""The Python side of the petrus-dst benchmarks (bench/Bench.hs).

Run from upstream/petrus:

    PYTHONPATH=. uv run --frozen python ../../packages/petrus-dst/scripts/bench.py

Each workload is timed as the median, over 7 rounds, of the mean time per
iteration within a round of at least 0.5 s (``timeit``'s autorange shape).
"""

from __future__ import annotations

import json
import statistics
import sys
import tempfile
import timeit
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from generated_stories import author  # noqa: E402

from petrus.testing.dst import (  # noqa: E402
    ChoiceAuthority,
    ChoiceStreams,
    ProcessRunSpec,
    _process_result,
    decode_artifact,
    digest_json,
    encode_artifact,
)

FIXTURES = Path("tests/dst/fixtures")
FOREIGN = {"generated-runtime-semantic-coverage-v1.json", "projection-crash-recovery-v1.json"}
DATA = Path(__file__).resolve().parent.parent / "test" / "data"


def measure(name: str, call) -> None:
    timer = timeit.Timer(call)
    number, elapsed = timer.autorange()
    while elapsed < 0.5:
        number *= 2
        elapsed = timer.timeit(number)
    rounds = [timer.timeit(number) / number for _ in range(7)]
    median = statistics.median(rounds)
    spread = statistics.pstdev(rounds)
    unit, scale = ("ms", 1e3) if median >= 1e-3 else ("us", 1e6)
    print(f"{name:40s} {median * scale:10.3f} {unit}  (stdev {spread * scale:.3f} {unit}, {number} per round)")


def main() -> int:
    fixtures = [
        path.read_bytes().rstrip(b"\n") for path in sorted(FIXTURES.glob("*.json")) if path.name not in FOREIGN
    ]
    artifacts = [decode_artifact(payload) for payload in fixtures]
    largest = json.loads(max(fixtures, key=len))
    scripts = [story["script"] for story in json.loads((DATA / "generated-stories.json").read_text())["stories"]]
    children = json.loads((DATA / "process-vectors.json").read_text())["children"]
    queue = next(child for child in children if child["scenario_id"] == "queue-story")
    spec = ProcessRunSpec.model_validate_json(queue["spec"])
    directory = tempfile.TemporaryDirectory(prefix="petrus-dst-bench-")
    progress = Path(directory.name) / "progress.jsonl"
    progress.write_bytes(queue["progress"].encode())

    def draws() -> int:
        streams = ChoiceStreams(1729)
        return sum(streams.index(ChoiceAuthority.WORKLOAD, 1000) for _ in range(1000))

    print(f"python {sys.version.split()[0]}")
    measure("codec/decode+encode 51 fixtures", lambda: [encode_artifact(decode_artifact(p)) for p in fixtures])
    measure("codec/encode 51 fixtures", lambda: [encode_artifact(a) for a in artifacts])
    measure("digest_json largest fixture", lambda: digest_json(largest))
    measure("1000 workload draws", draws)
    measure("author+replay 400 generated scripts", lambda: [author(script) for script in scripts])
    measure(
        "fold queue-story progress",
        lambda: _process_result(spec, 0, "exited", False, progress).model_dump_json(),
    )
    directory.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
