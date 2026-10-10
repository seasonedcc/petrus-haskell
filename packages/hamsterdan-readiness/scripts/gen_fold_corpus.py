"""Harvest the fold and gate-handler corpus for hamsterdan-readiness.

Run from the repository root against the pinned upstream environment:

    upstream/hamsterdan/.venv/bin/python -I -B \
        packages/hamsterdan-readiness/scripts/gen_fold_corpus.py

It runs the upstream net_v5 test suite (tests/unit/readiness/net_v5, in file
order) with every handler the harness wires wrapped by a recorder, so each
call the real journeys make is captured with its exact input and output:

  fold             a pure loop fold:   binding -> produced tokens | error
  prepare          a gate's prepare:   binding -> invocation | error
  project          a gate's project:   binding, result -> produced tokens | error
  project_failure  failure projection: binding, failure -> produced tokens | error

It then perturbs every recorded fold binding (one top-level field of one
bound token at a time: booleans flipped, integers bumped, strings extended
or emptied, containers emptied; at most PERTURBATIONS per transition,
chosen by a string-seeded generator) and records the reference's answer, so the
corpus also covers the folds' refusal and edge branches.

Observed calls are deduplicated and capped at OBSERVED_CAP per transition
and call kind (a string-seeded sample), which keeps the corpus small while
every transition the suite exercises stays represented.

Writes test/corpus/folds.jsonl, one call per line:

  {"call", "transition", "consumed", "read", "delivered",
   "result"?, "failure"?, "outcome"}

where a selection is [place, [[color, data], ...]], a token [color, data],
and outcome is {"tokens": [[place, [[color, data], ...]], ...]} |
{"invocation": {...}} | {"error": firing_failure_text(exc)}.
"""

from __future__ import annotations

import copy
import dataclasses
import json
import os
import random
import sys
from pathlib import Path

import pytest
from petrus.impetus.binding import HandlerResult
from petrus.impetus.instance import firing_failure_text
from petrus.impetus.petrinet import Binding, NetPath, Token

from hamsterdan.readiness.net_v5 import gating

ROOT = Path(__file__).resolve().parents[3]
UPSTREAM = ROOT / "upstream" / "hamsterdan"
OUT = Path(__file__).resolve().parents[1] / "test" / "corpus" / "folds.jsonl"
PERTURBATIONS = 24  # per transition
OBSERVED_CAP = 80  # per (transition, call)

ROWS: dict[str, dict] = {}
FOLDS: dict[str, tuple] = {}  # key -> (handler, binding, outputs)


def dumps(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def token(t: Token) -> list:
    return [t.color, t.data]


def selections(selected) -> list:
    return [[str(place), [token(t) for t in tokens]] for place, tokens in selected]


def produced(result) -> dict:
    if isinstance(result, HandlerResult):
        if result.opens or result.closes:
            raise AssertionError("V5 handlers never register deliveries")
        mapping = result.tokens
    else:
        mapping = result
    return {"tokens": [[str(place), [token(t) for t in tokens]] for place, tokens in mapping.items()]}


def binding_row(call: str, binding: Binding) -> dict:
    return {
        "call": call,
        "transition": str(binding.transition),
        "consumed": selections(binding.consumed),
        "read": selections(binding.read),
        "delivered": [token(t) for t in binding.delivered],
    }


def record(row: dict, run) -> object:
    try:
        value = run()
    except Exception as error:  # the engine records exactly this text
        row["outcome"] = {"error": firing_failure_text(error)}
        ROWS.setdefault(dumps(row), row)
        raise
    row["outcome"] = value[1]
    ROWS.setdefault(dumps(row), row)
    return value[0]


def invocation_json(inv) -> dict:
    return {
        "activity": inv.activity,
        "input": inv.input,
        "policy": dataclasses.asdict(inv.policy),
        "correlation": inv.correlation,
        "idempotency": inv.idempotency,
    }


def failure_json(failure) -> dict:
    return {
        "error": failure.error,
        "kind": failure.kind,
        "details": failure.details,
        "retryable": failure.retryable,
        "retry_after": failure.retry_after,
    }


def wrap_fold(handler):
    def fold(binding, outputs):
        row = binding_row("fold", binding)
        key = dumps(row)
        FOLDS.setdefault(key, (handler, binding, outputs))
        return record(row, lambda: (lambda r: (r, produced(r)))(handler(binding, outputs)))

    return fold


def wrap_activity(handler):
    class Recorded:
        def prepare(self, binding):
            return record(
                binding_row("prepare", binding),
                lambda: (lambda inv: (inv, {"invocation": invocation_json(inv)}))(handler.prepare(binding)),
            )

        def project(self, binding, result):
            row = binding_row("project", binding) | {"result": result}
            return record(row, lambda: (lambda r: (r, produced(r)))(handler.project(binding, result)))

    if hasattr(handler, "project_failure"):

        def project_failure(self, binding, failure):
            row = binding_row("project_failure", binding) | {"failure": failure_json(failure)}
            return record(row, lambda: (lambda r: (r, produced(r)))(handler.project_failure(binding, failure)))

        Recorded.project_failure = project_failure
    return Recorded()


ORIGINAL_WIRE = gating.wire_gates


def recording_wire_gates(built, gates, definitions, derived=None):
    handlers = ORIGINAL_WIRE(built, gates, definitions, derived)
    return {
        uri: wrap_activity(h) if hasattr(h, "prepare") else wrap_fold(h) if callable(h) else h
        for uri, h in handlers.items()
    }


class Recorder:
    @pytest.hookimpl(trylast=True)
    def pytest_collection_finish(self, session) -> None:
        for module in list(sys.modules.values()):
            if getattr(module, "wire_gates", None) is ORIGINAL_WIRE and module is not gating:
                module.wire_gates = recording_wire_gates


def variants(value):
    if isinstance(value, bool):
        return [not value]
    if isinstance(value, int):
        return [value + 1, 0] if value else [1]
    if isinstance(value, str):
        return [value + "~", ""] if value else ["x"]
    if isinstance(value, list):
        return [[]] if value else []
    if isinstance(value, dict):
        return [{}] if value else []
    return []


def perturb() -> None:
    by_transition: dict[str, list] = {}
    for key, (handler, binding, outputs) in FOLDS.items():
        for side in ("consumed", "read"):
            for arc, (place, tokens) in enumerate(getattr(binding, side)):
                for index, t in enumerate(tokens):
                    if not isinstance(t.data, dict):
                        continue
                    for field in t.data:
                        for value in variants(t.data[field]):
                            by_transition.setdefault(str(binding.transition), []).append(
                                (handler, binding, outputs, side, arc, index, field, value)
                            )
    for transition, candidates in by_transition.items():
        chosen = random.Random(transition).sample(candidates, min(PERTURBATIONS, len(candidates)))
        for handler, binding, outputs, side, arc, index, field, value in chosen:
            selected = [list(s) for s in getattr(binding, side)]
            place, tokens = selected[arc]
            tokens = list(tokens)
            data = copy.deepcopy(tokens[index].data)
            data[field] = value
            tokens[index] = Token(tokens[index].color, data)
            selected[arc] = (place, tuple(tokens))
            mutated = dataclasses.replace(binding, **{side: tuple(tuple(s) for s in selected)})
            row = binding_row("fold", mutated)
            try:
                record(row, lambda: (lambda r: (r, produced(r)))(handler(mutated, outputs)))
            except Exception:
                pass


def capped(rows: list[dict]) -> list[dict]:
    groups: dict[tuple, list] = {}
    for row in rows:
        groups.setdefault((row["transition"], row["call"]), []).append(row)
    kept = []
    for (transition, call), group in sorted(groups.items()):
        if len(group) > OBSERVED_CAP:
            picked = sorted(random.Random(f"{transition}:{call}").sample(range(len(group)), OBSERVED_CAP))
            group = [group[i] for i in picked]
        kept.extend(group)
    return kept


def main() -> None:
    os.chdir(UPSTREAM)
    code = pytest.main(
        ["-q", "-p", "no:randomly", "-p", "no:cacheprovider", "-o", "addopts=", "tests/unit/readiness/net_v5"],
        plugins=[Recorder()],
    )
    if code != 0:
        raise SystemExit(f"upstream suite failed: {code}")
    observed = capped(list(ROWS.values()))
    ROWS.clear()
    perturb()
    seen = {dumps(o) for o in observed}
    perturbed = [row for row in ROWS.values() if dumps(row) not in seen]
    rows = sorted(observed + perturbed, key=lambda r: (r["transition"], r["call"]))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(dumps(row) + "\n")
    print(f"{len(observed)} observed calls, {len(perturbed)} perturbations -> {OUT}")


if __name__ == "__main__":
    main()
