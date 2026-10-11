"""Turn a recorded journey tape into the shape a live recording has.

    python3 live_style.py SOURCE TARGET

Standard library only. A live host pumps on its own clock, so its tape
(``host_seams.LiveRecorder``) says ``converge`` where a journey's says
``process`` and ``pump``. TARGET is SOURCE with every ``process`` and
``pump`` step replaced by a ``converge`` at the same clock (consecutive
ones at one clock merged) and ``"source"`` marked ``live-style``. Replaying
it exercises what replaying a live tape does: ``converge`` steps, and a
replay server with ``--sticky-reads``. Both hosts must then agree with each
other (not with the recording, whose pumps were finer).
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import tape as tapes  # noqa: E402


def live_steps(steps: list[dict]) -> list[dict]:
    shaped: list[dict] = []
    for step in steps:
        if step["op"] in ("process", "pump"):
            step = {"op": "converge", "clock": step["clock"]}
            if shaped and shaped[-1]["op"] == "converge" and shaped[-1]["clock"] == step["clock"]:
                continue
        else:
            step = {key: value for key, value in step.items() if key != "seq"}
        shaped.append(step)
    return [{"seq": index, **step} for index, step in enumerate(shaped)]


def main() -> None:
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    meta = tapes.read_meta(source)
    target.mkdir(parents=True, exist_ok=True)
    meta["source"] = "live-style " + str(meta.get("source", ""))
    (target / "meta.json").write_text(json.dumps(meta, sort_keys=True, indent=1) + "\n")
    for name in ("github.jsonl", "agents.jsonl", "publisher.jsonl"):
        if (source / name).exists():
            shutil.copyfile(source / name, target / name)
    steps = live_steps(tapes.read(source, "steps.jsonl"))
    (target / "steps.jsonl").write_text("".join(json.dumps(step, ensure_ascii=False) + "\n" for step in steps))


if __name__ == "__main__":
    main()
