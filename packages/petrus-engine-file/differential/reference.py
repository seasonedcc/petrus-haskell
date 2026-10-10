"""Run petrus-engine's fileVersion 2 loader on corpus cases and report what it does.

A case is a directory of files plus a list of operations:

- ``{"op": "file", "path": P, "indent": I, "max_inline": M}``:
  ``FlatNetFile.from_filename(P).to_json(indent=I, max_inline=M)``.
- ``{"op": "format", "path": P, "indent": I, "max_inline": M}``:
  ``reformat_content(Path(P).read_text(), indent=I, max_inline=M)`` (the
  format CLI's transform).
- ``{"op": "load", "path": P}``: ``FlatNet.from_filename(P)`` and its
  ``to_schema()``.
- ``{"op": "dict", "root": P, "deps": {ref: P | null}}``:
  ``FlatNet.from_dict`` over ``json.loads`` of those files, and its
  ``to_schema()``.

Each result is ``{"ok": ...}`` or ``{"error": [class name, str(exception)]}``,
and a case's expectation is the list of each result's compact ``json.dumps``.

Usage (from the repository root) prints one ``{"name", "expect"}`` line per
case:

    upstream/petrus-engine/.venv/bin/python \\
        packages/petrus-engine-file/differential/reference.py CORPUS.json
"""

import base64
import json
import os
import sys
import tempfile
from pathlib import Path

from petrus.cli.format_json import reformat_content
from petrus.schema import FlatNet, FlatNetFile


def path_value(path):
    return list(path)


def delay_value(delay):
    if delay is None:
        return None
    return [delay.days, delay.seconds, delay.microseconds]


def place_value(path, pdef):
    return [path_value(path), pdef.initial, pdef.label, pdef.interface, pdef.metadata]


def transition_value(path, tdef):
    return [path_value(path), tdef.handler, tdef.guard, tdef.label, tdef.metadata, delay_value(tdef.delay)]


def view_state_value(vs):
    waypoints = None
    if vs.arcWaypoints is not None:
        waypoints = [[k, [list(p) for p in ps]] for k, ps in vs.arcWaypoints.items()]
    return [
        waypoints,
        [[path_value(p), list(xy)] for p, xy in vs.layout.items()],
        vs.zoom,
        list(vs.pan),
        [path_value(p) for p in vs.selected],
    ]


def net_value(net):
    return {
        "net": net.net,
        "arcs": [
            [path_value(a.source), path_value(a.target), a.kind.value, a.weight, a.metadata] for a in net.arcs
        ],
        "places": [place_value(p, d) for p, d in net.places.items()],
        "transitions": [transition_value(p, d) for p, d in net.transitions.items()],
        "view_states": [[name, view_state_value(vs)] for name, vs in net.view_states.items()],
        "ref_origins": [[name, [path_value(p) for p in ps]] for name, ps in net.ref_origins.items()],
    }


def schema_value(schema):
    return {
        "name": schema.name,
        "places": [place_value(p, d) for p, d in schema.places.items()],
        "transitions": [transition_value(p, d) for p, d in schema.transitions.items()],
        "arcs": [
            [path_value(s), path_value(t), a.kind.value, a.weight, a.metadata] for (s, t), a in schema.arcs.items()
        ],
        "ref_to_subnets": [[name, [path_value(p) for p in ps]] for name, ps in schema.ref_to_subnets.items()],
    }


def outcome(thunk):
    try:
        return {"ok": thunk()}
    except Exception as exc:  # noqa: BLE001 - every refusal is data here
        return {"error": [type(exc).__name__, str(exc)]}


def resolved(make_net):
    net = make_net()
    return {"net": net_value(net), "schema": outcome(lambda: schema_value(net.to_schema()))}


def run_op(op):
    kind = op["op"]
    if kind == "file":
        return outcome(
            lambda: FlatNetFile.from_filename(op["path"]).to_json(indent=op["indent"], max_inline=op["max_inline"])
        )
    if kind == "format":

        def fmt():
            changed, formatted = reformat_content(
                Path(op["path"]).read_text(), indent=op["indent"], max_inline=op["max_inline"]
            )
            return [changed, formatted]

        return outcome(fmt)
    if kind == "load":
        return outcome(lambda: resolved(lambda: FlatNet.from_filename(op["path"])))
    if kind == "dict":

        def from_dict():
            root = json.loads(Path(op["root"]).read_text())
            deps = {
                ref: (None if name is None else json.loads(Path(name).read_text())) for ref, name in op["deps"].items()
            }
            return resolved(lambda: FlatNet.from_dict(root, deps))

        return outcome(from_dict)
    raise ValueError(f"unknown op {kind!r}")


def materialize(case, directory):
    for name in case.get("dirs", []):
        (directory / name).mkdir(parents=True, exist_ok=True)
    for name, content in case["files"].items():
        target = directory / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if "text" in content:
            target.write_bytes(content["text"].encode("utf-8", "surrogatepass"))
        else:
            target.write_bytes(base64.b64decode(content["base64"]))


def run_case(case):
    here = os.getcwd()
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        materialize(case, directory)
        os.chdir(directory)
        try:
            return [run_op(op) for op in case["ops"]]
        finally:
            os.chdir(here)


def expectation(case):
    """The case's results as the compact JSON texts the corpus records."""
    return [json.dumps(result, separators=(",", ":")) for result in run_case(case)]


def main():
    corpus = json.loads(Path(sys.argv[1]).read_text())
    for case in corpus["cases"]:
        sys.stdout.write(json.dumps({"name": case["name"], "expect": expectation(case)}) + "\n")


if __name__ == "__main__":
    main()
