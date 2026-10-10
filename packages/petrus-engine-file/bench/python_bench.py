"""Time petrus-engine's fileVersion 2 loader on the same workloads as ``bench/Main.hs``.

Run from the repository root with the pinned reference's virtual environment:

    upstream/petrus-engine/.venv/bin/python packages/petrus-engine-file/bench/python_bench.py

Inputs (``bench/Main.hs`` builds the same texts, byte for byte; both print
their sizes):

- ``chain-N``: one file with N+1 places, N transitions and about 2.1N arcs,
  written on one line with keys out of canonical order, float coordinates,
  labels, weights, read arcs, delays and a layout entry per node;
- ``mounted-K``: a root file mounting the ``chain-10`` net K times through
  ``refs`` (K+1 files read, K mounts inlined), with an arc into each mount.

Steps:

- ``parse``: ``FlatNetFile.model_validate_json(text)``;
- ``to_json``: ``file.to_json()`` on the parsed file;
- ``format``: ``reformat_content(text, indent=2, max_inline=120)``, the
  ``petrus-format-json`` transform;
- ``load``: ``FlatNet.from_filename(path).to_schema()`` from files on disk.

Each line prints the median of several runs after one warm-up, in
milliseconds.
"""

from __future__ import annotations

import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True

from petrus.cli.format_json import reformat_content  # noqa: E402
from petrus.schema import FlatNet, FlatNetFile  # noqa: E402


def chain_text(n: int, name: str = "chain") -> str:
    places = ", ".join(
        f'"p{i}": {{"initial": 1}}' if i == 0 else f'"p{i}": {{"label": "Place {i}"}}' for i in range(n + 1)
    )
    transitions = ", ".join(
        f'"t{i}": {{"handler": "step", "delay": 30}}' if i % 5 == 0 else f'"t{i}": {{"handler": "step"}}'
        for i in range(n)
    )
    arcs = []
    for i in range(n):
        arcs.append(f'{{"source": "p{i}", "target": "t{i}"}}')
        if i % 3 == 0:
            arcs.append(f'{{"target": "p{i + 1}", "source": "t{i}", "weight": 2}}')
        else:
            arcs.append(f'{{"source": "t{i}", "target": "p{i + 1}"}}')
        if i % 7 == 3:
            arcs.append(f'{{"source": "p0", "target": "t{i}", "kind": "read"}}')
    layout = ", ".join(
        [f'"p{i}": [{i * 150}.0, 50.0]' for i in range(n + 1)] + [f'"t{i}": [{i * 150 + 75}.5, 150.0]' for i in range(n)]
    )
    return (
        f'{{"net": "{name}", "places": {{{places}}}, "transitions": {{{transitions}}}, '
        f'"arcs": [{", ".join(arcs)}], "viewState": {{"layout": {{{layout}}}, "zoom": 1.0, "pan": [0, 0]}}}}'
    )


def mounted_text(k: int) -> str:
    refs = ", ".join(f'"u{i}": {{"ref": "unit.json"}}' for i in range(k))
    transitions = ", ".join(f'"feed{i}": {{}}' for i in range(k))
    arcs = ", ".join(
        f'{{"source": "hub", "target": "feed{i}"}}, {{"source": "feed{i}", "target": "u{i}.p0"}}' for i in range(k)
    )
    return (
        f'{{"net": "root", "refs": {{{refs}}}, "places": {{"hub": {{"initial": 1}}}}, '
        f'"transitions": {{{transitions}}}, "arcs": [{arcs}]}}'
    )


def timed(name: str, action, repeats: int) -> None:
    action()
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        action()
        samples.append(time.perf_counter() - start)
    print(f"{name:24} {statistics.median(samples) * 1000:12.3f} ms   (n={repeats})")
    sys.stdout.flush()


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "unit.json").write_text(chain_text(10, "unit"))
        for n, repeats in ((10, 200), (1_000, 20), (10_000, 5)):
            text = chain_text(n)
            path = root / f"chain-{n}.json"
            path.write_text(text)
            parsed = FlatNetFile.model_validate_json(text)
            print(f"chain-{n}: {len(text.encode())} bytes in, {len(parsed.to_json().encode())} bytes out")
            timed(f"chain-{n}/parse", lambda: FlatNetFile.model_validate_json(text), repeats)
            timed(f"chain-{n}/to_json", lambda: parsed.to_json(), repeats)
            timed(f"chain-{n}/format", lambda: reformat_content(text, indent=2, max_inline=120), repeats)
            timed(f"chain-{n}/load", lambda: FlatNet.from_filename(path).to_schema(), repeats)
        for k, repeats in ((10, 100), (100, 20), (1_000, 5)):
            text = mounted_text(k)
            path = root / f"mounted-{k}.json"
            path.write_text(text)
            schema = FlatNet.from_filename(path).to_schema()
            print(f"mounted-{k}: {len(text.encode())} bytes in, {len(schema.arcs)} arcs")
            timed(f"mounted-{k}/load", lambda: FlatNet.from_filename(path).to_schema(), repeats)


if __name__ == "__main__":
    main()
