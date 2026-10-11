"""Generate the Catalog differential corpus from the reference implementation.

Run from the root of the pinned upstream Petrus checkout, with its virtual
environment, e.g. from the repository root:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/differential/catalog_corpus.py

The script writes ``catalog_corpus.json`` next to itself (or into the directory given as its first argument). It records:

- ``profiles``: every runtime x territory qualification cell, with the exact
  ``json.dumps`` bytes of its descriptor;
- ``descriptors``: descriptor ``from_data`` cases (generated, including
  Unicode names, unsorted offers and requirements) with either the
  ``json.dumps`` bytes of ``to_data()`` or the refusal (class and message);
- ``resolutions``: scripted Catalog sessions (register / enable / disable /
  resolve) with every step's outcome: the refusal, the revision, or the
  ``json.dumps`` bytes of the resolution results and snapshot.

``CatalogSpec`` replays every case with the Haskell Catalog and asserts the
same bytes and the same refusals.
"""

from __future__ import annotations

import json
import sys
import random
from pathlib import Path

from petrus.agenticus.catalog.descriptor import (
    CapabilityDescriptor,
    CompatibilityRequirement,
    DescriptorIdentity,
    DescriptorKind,
)
from petrus.agenticus.catalog.resolution import Catalog, ResolutionRequest, ResolutionSnapshot
from petrus.agenticus.runtime.profiles import RUNTIME_TERRITORY_PROFILES

HERE = Path(__file__).resolve().parent
KINDS = [kind.value for kind in DescriptorKind]


def error_data(error: BaseException) -> dict[str, str]:
    return {"class": type(error).__name__, "message": str(error)}


def profiles() -> list[dict[str, object]]:
    return [
        {
            "family": cell.family.value,
            "territory": cell.territory.value,
            "expectation": cell.expectation.value,
            "reason": cell.reason,
            "archetype": None if cell.archetype is None else cell.archetype.value,
            "descriptor": None if cell.descriptor is None else json.dumps(cell.descriptor.to_data()),
        }
        for cell in RUNTIME_TERRITORY_PROFILES
    ]


NAMES = ["runtime", "pi.application-owned", "é-name", "名前", "a b", "x" * 256, "z"]
CAPS = ["workspace.read", "workspace.write", "é.cap", "a", "B", "zz", "workspace.read "]


def random_descriptor_data(rng: random.Random) -> object:
    def requirement() -> dict[str, object]:
        return {
            "kind": rng.choice(KINDS),
            "name": rng.choice([None, None, *NAMES[:4]]),
            "contract_version": rng.choice([1, 1, 2, 3]),
            "capabilities": rng.sample(CAPS[:6], rng.randint(0, 3)),
        }

    data: dict[str, object] = {
        "schema_version": 1,
        "identity": {"kind": rng.choice(KINDS), "name": rng.choice(NAMES), "contract_version": rng.choice([1, 2, 7])},
        "offers": rng.sample(CAPS[:6], rng.randint(0, 4)),
        "requires": [requirement() for _ in range(rng.randint(0, 4))],
    }
    return data


MUTATIONS = [
    lambda d: d | {"unexpected": True},
    lambda d: d | {"schema_version": 2},
    lambda d: d | {"schema_version": True},
    lambda d: d | {"schema_version": 1.0},
    lambda d: d | {"identity": d["identity"] | {"contract_version": True}},
    lambda d: d | {"identity": d["identity"] | {"contract_version": 0}},
    lambda d: d | {"identity": d["identity"] | {"contract_version": 1.0}},
    lambda d: d | {"identity": d["identity"] | {"kind": "agent"}},
    lambda d: d | {"identity": d["identity"] | {"name": " padded"}},
    lambda d: d | {"identity": d["identity"] | {"name": "trail\u0085"}},
    lambda d: d | {"identity": d["identity"] | {"name": "nbsp "}},
    lambda d: d | {"identity": d["identity"] | {"name": "ctl\u0001x"}},
    lambda d: d | {"identity": d["identity"] | {"name": "del\u007fx"}},
    lambda d: d | {"identity": d["identity"] | {"name": "é" * 129}},
    lambda d: d | {"identity": d["identity"] | {"name": 3}},
    lambda d: d | {"offers": ["workspace.read", "workspace.read"]},
    lambda d: d | {"offers": "workspace.read"},
    lambda d: d | {"offers": [""]},
    lambda d: d | {"offers": [1]},
    lambda d: d | {"requires": {}},
    lambda d: d | {"requires": [{"kind": "hands", "name": None, "contract_version": 1, "capabilities": "x"}]},
    lambda d: d | {"requires": [{"kind": "hands", "name": None, "contract_version": 1}]},
    lambda d: d
    | {
        "requires": [
            {"kind": "hands", "name": None, "contract_version": 1, "capabilities": ["a"]},
            {"kind": "hands", "name": None, "contract_version": 1, "capabilities": ["a"]},
        ]
    },
    lambda d: d | {"requires": [{"kind": "nope", "name": None, "contract_version": 1, "capabilities": []}]},
    lambda d: d | {"requires": [{"kind": "hands", "name": "", "contract_version": 1, "capabilities": []}]},
    lambda d: d | {"requires": [{"kind": "hands", "name": None, "contract_version": -1, "capabilities": []}]},
    lambda d: {k: v for k, v in d.items() if k != "offers"},
    lambda d: [d],
]


def descriptors() -> list[dict[str, object]]:
    rng = random.Random(1729)
    cases: list[dict[str, object]] = []
    base = {
        "schema_version": 1,
        "identity": {"kind": "runtime", "name": "pi.application-owned", "contract_version": 1},
        "offers": ["program.harness-owned", "continuation.opaque"],
        "requires": [
            {"kind": "hands", "name": None, "contract_version": 1, "capabilities": ["workspace.write", "workspace.read"]},
            {"kind": "connection", "name": None, "contract_version": 1, "capabilities": ["authority.materialize"]},
        ],
    }
    inputs: list[object] = [base]
    inputs.extend(mutation(base) for mutation in MUTATIONS)
    inputs.extend(random_descriptor_data(rng) for _ in range(200))
    for data in inputs:
        try:
            descriptor = CapabilityDescriptor.from_data(data)
        except (TypeError, ValueError) as error:
            cases.append({"input": data, "error": error_data(error)})
        else:
            cases.append({"input": data, "output": json.dumps(descriptor.to_data())})
    return cases


def identity(kind: str, name: str, version: int = 1) -> DescriptorIdentity:
    return DescriptorIdentity(DescriptorKind(kind), name, version)


def resolution_data(resolution) -> dict[str, object]:
    return {
        "compatible": resolution.compatible,
        "results": json.dumps([result.to_data() for result in resolution.results]),
        "snapshot": None if resolution.snapshot is None else json.dumps(resolution.snapshot.to_data()),
    }


def run_session(rng: random.Random, pool: list[CapabilityDescriptor], identities: list[DescriptorIdentity]):
    catalog = Catalog()
    steps: list[dict[str, object]] = []
    for index in range(60):
        if index < 25:
            action = rng.choice(["register", "register", "enable"])
        else:
            action = rng.choice(["register", "enable", "enable", "disable", "resolve", "resolve", "resolve"])
        step: dict[str, object] = {"action": action}
        try:
            if action == "register":
                descriptor = rng.choice(pool)
                step["descriptor"] = descriptor.to_data()
                catalog.register(descriptor)
            elif action in ("enable", "disable"):
                target = rng.choice(identities)
                step["identity"] = target.to_data()
                getattr(catalog, action)(target)
            else:
                if rng.random() < 0.15:
                    chosen = rng.sample(identities, rng.randint(1, 4))
                else:
                    by_kind = {}
                    for item in identities:
                        by_kind.setdefault(item.kind, []).append(item)
                    kinds = [DescriptorKind.RUNTIME, *rng.sample([k for k in by_kind if k is not DescriptorKind.RUNTIME], rng.randint(0, 6))]
                    chosen = [rng.choice(by_kind[k]) for k in kinds]
                    rng.shuffle(chosen)
                step["selections"] = [item.to_data() for item in chosen]
                request = ResolutionRequest(tuple(chosen))
                step["resolution"] = resolution_data(catalog.resolve(request))
        except (TypeError, ValueError, LookupError) as error:
            step["error"] = error_data(error)
        step["revision"] = catalog.revision
        steps.append(step)
    steps.append(
        {
            "action": "inspect",
            "inspect": [[json.dumps(entry.descriptor.to_data()), entry.enabled] for entry in catalog.inspect()],
            "revision": catalog.revision,
        }
    )
    return steps


def resolutions() -> list[list[dict[str, object]]]:
    rng = random.Random(42)
    names = {
        "runtime": ["rt.a", "rt.b"],
        "connection": ["acct", "acct2"],
        "hands": ["hands"],
        "territory": ["motus.local", "motus.e2b"],
        "continuation": ["cont"],
        "program": ["prog"],
        "effect": ["eff"],
    }
    identities = [
        identity(kind, name, version) for kind, ns in names.items() for name in ns for version in ((1, 2) if kind == "runtime" else (1,))
    ]
    pool: list[CapabilityDescriptor] = []
    for ident in identities:
        for _ in range(2):
            requires = []
            for kind in rng.sample([k for k in KINDS if k != "runtime"], rng.randint(0, 3)):
                requires.append(
                    CompatibilityRequirement(
                        DescriptorKind(kind),
                        rng.choice([None, None, None, *names[kind]]),
                        rng.choice([1, 1, 1, 2]),
                        frozenset(rng.sample(["c1", "c2", "c3"], rng.randint(0, 1))),
                    )
                )
            try:
                pool.append(
                    CapabilityDescriptor(ident, frozenset(rng.sample(["c1", "c2", "c3"], rng.randint(1, 3))), tuple(requires))
                )
            except ValueError:
                pass
    return [run_session(rng, pool, identities) for _ in range(30)]


def snapshot_cases() -> list[dict[str, object]]:
    cases: list[dict[str, object]] = []
    runtime = {"schema_version": 1, "identity": {"kind": "runtime", "name": "rt", "contract_version": 1}, "offers": [], "requires": []}
    hands = {"schema_version": 1, "identity": {"kind": "hands", "name": "h", "contract_version": 1}, "offers": [], "requires": []}
    inputs = [
        {"schema_version": 1, "catalog_revision": 3, "descriptors": [runtime, hands]},
        {"schema_version": 1, "catalog_revision": 0, "descriptors": [hands, runtime]},
        {"schema_version": 1, "catalog_revision": 3, "descriptors": [hands]},
        {"schema_version": 1, "catalog_revision": 3, "descriptors": [runtime, runtime]},
        {"schema_version": 1, "catalog_revision": -1, "descriptors": [runtime]},
        {"schema_version": 1, "catalog_revision": True, "descriptors": [runtime]},
        {"schema_version": 1, "catalog_revision": 3, "descriptors": {}},
        {"schema_version": 2, "catalog_revision": 3, "descriptors": [runtime]},
        {"schema_version": 1, "catalog_revision": 3, "descriptors": [runtime], "x": 1},
        {
            "schema_version": 1,
            "catalog_revision": 3,
            "descriptors": [runtime, runtime | {"identity": {"kind": "runtime", "name": "rt2", "contract_version": 1}}],
        },
    ]
    for data in inputs:
        try:
            snapshot = ResolutionSnapshot.from_data(data)
        except (TypeError, ValueError) as error:
            cases.append({"input": data, "error": error_data(error)})
        else:
            cases.append({"input": data, "output": json.dumps(snapshot.to_data())})
    return cases


def main() -> None:
    corpus = {
        "profiles": profiles(),
        "descriptors": descriptors(),
        "snapshots": snapshot_cases(),
        "sessions": resolutions(),
    }
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE
    (out / "catalog_corpus.json").write_text(json.dumps(corpus, indent=1, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
