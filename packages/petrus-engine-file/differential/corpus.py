"""Build the fileVersion 2 differential corpus and record the reference's verdicts.

The corpus (``corpus.json`` next to this script) is a list of cases. Each case
is a directory of files and a list of operations (see ``reference.py``), and
``expect`` records what petrus-engine does for each operation. The cases come
from four places:

- ``upstream/...``: the nets the upstream loader, resolver and formatter tests
  build, written as the tests' ``persist_net`` fixture writes them;
- ``viewer/...``: petrus-viewer's example net, and every valid single-file
  corpus net opened and saved again by the viewer's own TypeScript
  (``viewer_resave.mjs``);
- ``edge/...``: hand-written variations over every field, coercion, refusal,
  error text, JSON spelling and layout threshold;
- ``fuzz/...``: seeded random nets, some mutated (wrong types, missing fields,
  corrupted bytes).

It is deterministic: rerunning it reproduces the committed file. From the
repository root (Node 22.18 or later on PATH for the viewer resaves):

    upstream/petrus-engine/.venv/bin/python packages/petrus-engine-file/differential/corpus.py
"""

import argparse
import base64
import json
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.dont_write_bytecode = True

from petrus.schema import FlatArc, FlatNetFile, RefEntry, ViewState  # noqa: E402
from petrus.types import ArcKind  # noqa: E402

from reference import expectation  # noqa: E402

REPO = HERE.parent.parent.parent
CASES = []


def content(data):
    """A file's content for the corpus: text when it is UTF-8, else base64."""
    if isinstance(data, str):
        data = data.encode("utf-8", "surrogatepass")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return {"base64": base64.b64encode(data).decode("ascii")}
    return {"text": text}


def case(name, files, ops, dirs=()):
    CASES.append(
        {
            "name": name,
            "files": {path: content(data) for path, data in files.items()},
            "dirs": list(dirs),
            "ops": ops,
        }
    )


def file_op(path="net.json", indent=2, max_inline=100):
    return {"op": "file", "path": path, "indent": indent, "max_inline": max_inline}


def format_op(path="net.json", indent=2, max_inline=120):
    return {"op": "format", "path": path, "indent": indent, "max_inline": max_inline}


def load_op(path="net.json"):
    return {"op": "load", "path": path}


def dict_op(root="net.json", deps=None):
    return {"op": "dict", "root": root, "deps": deps or {}}


def single_ops(path="net.json", extra=()):
    return [file_op(path), file_op(path, 4, 60), format_op(path), load_op(path), dict_op(path), *extra]


def single(name, text, extra=()):
    case(name, {"net.json": text}, single_ops(extra=extra))


def multi(name, files, root="net.json", deps=None):
    """A multi-file net: both loaders, plus each file on its own."""
    ops = [load_op(root), dict_op(root, deps if deps is not None else {}), file_op(root), format_op(root)]
    case(name, files, ops)


def persisted(net_file):
    """Written as the upstream tests' persist_net fixture writes it."""
    return net_file.to_json()


def dumps(obj, **kwargs):
    return json.dumps(obj, **kwargs)


# ── upstream ──────────────────────────────────────────────────────────────


def upstream_cases():
    # tests/test_flatnet_loader.py
    multi(
        "upstream/loader/reads_mounted_sources_with_nested_and_reused_refs",
        {
            "main.json": persisted(
                FlatNetFile(
                    net="main",
                    refs={
                        "leg": {"ref": "./lib.json"},
                        "direct_leaf": {"ref": "./leaf.json"},
                        "via_mid": {"ref": "./mid.json"},
                    },
                )
            ),
            "lib.json": persisted(FlatNetFile(net="lib", places={"ready": {}}, refs={"sub": {"ref": "./sublib.json"}})),
            "sublib.json": persisted(FlatNetFile(net="sublib", places={"done": {}})),
            "leaf.json": persisted(FlatNetFile(net="leaf", places={"x": {}})),
            "mid.json": persisted(FlatNetFile(net="mid", refs={"leaf": {"ref": "./leaf.json"}})),
        },
        root="main.json",
        deps={
            "./lib.json": "lib.json",
            "./sublib.json": "sublib.json",
            "./leaf.json": "leaf.json",
            "./mid.json": "mid.json",
        },
    )
    multi(
        "upstream/loader/duplicate_net_names_from_different_files_fail_loud",
        {
            "main.json": persisted(FlatNetFile(net="main", refs={"a": {"ref": "./a.json"}, "b": {"ref": "./b.json"}})),
            "a.json": persisted(FlatNetFile(net="dup", places={"a": {}})),
            "b.json": persisted(FlatNetFile(net="dup", places={"b": {}})),
        },
        root="main.json",
        deps={"./a.json": "a.json", "./b.json": "b.json"},
    )
    duplicate = FlatNetFile(net="dup", places={"p": {}})
    multi(
        "upstream/loader/duplicate_net_names_from_identical_different_files_are_reused",
        {
            "main.json": persisted(FlatNetFile(net="main", refs={"a": {"ref": "./a.json"}, "b": {"ref": "./b.json"}})),
            "a.json": persisted(duplicate),
            "b.json": persisted(duplicate),
        },
        root="main.json",
        deps={"./a.json": "a.json", "./b.json": "b.json"},
    )
    multi(
        "upstream/loader/missing_referenced_file_raises",
        {"main.json": persisted(FlatNetFile(net="main", refs={"leg": {"ref": "./gone.json"}}))},
        root="main.json",
    )
    root = {"fileVersion": "2", "net": "main", "refs": {"leg": {"ref": "./lib.json"}}}
    lib = {"fileVersion": "2", "net": "lib", "places": {"ready": {}}, "refs": {"sub": {"ref": "./sublib.json"}}}
    sublib = {"fileVersion": "2", "net": "sublib", "places": {"done": {}}}
    multi(
        "upstream/loader/reads_three_net_hierarchy_as_mounted_source_map",
        {"main.json": dumps(root), "lib.json": dumps(lib), "sublib.json": dumps(sublib)},
        root="main.json",
        deps={"./lib.json": "lib.json", "./sublib.json": "sublib.json"},
    )
    multi(
        "upstream/loader/missing_source_ref_names_ref_filename",
        {"main.json": dumps({"fileVersion": "2", "net": "main", "refs": {"leg": {"ref": "./missing.json"}}})},
        root="main.json",
    )
    multi(
        "upstream/loader/missing_transitive_source_ref_names_ref_filename",
        {
            "main.json": dumps({"fileVersion": "2", "net": "main", "refs": {"leg": {"ref": "./lt.json"}}}),
            "lt.json": dumps({"fileVersion": "2", "net": "lt", "refs": {"payment": {"ref": "./net_payment.json"}}}),
        },
        root="main.json",
        deps={"./lt.json": "lt.json"},
    )
    multi(
        "upstream/loader/duplicate_net_names_with_conflicting_layouts_fail_loud",
        {
            "main.json": dumps(
                {"fileVersion": "2", "net": "main", "refs": {"a": {"ref": "./a.json"}, "b": {"ref": "./b.json"}}}
            ),
            "a.json": dumps({"fileVersion": "2", "net": "dup", "viewState": {"layout": {"p": [0.0, 0.0]}}}),
            "b.json": dumps({"fileVersion": "2", "net": "dup", "viewState": {"layout": {"p": [9.0, 9.0]}}}),
        },
        root="main.json",
        deps={"./a.json": "a.json", "./b.json": "b.json"},
    )
    multi(
        "upstream/loader/duplicate_resolved_mount_netpath_fails_loud",
        {
            "main.json": dumps(
                {
                    "fileVersion": "2",
                    "net": "main",
                    "refs": {"a": {"ref": "./lib.json"}, "a.b": {"ref": "./direct.json"}},
                }
            ),
            "lib.json": dumps({"fileVersion": "2", "net": "lib", "refs": {"b": {"ref": "./nested.json"}}}),
            "nested.json": dumps({"fileVersion": "2", "net": "nested"}),
            "direct.json": dumps({"fileVersion": "2", "net": "direct"}),
        },
        root="main.json",
        deps={"./lib.json": "lib.json", "./nested.json": "nested.json", "./direct.json": "direct.json"},
    )
    multi(
        "upstream/loader/cyclic_reference_fails_loud",
        {
            "a.json": dumps({"fileVersion": "2", "net": "a", "refs": {"to_b": {"ref": "./b.json"}}}),
            "b.json": dumps({"fileVersion": "2", "net": "b", "refs": {"to_a": {"ref": "./a.json"}}}),
        },
        root="a.json",
        deps={"./a.json": "a.json", "./b.json": "b.json"},
    )
    multi(
        "upstream/loader/flat_net_from_filename_coordinates_source_loader_and_resolver",
        {
            "main.json": persisted(
                FlatNetFile(net="main", places={"start": {"initial": 1}}, refs={"leg": {"ref": "./lib.json"}})
            ),
            "lib.json": persisted(
                FlatNetFile(
                    net="lib",
                    places={"ready": {}},
                    transitions={"go": {}},
                    arcs=[FlatArc(source="ready", target="go")],
                    refs={"sub": {"ref": "./sublib.json"}},
                )
            ),
            "sublib.json": persisted(
                FlatNetFile(
                    net="sublib",
                    places={"done": {}},
                    transitions={"finish": {}},
                    arcs=[FlatArc(source="done", target="finish")],
                )
            ),
        },
        root="main.json",
        deps={"./lib.json": "lib.json", "./sublib.json": "sublib.json"},
    )
    multi(
        "upstream/loader/flat_net_from_dict_coordinates_source_loader_and_resolver",
        {
            "main.json": dumps(
                {
                    "fileVersion": "2",
                    "net": "main",
                    "places": {"start": {"initial": 1}},
                    "refs": {"leg": {"ref": "./lib.json"}},
                }
            ),
            "lib.json": dumps(
                {
                    "fileVersion": "2",
                    "net": "lib",
                    "places": {"ready": {}},
                    "transitions": {"go": {}},
                    "arcs": [{"source": "ready", "target": "go"}],
                }
            ),
        },
        root="main.json",
        deps={"./lib.json": "lib.json"},
    )

    # tests/test_flatnet_file_refs.py
    single("upstream/file_refs/from_filename_reads_json", persisted(FlatNetFile(net="main")))
    single(
        "upstream/file_refs/ref_keys_are_netpaths_after_validation",
        persisted(FlatNetFile(net="main", refs={"leg.sub": RefEntry(ref="./lib.json")})),
    )
    single(
        "upstream/file_refs/empty_ref_mount_netpath_is_rejected",
        dumps({"net": "main", "refs": {"": {"ref": "./lib.json"}}}),
    )

    # tests/test_flatnet_resolution.py, with the explicit mounts as refs
    def lib_net(name="lib"):
        return FlatNetFile(
            net=name,
            places={"ready": {}, "done": {}},
            transitions={"process": {}},
            arcs=[FlatArc(source="ready", target="process"), FlatArc(source="process", target="done")],
            viewState=ViewState(layout={"ready": (0.0, 0.0), "process": (50.0, 0.0)}),
        )

    single(
        "upstream/resolution/ref_less_source_preserves_structure",
        persisted(
            FlatNetFile(
                net="main",
                places={"a": {"initial": 1}, "b": {}},
                transitions={"x": {}},
                arcs=[FlatArc(source="a", target="x"), FlatArc(source="x", target="b")],
                viewState=ViewState(layout={"a": (1.0, 2.0)}),
            )
        ),
    )
    single(
        "upstream/resolution/ref_less_source_without_view_state_has_empty_view_states",
        persisted(FlatNetFile(net="bare", places={"a": {}}, transitions={}, arcs=[])),
    )
    multi(
        "upstream/resolution/mounted_places_transitions_and_arcs_inlined_and_prefixed",
        {
            "main.json": persisted(
                FlatNetFile(
                    net="main",
                    places={"start": {"initial": 1}},
                    viewState=ViewState(layout={"leg": (10.0, 10.0)}),
                    refs={"leg": {"ref": "lib.json"}},
                )
            ),
            "lib.json": persisted(lib_net()),
        },
        root="main.json",
        deps={"lib.json": "lib.json"},
    )
    multi(
        "upstream/resolution/nested_mounted_path_is_inlined_and_recorded",
        {
            "main.json": persisted(FlatNetFile(net="main", refs={"leg": {"ref": "mid.json"}})),
            "mid.json": persisted(FlatNetFile(net="mid", places={"hold": {}}, refs={"sub": {"ref": "leaf.json"}})),
            "leaf.json": persisted(lib_net("leaf")),
        },
        root="main.json",
        deps={"mid.json": "mid.json", "leaf.json": "leaf.json"},
    )
    multi(
        "upstream/resolution/inlined_arc_options_are_preserved",
        {
            "main.json": persisted(FlatNetFile(net="main", refs={"leg": {"ref": "guarded.json"}})),
            "guarded.json": persisted(
                FlatNetFile(
                    net="guarded",
                    places={"busy": {}, "done": {}},
                    transitions={"acquire": {}},
                    arcs=[
                        FlatArc(source="acquire", target="done"),
                        FlatArc(
                            source="busy", target="acquire", kind=ArcKind.INHIBITOR, weight=2, metadata={"note": "x"}
                        ),
                    ],
                )
            ),
        },
        root="main.json",
        deps={"guarded.json": "guarded.json"},
    )
    multi(
        "upstream/resolution/same_ref_mounted_twice_yields_one_view_state_entry",
        {
            "main.json": persisted(
                FlatNetFile(
                    net="main",
                    viewState=ViewState(layout={"a": (0.0, 0.0), "b": (100.0, 0.0)}),
                    refs={"a": {"ref": "t.json"}, "b": {"ref": "t.json"}},
                )
            ),
            "t.json": persisted(lib_net("leg_template")),
        },
        root="main.json",
        deps={"t.json": "t.json"},
    )
    for name, net in [
        (
            "flat_net_projects_absolute_netpaths",
            dict(
                net="test",
                places={"a": {"initial": 1}, "b": {}},
                transitions={"x": {"handler": "do_x"}},
                arcs=[FlatArc(source="a", target="x"), FlatArc(source="x", target="b")],
            ),
        ),
        (
            "dotted_ids_become_nested_netpaths",
            dict(
                net="root",
                places={"start": {"initial": 1}, "sub.inner": {}},
                transitions={"sub.step": {"handler": "on_step"}},
                arcs=[FlatArc(source="sub.inner", target="sub.step")],
            ),
        ),
        (
            "arc_options_survive_projection",
            dict(
                net="test",
                places={"busy": {}, "done": {}},
                transitions={"acquire": {}},
                arcs=[
                    FlatArc(source="acquire", target="done"),
                    FlatArc(source="busy", target="acquire", kind=ArcKind.INHIBITOR, weight=2),
                ],
            ),
        ),
    ]:
        single(f"upstream/resolution/{name}", persisted(FlatNetFile(**net)))
    multi(
        "upstream/resolution/ref_to_subnets_built_from_ref_origins",
        {
            "main.json": persisted(FlatNetFile(net="main", refs={"leg": {"ref": "mylib.json"}})),
            "mylib.json": persisted(FlatNetFile(net="mylib")),
        },
        root="main.json",
        deps={"mylib.json": "mylib.json"},
    )

    # tests/test_json_formatter.py works on compact_json directly; its three
    # layouts (key order, nested containers break, whole floats) show up in
    # FlatNetFile.to_json as:
    single(
        "upstream/json_formatter/orders_root_and_nested_keys",
        dumps({"viewState": {"zoom": 2}, "places": {"p": {"label": "z", "initial": 1}}, "net": "n"}),
    )
    single(
        "upstream/json_formatter/breaks_containers_with_nested_values",
        dumps({"net": "n", "arcs": [{"source": "a", "target": "b"}]}),
    )
    single(
        "upstream/json_formatter/converts_whole_number_floats_to_ints",
        dumps({"net": "n", "viewState": {"zoom": 1.5, "pan": [1.0, 2.5]}}),
    )

    # tests/test_timed_transitions.py: a 30 minute schema delay.
    single(
        "upstream/timed/static_delay",
        dumps({"net": "timed", "transitions": {"wait": {"delay": 1800}, "fast": {}}}),
    )


# ── viewer ────────────────────────────────────────────────────────────────


def viewer_cases():
    sample = (REPO / "upstream/petrus-viewer/examples/sample-net.json").read_text()
    single("viewer/examples/sample-net", sample)
    # A file as the viewer saves it, with the viewer-only annotations.
    single(
        "viewer/annotations-and-waypoints",
        """{
  "fileVersion": "2",
  "net": "noted",
  "arcs": [
    {"source": "a", "target": "t"},
    {"source": "t", "target": "b", "metadata": {"color": "#ff0000"}}
  ],
  "places": {
    "a": {"initial": 2, "label": "A"},
    "b": {}
  },
  "transitions": {
    "t": {"handler": "do_t", "delay": 2.5}
  },
  "viewState": {
    "layout": {"a": [10, 20], "b": [30.5, 40], "t": [20, 20]},
    "arcWaypoints": {"t->b": [[25, 25], [27.5, 30]]},
    "annotations": {"note1": {"text": "hello", "x": 1, "y": 2}}
  }
}
""",
    )


def viewer_resaves():
    """Every valid single-file net, opened and saved by the viewer."""
    inputs = []
    for c in list(CASES):
        if c["name"].startswith("viewer/resaved/") or list(c["files"]) != ["net.json"]:
            continue
        text = c["files"]["net.json"].get("text")
        if text is None:
            continue
        try:
            FlatNetFile.model_validate_json(text)
        except Exception:  # noqa: BLE001 - only nets the reference accepts
            continue
        inputs.append({"name": c["name"], "text": text})
    script = HERE / "viewer_resave.mjs"
    out = subprocess.run(
        ["node", str(script)], input=json.dumps(inputs), capture_output=True, text=True, check=True
    ).stdout
    saved = json.loads(out)
    for item in inputs:
        result = saved[item["name"]]
        if "saved" in result:
            single(f"viewer/resaved/{item['name']}", result["saved"])


# ── edge ──────────────────────────────────────────────────────────────────


def edge_cases():
    full = {
        "fileVersion": "2",
        "net": "full",
        "arcs": [
            {"source": "p1", "target": "t1"},
            {"source": "t1", "target": "p2", "weight": 3, "metadata": {"k": [1, 2.5, None, True]}},
            {"source": "p2", "target": "t2", "kind": "inhibitor"},
            {"source": "p2", "target": "t1", "kind": "read", "weight": 1, "metadata": {}},
            {"source": "sub.p", "target": "sub.t", "kind": "normal"},
        ],
        "places": {
            "p1": {"initial": 5, "label": "Start", "interface": "input", "metadata": {"x": {"y": [1, {"z": None}]}}},
            "p2": {"initial": 0, "interface": "output"},
            "sub.p": {"interface": "awaiting", "label": None},
            "ctl": {"interface": "control", "metadata": None},
        },
        "transitions": {
            "t1": {"handler": "h1", "guard": "g1", "label": "T1", "metadata": {"a": 1}, "delay": 30},
            "t2": {"delay": 0.5},
            "sub.t": {"delay": "PT1H30M"},
            "t3": {"delay": "01:02:03.5"},
            "t4": {"delay": None, "handler": None},
        },
        "refs": {},
        "viewState": {
            "layout": {"p1": [0, 0], "t1": [100.25, -3], "sub": [1e3, 2e-3]},
            "zoom": 1.25,
            "pan": [-10, 20.5],
            "selected": ["p1", "sub.p"],
            "arcWaypoints": {"p1->t1": [[1, 2], [3.5, 4]], "empty": []},
        },
    }
    single("edge/full", dumps(full, indent=2))
    single("edge/full-compact", dumps(full, separators=(",", ":")))
    single("edge/full-unicode", dumps(full, ensure_ascii=False).replace('"Start"', '"Sta\\u00e9rt 日本 😀"'))
    single("edge/minimal", '{"net": "m"}')
    single("edge/minimal-canonical", '{\n  "fileVersion": "2",\n  "net": "m"\n}\n')
    single("edge/empty-net-name", '{"net": ""}')
    single("edge/dotted-net-name", '{"net": "a.b", "places": {"p": {}}, "arcs": [{"source": "p", "target": "p"}]}')
    single("edge/file-version-3", '{"fileVersion": "3", "net": "m"}')
    single("edge/file-version-1", '{"fileVersion": "1", "net": "m"}')
    single("edge/file-version-int", '{"fileVersion": 2, "net": "m"}')
    single("edge/extra-top-level-keys", '{"net": "m", "netSchema": {"x": 1}, "version": "1"}')
    single("edge/default-viewstate", '{"net": "m", "viewState": {}}')
    single(
        "edge/default-valued-viewstate",
        '{"net": "m", "viewState": {"zoom": 1, "pan": [0, -0.0], "layout": {}, "selected": [], "arcWaypoints": null}}',
    )
    single("edge/viewstate-null", '{"net": "m", "viewState": null}')
    single("edge/arcs-null", '{"net": "m", "arcs": null}')
    single("edge/places-null", '{"net": "m", "places": null}')

    # Required, types, and every error kind.
    for name, text in [
        ("missing-net", "{}"),
        ("top-level-list", "[]"),
        ("top-level-string", '"x"'),
        ("top-level-number", "1"),
        ("top-level-null", "null"),
        ("top-level-nan", "NaN"),
        ("top-level-infinity", "-Infinity"),
        ("net-int", '{"net": 1}'),
        ("net-null", '{"net": null}'),
        ("net-list", '{"net": ["a"]}'),
        ("net-bool", '{"net": true}'),
        ("arcs-object", '{"net": "m", "arcs": {}}'),
        ("arcs-string", '{"net": "m", "arcs": "ab"}'),
        ("arc-not-object", '{"net": "m", "arcs": [1, "x", null, []]}'),
        ("arc-missing-fields", '{"net": "m", "arcs": [{}]}'),
        ("arc-kind-invalid", '{"net": "m", "arcs": [{"source": "a", "target": "b", "kind": "weird"}]}'),
        ("arc-kind-int", '{"net": "m", "arcs": [{"source": "a", "target": "b", "kind": 1}]}'),
        ("arc-kind-upper", '{"net": "m", "arcs": [{"source": "a", "target": "b", "kind": "READ"}]}'),
        ("arc-weight-float-whole", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": 2.0}]}'),
        ("arc-weight-float-frac", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": 2.5}]}'),
        ("arc-weight-string", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": "3"}]}'),
        ("arc-weight-string-bad", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": "3x"}]}'),
        ("arc-weight-string-spaces", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": " 3_0 "}]}'),
        ("arc-weight-string-float", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": "3.0"}]}'),
        ("arc-weight-bool", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": true}]}'),
        ("arc-weight-null", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": null}]}'),
        ("arc-weight-zero", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": 0}]}'),
        ("arc-weight-negative", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": -7}]}'),
        (
            "arc-weight-big",
            '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": 123456789012345678901234567890}]}',
        ),
        ("arc-weight-big-float", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": 1e20}]}'),
        ("arc-weight-huge-float", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": 1e300}]}'),
        ("arc-weight-nan", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": NaN}]}'),
        ("arc-weight-inf", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": Infinity}]}'),
        ("arc-weight-1e999", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": 1e999}]}'),
        ("arc-metadata-list", '{"net": "m", "arcs": [{"source": "a", "target": "b", "metadata": [1]}]}'),
        ("arc-metadata-null", '{"net": "m", "arcs": [{"source": "a", "target": "b", "metadata": null}]}'),
        ("arc-extra-key", '{"net": "m", "arcs": [{"source": "a", "target": "b", "color": "red"}]}'),
        ("arc-source-int", '{"net": "m", "arcs": [{"source": 5, "target": "b"}]}'),
        ("arc-source-null", '{"net": "m", "arcs": [{"source": null, "target": "b"}]}'),
        ("arc-source-float", '{"net": "m", "arcs": [{"source": 1.5, "target": "b"}]}'),
        ("arc-source-bool", '{"net": "m", "arcs": [{"source": false, "target": "b"}]}'),
        ("arc-source-empty", '{"net": "m", "arcs": [{"source": "", "target": "b"}]}'),
        ("arc-source-dots", '{"net": "m", "arcs": [{"source": "a..b.", "target": ".b"}]}'),
        ("arc-source-list", '{"net": "m", "arcs": [{"source": ["x", "y"], "target": "b"}]}'),
        ("arc-source-list-empty", '{"net": "m", "arcs": [{"source": [], "target": "b"}]}'),
        ("arc-source-list-dotted", '{"net": "m", "arcs": [{"source": ["x.y"], "target": "b"}]}'),
        ("arc-source-list-int", '{"net": "m", "arcs": [{"source": ["x", 1], "target": "b"}]}'),
        ("arc-source-list-null", '{"net": "m", "arcs": [{"source": [null], "target": "b"}]}'),
        ("arc-source-list-nested", '{"net": "m", "arcs": [{"source": [["x"]], "target": "b"}]}'),
        ("arc-source-list-nested-dot", '{"net": "m", "arcs": [{"source": [["."]], "target": "b"}]}'),
        ("arc-source-list-nested-dotted", '{"net": "m", "arcs": [{"source": [["a.b"]], "target": "b"}]}'),
        ("arc-source-list-nested-int", '{"net": "m", "arcs": [{"source": [[1]], "target": "b"}]}'),
        ("arc-source-list-two-nested", '{"net": "m", "arcs": [{"source": ["a", ["x"]], "target": "b"}]}'),
        ("arc-source-list-empty-string", '{"net": "m", "arcs": [{"source": [""], "target": "b"}]}'),
        ("arc-source-dict", '{"net": "m", "arcs": [{"source": {"x": 1, "y": 2}, "target": "b"}]}'),
        ("arc-source-dict-dotted", '{"net": "m", "arcs": [{"source": {"x.y": 1}, "target": "b"}]}'),
        ("arc-source-dict-nested", '{"net": "m", "arcs": [{"source": [{"x": 1}], "target": "b"}]}'),
        ("arc-source-dict-nested-dot", '{"net": "m", "arcs": [{"source": [{".": 1}], "target": "b"}]}'),
        ("arc-target-list-nested", '{"net": "m", "arcs": [{"source": "a", "target": [["y"], "z"]}]}'),
        (
            "arc-both-errors",
            '{"net": 3, "arcs": [{"source": "a", "target": "b", "kind": "x", "weight": "y"}], "places": []}',
        ),
        ("place-not-object", '{"net": "m", "places": {"p": 1, "q": null, "r": []}}'),
        ("place-initial-float", '{"net": "m", "places": {"p": {"initial": 1.0}, "q": {"initial": 1.5}}}'),
        ("place-initial-string", '{"net": "m", "places": {"p": {"initial": "7"}, "q": {"initial": "seven"}}}'),
        ("place-initial-negative", '{"net": "m", "places": {"p": {"initial": -2}}}'),
        ("place-initial-big", '{"net": "m", "places": {"p": {"initial": 99999999999999999999}}}'),
        ("place-initial-bool", '{"net": "m", "places": {"p": {"initial": false}}}'),
        ("place-initial-null", '{"net": "m", "places": {"p": {"initial": null}}}'),
        ("place-interface-bad", '{"net": "m", "places": {"p": {"interface": "inout"}}}'),
        ("place-interface-int", '{"net": "m", "places": {"p": {"interface": 0}}}'),
        ("place-label-int", '{"net": "m", "places": {"p": {"label": 5}}}'),
        ("place-metadata-string", '{"net": "m", "places": {"p": {"metadata": "x"}}}'),
        ("place-empty-key", '{"net": "m", "places": {"": {"initial": 1}}}'),
        ("place-dotted-keys", '{"net": "m", "places": {"a.b": {}, "a": {}, "a..b": {}, ".": {}}}'),
        ("places-list", '{"net": "m", "places": [{"p": {}}]}'),
        ("transition-not-object", '{"net": "m", "transitions": {"t": "x"}}'),
        ("transition-handler-int", '{"net": "m", "transitions": {"t": {"handler": 1, "guard": [], "label": {}}}}'),
        ("delay-int", '{"net": "m", "transitions": {"t": {"delay": 90}}}'),
        ("delay-negative", '{"net": "m", "transitions": {"t": {"delay": -1}}}'),
        ("delay-negative-frac", '{"net": "m", "transitions": {"t": {"delay": -0.0000005}}}'),
        ("delay-float", '{"net": "m", "transitions": {"t": {"delay": 0.1234567}}}'),
        ("delay-tiny", '{"net": "m", "transitions": {"t": {"delay": 1e-7}}}'),
        ("delay-huge", '{"net": "m", "transitions": {"t": {"delay": 1e18}}}'),
        ("delay-max-days", '{"net": "m", "transitions": {"t": {"delay": 86399999999999}}}'),
        ("delay-over-max-days", '{"net": "m", "transitions": {"t": {"delay": 86400000000000}}}'),
        ("delay-min", '{"net": "m", "transitions": {"t": {"delay": -86399999999999}}}'),
        ("delay-under-min", '{"net": "m", "transitions": {"t": {"delay": -86400000000000}}}'),
        ("delay-big-int", '{"net": "m", "transitions": {"t": {"delay": 123456789012345678901234567890}}}'),
        ("delay-nan", '{"net": "m", "transitions": {"t": {"delay": NaN}}}'),
        ("delay-inf", '{"net": "m", "transitions": {"t": {"delay": Infinity}}}'),
        ("delay-bool", '{"net": "m", "transitions": {"t": {"delay": true}}}'),
        ("delay-list", '{"net": "m", "transitions": {"t": {"delay": [1]}}}'),
        ("delay-object", '{"net": "m", "transitions": {"t": {"delay": {"seconds": 1}}}}'),
        ("delay-iso", '{"net": "m", "transitions": {"t": {"delay": "P1DT2H3M4.5S"}}}'),
        ("delay-iso-weeks", '{"net": "m", "transitions": {"t": {"delay": "P2W"}}}'),
        ("delay-iso-years", '{"net": "m", "transitions": {"t": {"delay": "P1Y2M"}}}'),
        ("delay-iso-negative", '{"net": "m", "transitions": {"t": {"delay": "-P1D"}}}'),
        ("delay-iso-plus", '{"net": "m", "transitions": {"t": {"delay": "+PT5S"}}}'),
        ("delay-iso-fraction", '{"net": "m", "transitions": {"t": {"delay": "P1.5DT2.5H"}}}'),
        ("delay-iso-lower", '{"net": "m", "transitions": {"t": {"delay": "pt5s"}}}'),
        ("delay-iso-empty", '{"net": "m", "transitions": {"t": {"delay": "P"}}}'),
        ("delay-iso-t-only", '{"net": "m", "transitions": {"t": {"delay": "PT"}}}'),
        ("delay-hms", '{"net": "m", "transitions": {"t": {"delay": "1:00:00.123456789xyz"}}}'),
        ("delay-hms-7", '{"net": "m", "transitions": {"t": {"delay": "00:00:00.1234567"}}}'),
        ("delay-hms-days", '{"net": "m", "transitions": {"t": {"delay": "2 days, 01:02:03"}}}'),
        ("delay-hms-day", '{"net": "m", "transitions": {"t": {"delay": "1 day 00:00:01"}}}'),
        ("delay-hms-short", '{"net": "m", "transitions": {"t": {"delay": "12:30"}}}'),
        ("delay-hms-bad-minute", '{"net": "m", "transitions": {"t": {"delay": "00:61:00"}}}'),
        ("delay-hms-bad-second", '{"net": "m", "transitions": {"t": {"delay": "00:00:61"}}}'),
        ("delay-hms-hours-big", '{"net": "m", "transitions": {"t": {"delay": "99:00:00"}}}'),
        ("delay-string-number", '{"net": "m", "transitions": {"t": {"delay": "30"}}}'),
        ("delay-string-empty", '{"net": "m", "transitions": {"t": {"delay": ""}}}'),
        ("delay-string-garbage", '{"net": "m", "transitions": {"t": {"delay": "soon"}}}'),
        ("delay-string-unicode", '{"net": "m", "transitions": {"t": {"delay": "PT1\\u00e9S"}}}'),
        ("refs-entry-missing-ref", '{"net": "m", "refs": {"a": {}}}'),
        ("refs-entry-ref-int", '{"net": "m", "refs": {"a": {"ref": 1}}}'),
        ("refs-entry-string", '{"net": "m", "refs": {"a": "x.json"}}'),
        ("refs-empty-key-and-errors", '{"net": "m", "refs": {"": {"ref": "x.json"}, "b": {}}}'),
        ("refs-empty-key-only-after", '{"net": "m", "refs": {"": {"ref": "x.json"}}, "places": {"p": 1}}'),
        ("viewstate-list", '{"net": "m", "viewState": []}'),
        ("viewstate-zoom-string", '{"net": "m", "viewState": {"zoom": "2.5"}}'),
        ("viewstate-zoom-string-bad", '{"net": "m", "viewState": {"zoom": "big"}}'),
        ("viewstate-zoom-string-inf", '{"net": "m", "viewState": {"zoom": "-inf"}}'),
        ("viewstate-zoom-string-nan", '{"net": "m", "viewState": {"zoom": "NaN"}}'),
        ("viewstate-zoom-string-underscore", '{"net": "m", "viewState": {"zoom": "1_000.5"}}'),
        ("viewstate-zoom-bool", '{"net": "m", "viewState": {"zoom": true}}'),
        ("viewstate-zoom-nan", '{"net": "m", "viewState": {"zoom": NaN}}'),
        ("viewstate-zoom-inf", '{"net": "m", "viewState": {"zoom": Infinity}}'),
        ("viewstate-zoom-big-int", '{"net": "m", "viewState": {"zoom": 123456789012345678901234567890}}'),
        ("viewstate-zoom-huge-int", '{"net": "m", "viewState": {"zoom": 1' + "0" * 400 + "}}"),
        ("viewstate-zoom-neg-zero", '{"net": "m", "viewState": {"zoom": -0.0}}'),
        ("viewstate-zoom-1e16", '{"net": "m", "viewState": {"zoom": 1e16, "pan": [1e17, 123456789.0]}}'),
        ("viewstate-zoom-tiny", '{"net": "m", "viewState": {"zoom": 5e-324, "pan": [1e-7, 0.1]}}'),
        ("viewstate-pan-short", '{"net": "m", "viewState": {"pan": [1]}}'),
        ("viewstate-pan-empty", '{"net": "m", "viewState": {"pan": []}}'),
        ("viewstate-pan-long", '{"net": "m", "viewState": {"pan": [1, 2, 3]}}'),
        ("viewstate-pan-long-bad", '{"net": "m", "viewState": {"pan": ["a", 2, "c"]}}'),
        ("viewstate-pan-strings", '{"net": "m", "viewState": {"pan": ["1", "x"]}}'),
        ("viewstate-pan-object", '{"net": "m", "viewState": {"pan": {"x": 1}}}'),
        ("viewstate-pan-string", '{"net": "m", "viewState": {"pan": "12"}}'),
        ("viewstate-layout-list", '{"net": "m", "viewState": {"layout": [[0, 0]]}}'),
        ("viewstate-layout-bad-point", '{"net": "m", "viewState": {"layout": {"a": [0], "b": "x", "c": [1, 2, 3]}}}'),
        ("viewstate-layout-dotted", '{"net": "m", "viewState": {"layout": {"a.b": [0, 1], "": [2, 3]}}}'),
        ("viewstate-selected-string", '{"net": "m", "viewState": {"selected": "a"}}'),
        ("viewstate-selected-ints", '{"net": "m", "viewState": {"selected": [1, "b", null]}}'),
        ("viewstate-selected-lists", '{"net": "m", "viewState": {"selected": [["a", "b"], ["c"], {"d": 1}]}}'),
        ("viewstate-selected-list-dotted", '{"net": "m", "viewState": {"selected": [["a.b"]]}}'),
        ("viewstate-selected-nested", '{"net": "m", "viewState": {"selected": [[["a"]]]}}'),
        ("viewstate-waypoints-bad", '{"net": "m", "viewState": {"arcWaypoints": {"a": [[1]], "b": "x", "c": [[1, "y"]]}}}'),
        ("viewstate-waypoints-list", '{"net": "m", "viewState": {"arcWaypoints": []}}'),
        ("viewstate-annotations", '{"net": "m", "viewState": {"annotations": {"n": {"text": "hi"}}}}'),
        ("many-errors", '{"arcs": [1, 2, 3], "places": {"a": 1, "b": 2}, "transitions": {"t": 3}, "viewState": 4}'),
        (
            "long-input-repr",
            '{"net": "m", "places": {"p": {"label": ["' + "x" * 80 + '"]}}}',
        ),
        (
            "long-unicode-repr",
            '{"net": "m", "places": {"p": {"label": ["' + "é日😀" * 20 + '"]}}}',
        ),
        ("long-key-repr", '{"net": "m", "places": {"' + "k" * 70 + '": 5}}'),
        ("dotted-key-loc", '{"net": "m", "places": {"a.b": 5, "c": {"initial": "z"}}}'),
        ("key-with-quote-loc", '{"net": "m", "places": {"a\'b": 5, "c\\"d": 6}}'),
        ("repr-quotes", '{"net": "m", "places": {"p": {"label": ["it\'s", "say \\"hi\\"", "both \' \\""]}}}'),
        ("repr-control", '{"net": "m", "places": {"p": {"label": ["\\u0000\\t\\n\\u007f\\u0080\\u00a0\\u2028"]}}}'),
        ("repr-nonprintable", '{"net": "m", "places": {"p": {"label": ["\\u200b\\ufeff\\ue000\\udbff\\udfff"]}}}'),
        ("repr-floats", '{"net": "m", "places": {"p": {"label": [1e16, 1.5e-7, 0.1, -0.0, 1e22, 12345678901234567]}}}'),
    ]:
        single(f"edge/{name}", text)

    # Duplicate keys: model fields take the last; dicts keep the first
    # position and the last value.
    single("edge/duplicate-net", '{"net": "a", "net": "b"}')
    single("edge/duplicate-net-invalid-first", '{"net": 1, "net": "b"}')
    single("edge/duplicate-net-invalid-last", '{"net": "a", "net": 2}')
    single("edge/duplicate-places", '{"net": "m", "places": {"a": {}, "b": {"initial": 1}, "a": {"initial": 2}}}')
    single("edge/duplicate-places-errors", '{"net": "m", "places": {"a": 1, "b": {}, "a": 2}}')
    single("edge/duplicate-arc-fields", '{"net": "m", "arcs": [{"source": "a", "target": "b", "source": "c"}]}')
    single("edge/duplicate-only", '{"a": 1, "a": 2}')
    single("edge/duplicate-metadata", '{"net": "m", "places": {"p": {"metadata": {"x": 1, "y": 2, "x": 3}}}}')

    # JSON syntax: jiter for files, json.loads for format and dicts.
    for name, text in [
        ("empty", ""),
        ("spaces", "   "),
        ("newlines", "\n\n"),
        ("truncated-object", '{"net": "m"'),
        ("truncated-string", '{"net": "m'),
        ("truncated-key", '{"ne'),
        ("trailing-comma-object", '{"net": "m",}'),
        ("trailing-comma-array", '{"net": "m", "arcs": [],}'),
        ("trailing-comma-in-array", '{"net": "m", "arcs": [1,]}'),
        ("missing-colon", '{"net" "m"}'),
        ("missing-comma", '{"net": "m" "arcs": []}'),
        ("single-quotes", "{'net': 'm'}"),
        ("unquoted-key", "{net: 1}"),
        ("extra-data", '{"net": "m"} x'),
        ("extra-object", '{"net": "m"}{}'),
        ("extra-whitespace-after", '{"net": "m"}  \n\t '),
        ("bad-literal", '{"net": tru}'),
        ("bad-literal-null", '{"net": nul}'),
        ("bad-literal-nan", '{"net": NaX}'),
        ("bad-literal-inf", '{"net": Infinit}'),
        ("number-leading-zero", '{"net": 01}'),
        ("number-dot-exp", '{"net": 1.e5}'),
        ("number-minus", '{"net": -a}'),
        ("number-minus-brace", '{"net": -}'),
        ("number-minus-inf", '{"net": "m", "viewState": {"zoom": -Infinity}}'),
        ("number-plus", '{"net": +1}'),
        ("number-dot", '{"net": .5}'),
        ("number-trailing-dot", '{"net": 1.}'),
        ("number-exp-sign", '{"net": 1e+}'),
        ("number-hex", '{"net": 0x10}'),
        ("number-long-int", '{"net": "m", "viewState": {"zoom": ' + "9" * 4300 + "}}"),
        ("number-too-long-int", '{"net": "m", "viewState": {"zoom": ' + "9" * 4301 + "}}"),
        ("number-too-long-neg", '{"net": "m", "viewState": {"zoom": -' + "9" * 4300 + "}}"),
        ("number-long-float", '{"net": "m", "viewState": {"zoom": 0.' + "1" * 5000 + "}}"),
        ("number-long-exp", '{"net": "m", "viewState": {"zoom": 1e' + "1" * 30 + "}}"),
        ("number-neg-exp", '{"net": "m", "viewState": {"zoom": 1e-400}}'),
        ("control-char-in-string", '{"net": "a\tb"}'),
        ("newline-in-string", '{"net": "a\nb"}'),
        ("bad-escape", '{"net": "a\\qb"}'),
        ("bad-unicode-escape", '{"net": "a\\u12G4"}'),
        ("short-unicode-escape", '{"net": "a\\u12"}'),
        ("escapes", '{"net": "\\"\\\\\\/\\b\\f\\n\\r\\t\\u0041\\u00e9\\ud83d\\ude00"}'),
        ("lone-high-surrogate-file", '{"fileVersion": "2", "net": "a\\ud800"}'),
        ("lone-low-surrogate-file", '{"fileVersion": "2", "net": "a\\udc00b"}'),
        ("surrogate-then-bad", '{"net": "a\\ud800\\u0041"}'),
        # Lone surrogates json.loads keeps: plain strings carry them, and a
        # string pydantic must parse (int, float, enum, literal, timedelta)
        # is a string_unicode error; a dict key in a loc is spelled lossily.
        ("surrogate-names", '{"net": "m\\udc00", "places": {"p\\udc00": {"initial": 1, "label": "\\ud800",'
         ' "metadata": {"k\\ud83d": "\\udfff x", "\\ud800": ["\\udbff"]}}}, "transitions": {"t\\ud800":'
         ' {"handler": "\\ud800", "guard": "\\udc00", "metadata": {"\\ud801": null}}}, "arcs":'
         ' [{"source": "p\\udc00", "target": "t\\ud800"}], "refs": {"r\\ud800": {"ref": "x\\udc00.json"}},'
         ' "viewState": {"layout": {"p\\udc00": [1, 2]}, "selected": ["t\\ud800"]}}'),
        ("surrogate-int", '{"net": "m", "places": {"p": {"initial": "1\\ud800"}}}'),
        ("surrogate-weight", '{"net": "m", "arcs": [{"source": "a", "target": "b", "weight": "\\ud800"}]}'),
        ("surrogate-kind", '{"net": "m", "arcs": [{"source": "a", "target": "b", "kind": "read\\udc00"}]}'),
        ("surrogate-interface", '{"net": "m", "places": {"p": {"interface": "\\ud800"}}}'),
        ("surrogate-delay", '{"net": "m", "transitions": {"t": {"delay": "1s\\ud800"}}}'),
        ("surrogate-zoom", '{"net": "m", "viewState": {"zoom": "\\ud800"}}'),
        ("surrogate-pan", '{"net": "m", "viewState": {"pan": ["\\ud800", 1]}}'),
        ("surrogate-loc-key", '{"net": "m", "places": {"p\\ud800q": {"initial": "x"}},'
         ' "viewState": {"arcWaypoints": {"a\\udfff": [["\\ud800", 1]]}}}'),
        ("surrogate-extra-keys", '{"net": "m", "\\ud800": 1, "places": {"p": {"\\udc00": 2}},'
         ' "arcs": [{"source": "a", "target": "b", "\\ud800": 3}], "viewState": {"\\ud800": 4}}'),
        ("surrogate-file-version", '{"fileVersion": "\\ud800", "net": "m"}'),
        ("surrogate-dotted-segment", '{"net": "m", "arcs": [{"source": ["a", "\\ud800.b"], "target": "b"}]}'),
        ("deep-199", '{"net": "m", "places": {"p": {"metadata": {"x": ' + "[" * 196 + "]" * 196 + "}}}}"),
        ("deep-200", '{"net": "m", "places": {"p": {"metadata": {"x": ' + "[" * 197 + "]" * 197 + "}}}}"),
        ("deep-201", '{"net": "m", "places": {"p": {"metadata": {"x": ' + "[" * 198 + "]" * 198 + "}}}}"),
        ("deep-empty", '{"net": "m", "places": {"p": {"metadata": {"x": ' + "[" * 199 + "]" * 199 + "}}}}"),
        ("deep-objects", '{"net": "m", "places": {"p": {"metadata": ' + '{"a":' * 197 + "1" + "}" * 197 + "}}}"),
        ("deep-unclosed", "[" * 250),
        ("bom", '﻿{"net": "m"}'),
        ("bom-only", "﻿"),
        ("nul-byte", '{"net": "m"}\x00'),
        ("crlf", '{\r\n  "net": "m",\r\n  "places": {"p": {}}\r\n}\r\n'),
        ("cr-only", '{\r  "net": "m"\r}\r'),
        ("crlf-in-error", '{\r\n  "net": "m",\r\n  "places": {"p": 1},\r\n}'),
        ("cr-in-string-escape", '{"net": "m\\r\\n"}'),
        ("multiline-error-position", '{\n  "net": "m",\n  "arcs": [\n    {"source": "a", "target": }\n  ]\n}'),
        ("error-at-newline", '{"net": "m",\n'),
        ("unicode-before-error", '{"net": "日本語😀", "places": ]'),
    ]:
        single(f"edge/json/{name}", text)

    # Bytes that are not UTF-8.
    for name, data in [
        ("invalid-start", b'{"net": "\x80"}'),
        ("invalid-start-c1", b'{"net": "\xc1\xbf"}'),
        ("invalid-continuation", b'{"net": "\xc3\x28"}'),
        ("invalid-continuation-3", b'{"net": "\xe2\x28\xa1"}'),
        ("invalid-continuation-3b", b'{"net": "\xe2\x82\x28"}'),
        ("overlong-e0", b'{"net": "\xe0\x80\x80"}'),
        ("surrogate-ed", b'{"net": "\xed\xa0\x80"}'),
        ("invalid-continuation-4", b'{"net": "\xf0\x28\x8c\xbc"}'),
        ("invalid-continuation-4c", b'{"net": "\xf0\x90\x8c\x28"}'),
        ("invalid-continuation-4b", b'{"net": "\xf0\x90\x28\xbc"}'),
        ("f4-too-big", b'{"net": "\xf4\x90\x80\x80"}'),
        ("f5", b'{"net": "\xf5\x80\x80\x80"}'),
        ("truncated-2", b'{"net": "m"}\xc3'),
        ("truncated-3", b'{"net": "m"}\xe2\x82'),
        ("truncated-3-bad", b'{"net": "m"}\xe2\x28'),
        ("truncated-4", b'{"net": "m"}\xf0\x90\x8c'),
        ("truncated-4-bad", b'{"net": "m"}\xf0\x90\x28'),
        ("latin1", '{"net": "caf\xe9"}'.encode("latin-1")),
        ("utf16", '{"net": "m"}'.encode("utf-16")),
    ]:
        single(f"edge/bytes/{name}", data)

    # Layout thresholds of compact_json.
    long_label = "L" * 60
    layout = {
        "net": "lay",
        "arcs": [{"source": "a" * 40, "target": "b" * 40, "metadata": {"m": "x" * 30}}],
        "places": {"p": {"label": long_label, "metadata": {"k": 1}}, "q": {}},
        "transitions": {"t": {"label": "y" * 95}},
        "viewState": {"layout": {f"n{i}": [i, i * 1.5] for i in range(12)}, "selected": [f"n{i}" for i in range(30)]},
    }
    text = dumps(layout)
    ops = []
    for indent in (0, 1, 2, 3, 4, 8):
        for max_inline in (0, 1, 10, 17, 40, 60, 99, 100, 101, 120, 200, 10000):
            ops.append(file_op(indent=indent, max_inline=max_inline))
    ops.append(format_op(indent=4, max_inline=40))
    ops.append(format_op(indent=0, max_inline=0))
    case("edge/layout-thresholds", {"net.json": text}, ops)
    # Exactly at max_inline.
    for width in range(95, 106):
        label = "z" * (width - len('{"label": ""}'))
        single(f"edge/inline-width-{width}", dumps({"net": "w", "places": {"p": {"label": label}}}))

    # A file already in format-CLI spelling (format reports no change).
    canonical = FlatNetFile.model_validate(full).to_json(max_inline=120)
    single("edge/already-formatted", canonical)
    single("edge/already-formatted-crlf", canonical.replace("\n", "\r\n"))
    single("edge/already-formatted-no-newline", canonical.rstrip("\n"))

    # Arc order: sorted by (source, target) after prefixing.
    single(
        "edge/arc-order",
        dumps(
            {
                "net": "o",
                "arcs": [
                    {"source": "b", "target": "a"},
                    {"source": "a.b", "target": "c"},
                    {"source": "a", "target": "z"},
                    {"source": "a", "target": "b", "weight": 2},
                    {"source": "a", "target": "b", "weight": 3},
                    {"source": "A", "target": "b"},
                    {"source": "é", "target": "b"},
                    {"source": "😀", "target": "b"},
                    {"source": "￿", "target": "b"},
                    {"source": "", "target": "b"},
                    {"source": "a", "target": ""},
                ],
            }
        ),
    )
    # Non-string segments through the sort and the schema.
    for name, arcs in [
        ("list-vs-str", [{"source": "b", "target": "x"}, {"source": [["a"]], "target": "x"}]),
        ("list-vs-list", [{"source": ["a", ["b"]], "target": "x"}, {"source": ["a", ["a"]], "target": "x"}]),
        ("list-equal-prefix", [{"source": ["a", ["b", "c"]], "target": "x"}, {"source": ["a", ["b"]], "target": "x"}]),
        ("list-numbers", [{"source": ["a", [2]], "target": "x"}, {"source": ["a", [1.5]], "target": "x"}]),
        ("list-nan", [{"source": ["a", [NAN]], "target": "x"}, {"source": ["a", [NAN]], "target": "y"}]),
        ("list-mixed", [{"source": ["a", [1]], "target": "x"}, {"source": ["a", ["s"]], "target": "x"}]),
        ("dict-vs-dict", [{"source": ["a", {"k": 1}], "target": "x"}, {"source": ["a", {"k": 2}], "target": "x"}]),
        ("dict-equal", [{"source": ["a", {"k": 1}], "target": "x"}, {"source": ["a", {"k": 1}], "target": "y"}]),
        ("null-in-list", [{"source": ["a", [None]], "target": "x"}, {"source": ["a", [None]], "target": "y"}]),
        ("bool-int", [{"source": ["a", [True]], "target": "x"}, {"source": ["a", [1]], "target": "y"}]),
        ("target-list", [{"source": "a", "target": ["t", ["u"]]}, {"source": "a", "target": "t"}]),
        ("single-list-root", [{"source": [["p", "q"]], "target": "x"}, {"source": "p.q", "target": "w"}]),
        (
            "many-mixed",
            [{"source": ["s", [i % 3]], "target": "x"} for i in range(9)]
            + [{"source": ["s", "z"], "target": "x"}, {"source": "s", "target": "x"}],
        ),
        (
            "descending",
            [{"source": ["s", [9 - i]], "target": "x"} for i in range(10)],
        ),
        (
            "equal-runs",
            [{"source": ["s", [1]], "target": "x"}] * 3
            + [{"source": ["s", [0]], "target": "x"}] * 2
            + [{"source": ["s", [2]], "target": "x"}, {"source": ["s", "t"], "target": "x"}],
        ),
    ]:
        single(
            f"edge/segments/{name}",
            json.dumps({"net": "s", "arcs": arcs}).replace('"__NAN__"', "NaN"),
        )

    # The format CLI spelling of lone surrogates and NaN identity (Python
    # mode), and NaN in duplicate-name comparisons.
    nan_dup = '{"fileVersion": "2", "net": "dup", "viewState": {"zoom": NaN}}'
    multi(
        "edge/refs/nan-duplicate-names",
        {
            "main.json": dumps(
                {"net": "main", "refs": {"a": {"ref": "a.json"}, "b": {"ref": "b.json"}}}
            ),
            "a.json": nan_dup,
            "b.json": nan_dup,
        },
        root="main.json",
        deps={"a.json": "a.json", "b.json": "b.json"},
    )
    multi(
        "edge/refs/nan-same-file-twice",
        {
            "main.json": dumps({"net": "main", "refs": {"a": {"ref": "a.json"}, "b": {"ref": "a.json"}}}),
            "a.json": '{"net": "dup", "places": {"p": {"metadata": {"x": NaN}}}}',
        },
        root="main.json",
        deps={"a.json": "a.json"},
    )
    multi(
        "edge/refs/same-file-twice-different-ref-spelling",
        {
            "main.json": dumps({"net": "main", "refs": {"a": {"ref": "a.json"}, "b": {"ref": "./a.json"}}}),
            "a.json": '{"net": "dup", "places": {"p": {"initial": 2}}, "transitions": {"t": {"delay": 5}}}',
        },
        root="main.json",
        deps={"a.json": "a.json", "./a.json": "a.json"},
    )
    multi(
        "edge/refs/equal-but-differently-spelled",
        {
            "main.json": dumps({"net": "main", "refs": {"a": {"ref": "a.json"}, "b": {"ref": "b.json"}}}),
            "a.json": '{"net": "dup", "places": {"p": {"initial": 2, "metadata": {"x": 1, "y": 2}}}, "viewState": {"zoom": 2}}',
            "b.json": '{"places": {"p": {"metadata": {"y": 2, "x": 1.0}, "initial": "2"}}, "net": "dup", "viewState": {"zoom": 2.0, "pan": [0, 0]}}',
        },
        root="main.json",
        deps={"a.json": "a.json", "b.json": "b.json"},
    )
    multi(
        "edge/refs/differ-in-delay",
        {
            "main.json": dumps({"net": "main", "refs": {"a": {"ref": "a.json"}, "b": {"ref": "b.json"}}}),
            "a.json": '{"net": "dup", "transitions": {"t": {"delay": 1}}}',
            "b.json": '{"net": "dup", "transitions": {"t": {"delay": "PT1.000001S"}}}',
        },
        root="main.json",
        deps={"a.json": "a.json", "b.json": "b.json"},
    )
    multi(
        "edge/refs/root-name-reused-below",
        {
            "main.json": dumps({"net": "main", "refs": {"a": {"ref": "a.json"}}}),
            "a.json": dumps({"net": "main"}),
        },
        root="main.json",
        deps={"a.json": "a.json"},
    )
    multi(
        "edge/refs/self-reference",
        {"main.json": dumps({"net": "main", "refs": {"me": {"ref": "main.json"}}})},
        root="main.json",
        deps={"main.json": "main.json"},
    )
    multi(
        "edge/refs/deep-chain",
        {
            **{
                f"n{i}.json": dumps({"net": f"n{i}", "places": {"p": {}}, "refs": {"c": {"ref": f"n{i + 1}.json"}}})
                for i in range(6)
            },
            "n6.json": dumps({"net": "n6", "places": {"leaf": {"initial": 1}}, "arcs": [{"source": "leaf", "target": "leaf"}]}),
        },
        root="n0.json",
        deps={f"n{i}.json": f"n{i}.json" for i in range(1, 7)},
    )
    multi(
        "edge/refs/dotted-mounts",
        {
            "main.json": dumps(
                {
                    "net": "main",
                    "places": {"x.p": {"initial": 1}},
                    "refs": {"x": {"ref": "lib.json"}, "y.z": {"ref": "lib.json"}},
                    "viewState": {"layout": {"x": [1, 2]}},
                }
            ),
            "lib.json": dumps(
                {
                    "net": "lib",
                    "places": {"p": {}, "q": {"label": "Q"}},
                    "arcs": [{"source": "p", "target": "q"}],
                    "viewState": {"zoom": 2},
                }
            ),
        },
        root="main.json",
        deps={"lib.json": "lib.json"},
    )
    multi(
        "edge/refs/mount-collides-with-node",
        {
            "main.json": dumps({"net": "main", "places": {"a.b": {"initial": 7}}, "refs": {"a": {"ref": "lib.json"}}}),
            "lib.json": dumps({"net": "lib", "places": {"b": {"label": "from lib"}}, "transitions": {"b": {}}}),
        },
        root="main.json",
        deps={"lib.json": "lib.json"},
    )
    multi(
        "edge/refs/subdirectories",
        {
            "main.json": dumps({"net": "main", "refs": {"a": {"ref": "sub/a.json"}}}),
            "sub/a.json": dumps({"net": "a", "refs": {"b": {"ref": "b.json"}}}),
            "b.json": dumps({"net": "b", "places": {"root_relative": {}}}),
            "sub/b.json": dumps({"net": "b2"}),
        },
        root="main.json",
        deps={"sub/a.json": "sub/a.json", "b.json": "b.json"},
    )
    multi(
        "edge/refs/root-in-subdirectory",
        {
            "nets/main.json": dumps({"net": "main", "refs": {"a": {"ref": "../lib/a.json"}, "b": {"ref": "b.json"}}}),
            "lib/a.json": dumps({"net": "a"}),
            "nets/b.json": dumps({"net": "b"}),
        },
        root="nets/main.json",
        deps={"../lib/a.json": "lib/a.json", "b.json": "nets/b.json"},
    )
    for ref, extra_files, dirs in [
        ("", {}, []),
        (".", {}, []),
        ("d", {}, ["d"]),
        ("d/", {}, ["d"]),
        ("main.json/x", {}, []),
        ("missing/x.json", {}, []),
        ("x\u0000y", {}, []),
        ("é.json", {"é.json": dumps({"net": "accent"})}, []),
        ("it's \"q\".json", {}, []),
        ("/nonexistent-petrus-path/x.json", {}, []),
        ("bad.json", {"bad.json": "{"}, []),
        ("invalid.json", {"invalid.json": '{"net": 5}'}, []),
        ("bytes.json", {"bytes.json": b'{"net": "\xff"}'}, []),
    ]:
        files = {"main.json": dumps({"net": "main", "refs": {"r": {"ref": ref}}}), **extra_files}
        ops = [load_op("main.json"), dict_op("main.json", {ref: None} if ref == "." else {})]
        if extra_files:
            ops.append(dict_op("main.json", {ref: list(extra_files)[0]}))
        case(f"edge/refs/ref-{json.dumps(ref)}", files, ops, dirs=dirs)
    case(
        "edge/root-paths",
        {"main.json": dumps({"net": "main"}), "sub/n.json": dumps({"net": "n"})},
        [
            load_op("missing.json"),
            load_op("sub"),
            load_op("sub/"),
            load_op("main.json/"),
            load_op(".//sub/./n.json"),
            load_op("sub/../main.json"),
            file_op("missing.json"),
            file_op("sub"),
            format_op("missing.json"),
            format_op("sub"),
        ],
    )
    case(
        "edge/deps-null",
        {"main.json": dumps({"net": "main", "refs": {"r": {"ref": "x.json"}}})},
        [dict_op("main.json", {"x.json": None})],
    )
    case(
        "edge/deps-not-object",
        {"main.json": dumps({"net": "main", "refs": {"r": {"ref": "x.json"}}}), "x.json": "[1, 2]"},
        [dict_op("main.json", {"x.json": "x.json"})],
    )


NAN = "__NAN__"


# ── fuzz ──────────────────────────────────────────────────────────────────


ALPHABET = "abcxyz_019AZ.-é日😀 '\"\\\t"


FUZZ_SEED = 20261010
FUZZ_COUNT = 400


def fuzz_cases(seed, count):
    rng = random.Random(seed)

    def name(allow_dot=True):
        n = rng.choice([1, 1, 2, 3, 6])
        chars = ALPHABET if allow_dot else ALPHABET.replace(".", "")
        word = "".join(rng.choice(chars[:12] if rng.random() < 0.8 else chars) for _ in range(n))
        if allow_dot and rng.random() < 0.2:
            word += "." + "".join(rng.choice("pqr") for _ in range(2))
        return word

    def number():
        return rng.choice(
            [
                0,
                1,
                -1,
                rng.randint(-1000, 1000),
                rng.uniform(-1e3, 1e3),
                rng.choice([0.5, 1.0, 2.0, 1e16, 1e-7, 123456789.125, 1e300]),
                rng.randint(-(10**30), 10**30),
            ]
        )

    def any_value(depth=0):
        r = rng.random()
        if depth > 2 or r < 0.5:
            return rng.choice([None, True, False, number(), name(), ""])
        if r < 0.75:
            return [any_value(depth + 1) for _ in range(rng.randint(0, 3))]
        return {name(): any_value(depth + 1) for _ in range(rng.randint(0, 3))}

    def delay():
        return rng.choice(
            [
                rng.randint(0, 100000),
                round(rng.uniform(0, 1000), rng.randint(0, 7)),
                f"PT{rng.randint(0, 99)}M{rng.randint(0, 59)}S",
                f"P{rng.randint(0, 9)}DT{rng.randint(0, 23)}H",
                f"{rng.randint(0, 23):02d}:{rng.randint(0, 59):02d}:{rng.randint(0, 59):02d}",
                f"{rng.randint(0, 3)} days, {rng.randint(0, 23)}:{rng.randint(0, 59):02d}:00.{rng.randint(0, 999999)}",
                -rng.randint(1, 10**6),
            ]
        )

    def net(refs=None):
        nodes = [name() for _ in range(rng.randint(0, 8))]
        places = {}
        transitions = {}
        for node in nodes:
            if rng.random() < 0.5:
                p = {}
                if rng.random() < 0.5:
                    p["initial"] = rng.choice([0, 1, 2, rng.randint(0, 10**6), 3.0])
                if rng.random() < 0.3:
                    p["label"] = name()
                if rng.random() < 0.3:
                    p["interface"] = rng.choice(["input", "output", "awaiting", "control"])
                if rng.random() < 0.2:
                    p["metadata"] = {name(): any_value() for _ in range(rng.randint(0, 3))}
                places[node] = p
            else:
                t = {}
                for field in ("handler", "guard", "label"):
                    if rng.random() < 0.3:
                        t[field] = name()
                if rng.random() < 0.2:
                    t["metadata"] = {name(): any_value() for _ in range(rng.randint(0, 3))}
                if rng.random() < 0.4:
                    t["delay"] = delay()
                transitions[node] = t
        arcs = []
        for _ in range(rng.randint(0, 10)):
            if not nodes:
                break
            a = {"source": rng.choice(nodes), "target": rng.choice(nodes)}
            if rng.random() < 0.3:
                a["kind"] = rng.choice(["normal", "inhibitor", "read"])
            if rng.random() < 0.3:
                a["weight"] = rng.choice([1, 2, 5, 1.0, rng.randint(0, 100)])
            if rng.random() < 0.15:
                a["metadata"] = {name(): any_value() for _ in range(rng.randint(0, 2))}
            arcs.append(a)
        doc = {"net": name(allow_dot=rng.random() < 0.1)}
        if rng.random() < 0.7:
            doc["fileVersion"] = "2"
        if arcs or rng.random() < 0.2:
            doc["arcs"] = arcs
        if places or rng.random() < 0.2:
            doc["places"] = places
        if transitions or rng.random() < 0.2:
            doc["transitions"] = transitions
        if refs:
            doc["refs"] = refs
        if rng.random() < 0.5:
            vs = {}
            if rng.random() < 0.7:
                vs["layout"] = {n: [number(), number()] for n in nodes if rng.random() < 0.7}
            if rng.random() < 0.3:
                vs["zoom"] = rng.choice([1, 1.0, 0.75, 2, number()])
            if rng.random() < 0.3:
                vs["pan"] = [number(), number()]
            if rng.random() < 0.2:
                vs["selected"] = [rng.choice(nodes) for _ in range(rng.randint(0, 2))] if nodes else []
            if rng.random() < 0.2:
                vs["arcWaypoints"] = {
                    f"{a['source']}->{a['target']}": [[number(), number()]] for a in arcs[: rng.randint(0, 3)]
                }
            doc["viewState"] = vs
        if rng.random() < 0.3:
            keys = list(doc)
            rng.shuffle(keys)
            doc = {k: doc[k] for k in keys}
        return doc

    def mutate(doc):
        """Put a wrong value somewhere, or drop a field."""
        paths = []

        def walk(value, path):
            paths.append(path)
            if isinstance(value, dict):
                for k, v in value.items():
                    walk(v, (*path, k))
            elif isinstance(value, list):
                for i, v in enumerate(value):
                    walk(v, (*path, i))

        walk(doc, ())
        path = rng.choice(paths[1:]) if len(paths) > 1 else ()
        if not path:
            return any_value()
        parent = doc
        for key in path[:-1]:
            parent = parent[key]
        if isinstance(parent, dict) and rng.random() < 0.3:
            del parent[path[-1]]
        else:
            parent[path[-1]] = rng.choice([any_value(), None, "", [], {}, 1.5, -3, "x.y", [1, 2, 3], NAN])
        return doc

    def spell(doc):
        style = rng.random()
        if style < 0.3:
            try:
                return FlatNetFile.model_validate(doc).to_json(max_inline=rng.choice([60, 100, 120]))
            except Exception:  # noqa: BLE001
                pass
        if style < 0.6:
            text = json.dumps(doc, indent=rng.choice([None, 0, 1, 2, 4]), ensure_ascii=False)
        else:
            text = json.dumps(doc, separators=(",", ":"), ensure_ascii=rng.random() < 0.5)
        return text.replace('"__NAN__"', "NaN")

    def corrupt(text):
        data = bytearray(text.encode("utf-8"))
        if not data:
            return bytes(data)
        r = rng.random()
        i = rng.randrange(len(data))
        if r < 0.3:
            return bytes(data[:i])
        if r < 0.5:
            del data[i]
        elif r < 0.7:
            data.insert(i, rng.choice(b'{}[],:"\\ 0aeE-+.\x80\xff\n\r'))
        else:
            data[i] = rng.choice(b'{}[],:"\\ 0aeE-+.\x80\xff\n')
        return bytes(data)

    for index in range(count):
        kind = rng.random()
        if kind < 0.15:
            # A multi-file net.
            children = {}
            child_refs = {}
            for j in range(rng.randint(1, 3)):
                filename = rng.choice(["a.json", "b.json", "c.json", "sub/d.json"])
                child = net()
                if rng.random() < 0.3 and children:
                    child["net"] = json.loads(next(iter(children.values())))["net"]
                children[filename] = spell(child)
                child_refs[name(allow_dot=False) or "m"] = {"ref": filename}
            if rng.random() < 0.1:
                child_refs[name()] = {"ref": "missing.json"}
            root = net(refs=child_refs)
            files = {"net.json": spell(root), **children}
            deps = {f: f for f in children}
            multi(f"fuzz/{index:03d}-multi", files, root="net.json", deps=deps)
            continue
        doc = net()
        if kind < 0.55:
            text = spell(doc)
        elif kind < 0.85:
            text = spell(mutate(doc))
        else:
            text = corrupt(spell(doc))
        extra = ()
        if rng.random() < 0.3:
            extra = (file_op(indent=rng.randint(0, 5), max_inline=rng.randint(0, 150)),)
        single(f"fuzz/{index:03d}", text, extra=extra)


def record(cases, out):
    for c in cases:
        c["expect"] = expectation(c)
    names = [c["name"] for c in cases]
    assert len(names) == len(set(names)), "duplicate case names"
    out.write_text(json.dumps({"cases": cases}, indent=1, ensure_ascii=True) + "\n")
    print(f"{len(cases)} cases -> {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fuzz-only", action="store_true", help="only seeded random cases (no viewer, no node)")
    parser.add_argument("--seed", type=int, default=FUZZ_SEED, help="fuzz seed")
    parser.add_argument("--count", type=int, default=FUZZ_COUNT, help="number of fuzz cases")
    parser.add_argument("--out", type=Path, default=HERE / "corpus.json", help="output file")
    args = parser.parse_args()
    if args.fuzz_only:
        fuzz_cases(args.seed, args.count)
    else:
        upstream_cases()
        viewer_cases()
        edge_cases()
        fuzz_cases(args.seed, args.count)
        viewer_resaves()
    record(CASES, args.out)


if __name__ == "__main__":
    main()
