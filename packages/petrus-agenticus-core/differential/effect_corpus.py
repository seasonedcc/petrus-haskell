"""Generate ``effect_corpus.json``: the reference Effect layer's observable answers.

Run from the pinned upstream checkout with its virtual environment:

    cd upstream/petrus
    .venv/bin/python ../../packages/petrus-agenticus-core/differential/effect_corpus.py

Sections (``test/Petrus/Agenticus/EffectSpec.hs`` replays every one):

* ``digests`` -- ``digest_payload`` over generated payloads: Unicode keys and
  strings (controls, quotes, backslashes, DEL, U+0085, U+2028, astral), ints
  up to 10**100, bools, nulls, nesting; plus refused payloads (floats, NaN,
  infinities, non-object roots).  Each case keeps the canonical text and the
  digest, or the refusal class and message.
* ``proposal_digests`` -- ``EffectProposal.digest`` over generated proposals.
* ``decode`` -- ``from_data`` for every value type over valid data, every
  single-field mutation from a pool of hostile values, missing and extra
  keys, nested mutations, and the full cross-field products of evidence,
  lookup and decision shapes.  Each case keeps ``json.dumps(to_data())`` of
  the decoded value, or the refusal.
* ``gateway`` -- every reachable scripted path through ``EffectGateway``:
  the decision's ``json.dumps(to_data())`` and the provider call trace, or
  the refusal.
"""

from __future__ import annotations

import json
import math
import pathlib
import random
from dataclasses import replace

from petrus.agenticus.effect.gateway import EffectGateway
from petrus.agenticus.effect.model import (
    EffectDecision,
    EffectDecisionKind,
    EffectEvidence,
    EffectFence,
    EffectProposal,
    EffectReceipt,
    LookupDisposition,
    LookupResult,
    TargetIdentity,
    digest_payload,
)

OUT = pathlib.Path(__file__).with_name("effect_corpus.json")
rng = random.Random(20261010)

ALPHABET = (
    list("abcxyzABC019 _-.:/")
    + ["\x00", "\x01", "\x08", "\t", "\n", "\x0b", "\x0c", "\r", "\x1f", '"', "\\", "\x7f"]
    + ["é", "ü", "ß", "中", "文", "\x85", "\xa0", " ", " ", "﻿", "￿"]
    + ["😀", "𝄞", "\U0010ffff"]
)
SORT_KEYS = ["", "a", "A", "aa", "b", "Z", "é", "\x7f", "￿", "😀", "\U0010ffff", "中", "a\x00", "~"]


def refusal(error: Exception) -> dict[str, object]:
    return {"class": type(error).__name__, "message": str(error)}


def text(max_size: int) -> str:
    return "".join(rng.choice(ALPHABET) for _ in range(rng.randint(0, max_size)))


def scalar() -> object:
    choice = rng.randrange(9)
    if choice == 0:
        return None
    if choice == 1:
        return rng.random() < 0.5
    if choice == 2:
        return rng.randint(-1000, 1000)
    if choice == 3:
        return rng.choice([2**31, 2**53 + 1, 2**63, 2**64, 10**40, -(10**100), 0, -1])
    return text(20)


def value(depth: int) -> object:
    if depth <= 0 or rng.random() < 0.4:
        return scalar()
    if rng.random() < 0.5:
        return [value(depth - 1) for _ in range(rng.randint(0, 4))]
    return obj(depth - 1)


def obj(depth: int) -> dict[str, object]:
    keys = [rng.choice(SORT_KEYS) if rng.random() < 0.3 else text(8) for _ in range(rng.randint(0, 5))]
    return {key: value(depth) for key in keys}


def digest_cases() -> list[dict[str, object]]:
    payloads: list[object] = [
        {"message": "ready"},
        {},
        {"é": "ü"},
        {key: index for index, key in enumerate(SORT_KEYS)},
        {"nested": {"z": [1, {"b": None, "a": True}], "a": "😀"}},
        {"big": 10**100, "neg": -(2**64), "zero": 0},
        {"controls": "".join(chr(i) for i in range(32)) + '"\\\x7f'},
        {"line": "  \x85\xa0"},
    ]
    payloads += [obj(4) for _ in range(260)]
    refused: list[object] = [
        ["not-an-object"],
        "text",
        7,
        None,
        True,
        {"float": 1.25},
        {"zero": 0.0},
        {"negative-zero": -0.0},
        {"large": 1e300},
        {"nan": math.nan},
        {"inf": math.inf},
        {"-inf": -math.inf},
        {"nested": [1, 2, {"deep": [0.5]}]},
        {"ok": "fine", "late": {"x": 2.0}},
    ]
    for _ in range(20):
        payload = obj(3)
        payload[text(6)] = rng.choice([0.1, 1.0, -2.5, 1e-7])
        refused.append(payload)
    cases = []
    for payload in payloads + refused:
        try:
            digest = digest_payload(payload)
        except (TypeError, ValueError) as error:
            cases.append({"payload": payload, "refusal": refusal(error)})
            continue
        canonical = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        cases.append({"payload": payload, "canonical": canonical, "digest": digest})
    return cases


def proposal(payload: object | None = None) -> EffectProposal:
    return EffectProposal(
        proposal_id="proposal-7",
        effect_type="bulletin.publish",
        effect_version=1,
        payload_digest=digest_payload({"message": "ready"} if payload is None else payload),
        target=TargetIdentity("bulletin", "release-notes"),
        requested_authority_class="bulletin.publish",
    )


def fence_for(value: EffectProposal) -> EffectFence:
    return EffectFence(value.proposal_id, value.digest, 4, "revision-11", "episode-3", "attachment-8", 2)


def receipt_for(value: EffectProposal, raw: object | None = None) -> EffectReceipt:
    return EffectReceipt(
        value.proposal_id,
        value.digest,
        value.payload_digest,
        value.target,
        digest_payload({"provider_record": "record-1"} if raw is None else raw),
    )


def code() -> str:
    parts = ["".join(rng.choice("abcxyz019") for _ in range(rng.randint(1, 5))) for _ in range(rng.randint(1, 3))]
    first = rng.choice("abcxyz")
    joined = first + parts[0]
    for part in parts[1:]:
        joined += rng.choice("._-") + part
    return joined


def proposal_digest_cases() -> list[dict[str, object]]:
    cases = []
    for index in range(60):
        identity = "".join(c for c in text(12) if ord(c) >= 32).strip() or "p"
        value = EffectProposal(
            identity,
            code(),
            rng.choice([1, 2, 10**30]),
            digest_payload(obj(2)),
            TargetIdentity(code(), "target-" + str(index) + rng.choice(["", "é", "😀", "\x7f"])),
            code(),
        )
        cases.append({"data": value.to_data(), "digest": value.digest})
    return cases


HOSTILE = [
    None,
    True,
    False,
    0,
    -1,
    1,
    2,
    10**30,
    1.0,
    "",
    " x",
    "x ",
    "\x85x",
    "x\xa0",
    "x\x00y",
    "x\x7fy",
    "x" * 256,
    "x" * 257,
    "é" * 128,
    "é" * 129,
    "Bad-Code",
    "a..b",
    "a.b-c_d9",
    "1abc",
    "sha256:" + "0" * 64,
    "sha256:" + "A" * 64,
    "sha256:" + "0" * 63,
    "SHA256:" + "0" * 64,
    [],
    {},
    "applied",
    "superseded",
    "safe-to-retry",
    "indeterminate",
    "reject",
    "approve",
    "execute",
    "already-applied",
]


def decode_case(name: str, cls, data: object) -> dict[str, object]:
    try:
        decoded = cls.from_data(data)
    except (TypeError, ValueError) as error:
        return {"type": name, "data": data, "refusal": refusal(error)}
    return {"type": name, "data": data, "ok": json.dumps(decoded.to_data())}


def mutations(data: dict[str, object], samples: int) -> list[object]:
    out: list[object] = [[], None, "text", data | {"extra": 1}]
    for key in data:
        out.append({k: v for k, v in data.items() if k != key})
        for bad in rng.sample(HOSTILE, samples):
            out.append(data | {key: bad})
        nested = data[key]
        if isinstance(nested, dict):
            for inner in list(nested)[:3]:
                for bad in rng.sample(HOSTILE, 3):
                    out.append(data | {key: nested | {inner: bad}})
    return out


def decode_cases() -> list[dict[str, object]]:
    p = proposal()
    f = fence_for(p)
    r = receipt_for(p)
    other = replace(f, authority_epoch=5)
    wrong_id = EffectFence("another-proposal", p.digest, 4, "revision-11", "episode-3", "attachment-8", 2)
    wrong_digest = replace(f, proposal_digest="sha256:" + "0" * 64)

    def evidence(recovery, receipt=None, fence=f):
        return EffectEvidence(p.proposal_id, p.digest, p.payload_digest, p.target, fence, recovery, receipt)

    direct = evidence(None, r.receipt_digest)
    applied = evidence(LookupDisposition.APPLIED, r.receipt_digest)
    safe = evidence(LookupDisposition.SAFE_TO_RETRY)
    superseded = evidence(LookupDisposition.SUPERSEDED)
    indeterminate = evidence(LookupDisposition.INDETERMINATE)
    other_fence = evidence(LookupDisposition.SUPERSEDED, fence=other)

    bases: list[tuple[str, type, object]] = [
        ("target", TargetIdentity, p.target),
        ("proposal", EffectProposal, p),
        ("fence", EffectFence, f),
        ("receipt", EffectReceipt, r),
        ("lookup", LookupResult, LookupResult.applied(r)),
        ("lookup", LookupResult, LookupResult.safe_to_retry()),
        ("evidence", EffectEvidence, direct),
        ("evidence", EffectEvidence, applied),
        ("evidence", EffectEvidence, superseded),
        ("decision", EffectDecision, EffectDecision.reject(p, "host-policy-denied")),
        ("decision", EffectDecision, EffectDecision.approve(p, f)),
        ("decision", EffectDecision, EffectDecision(EffectDecisionKind.EXECUTE, p.proposal_id, p.digest, f, direct)),
        ("decision", EffectDecision, EffectDecision(EffectDecisionKind.INDETERMINATE, p.proposal_id, p.digest, f, safe)),
    ]
    cases = []
    for name, cls, base in bases:
        data = base.to_data()
        cases.append(decode_case(name, cls, data))
        for mutated in mutations(data, 8):
            cases.append(decode_case(name, cls, mutated))

    # Cross-field products.
    for disposition in [*(d.value for d in LookupDisposition), "bogus", None, 1]:
        for receipt in (None, r.to_data(), r.to_data() | {"receipt_digest": "nope"}):
            cases.append(
                decode_case("lookup", LookupResult, {"schema_version": 1, "disposition": disposition, "receipt": receipt})
            )
    for recovery in [None, *(d.value for d in LookupDisposition), "bogus", 3]:
        for receipt in (None, r.receipt_digest, "not-a-digest"):
            for fence in (f, wrong_id, wrong_digest):
                data = direct.to_data() | {"recovery": recovery, "receipt_digest": receipt, "fence": fence.to_data()}
                cases.append(decode_case("evidence", EffectEvidence, data))
    evidences = [None, direct, applied, safe, superseded, indeterminate, other_fence]
    for kind in [*(k.value for k in EffectDecisionKind), "bogus"]:
        for fence in (None, f, other, wrong_id):
            for ev in evidences:
                for reason in (None, "host-policy-denied", "Bad Reason"):
                    data = {
                        "schema_version": 1,
                        "kind": kind,
                        "proposal_id": p.proposal_id,
                        "proposal_digest": p.digest,
                        "fence": None if fence is None else fence.to_data(),
                        "evidence": None if ev is None else ev.to_data(),
                        "reason_code": reason,
                    }
                    cases.append(decode_case("decision", EffectDecision, data))
    return cases


class Script:
    """Scripted adapter and fence source recording the provider call trace."""

    def __init__(self, p: EffectProposal, steps: dict[str, str]):
        self.p = p
        self.steps = steps
        self.calls: list[str] = []
        self.lookups = 0

    def _lookup_answer(self, name: str) -> LookupResult:
        if name == "raise":
            raise RuntimeError("SECRET-lookup-crash")
        if name == "applied":
            return LookupResult.applied(receipt_for(self.p))
        if name == "applied-wrong":
            return LookupResult.applied(replace(receipt_for(self.p), proposal_id="another-proposal"))
        return {
            "safe-to-retry": LookupResult.safe_to_retry(),
            "superseded": LookupResult.superseded(),
            "indeterminate": LookupResult.indeterminate(),
        }[name]

    def lookup(self, proposal: EffectProposal) -> LookupResult:
        self.calls.append("lookup")
        self.lookups += 1
        return self._lookup_answer(self.steps["lookup1" if self.lookups == 1 else "lookup2"])

    def current(self, proposal: EffectProposal) -> EffectFence:
        self.calls.append("current")
        name = self.steps["fence"]
        fence = fence_for(self.p)
        if name == "raise":
            raise RuntimeError("SECRET-fence-crash")
        if name == "stale-authority":
            return replace(fence, authority_epoch=5)
        if name == "stale-head":
            return replace(fence, target_head="revision-12")
        if name == "wrong-proposal":
            return replace(fence, proposal_id="another-proposal")
        return fence

    def execute(self, proposal: EffectProposal, payload: dict[str, object], fence: EffectFence) -> EffectReceipt:
        self.calls.append("execute")
        name = self.steps["execute"]
        if name == "raise":
            raise TimeoutError("SECRET-response-lost")
        if name == "receipt-wrong":
            return replace(receipt_for(self.p), proposal_id="another-proposal")
        return receipt_for(self.p, {"executed": payload})


def gateway_cases() -> list[dict[str, object]]:
    lookups = ["safe-to-retry", "applied", "applied-wrong", "superseded", "indeterminate", "raise"]
    fences = ["same", "stale-authority", "stale-head", "wrong-proposal", "raise"]
    executions = ["receipt", "receipt-wrong", "raise"]
    payload = {"message": "ready"}
    unicode_payload = {"message": "pronto 😀", "regions": ["west", "north"], "n": 10**20}
    proposals = [
        (proposal(), payload),
        (
            EffectProposal(
                "operação-42",
                "deployment.rollout",
                10**12,
                digest_payload(unicode_payload),
                TargetIdentity("service", "pagamentos-é"),
                "deployment.production",
            ),
            unicode_payload,
        ),
    ]
    cases = []
    seen: set[str] = set()
    for index, (p, raw) in enumerate(proposals):
        for first in lookups:
            for fence in fences:
                for execution in executions:
                    for second in lookups:
                        steps = {"lookup1": first, "fence": fence, "execute": execution, "lookup2": second}
                        script = Script(p, steps)
                        decision = EffectGateway(script, script).execute(p, raw, EffectDecision.approve(p, fence_for(p)))
                        used = {"lookup1": first}
                        if "current" in script.calls:
                            used["fence"] = fence
                        if "execute" in script.calls:
                            used["execute"] = execution
                        if script.lookups > 1:
                            used["lookup2"] = second
                        key = json.dumps([index, used], sort_keys=True)
                        if key in seen:
                            continue
                        seen.add(key)
                        cases.append(
                            {
                                "proposal": index,
                                "steps": used,
                                "decision": json.dumps(decision.to_data()),
                                "calls": script.calls,
                            }
                        )
    # Refusals before any provider call.
    p, raw = proposals[0]
    approval = EffectDecision.approve(p, fence_for(p))
    refusals = [
        ("payload-mismatch", {"message": "changed"}, approval),
        ("payload-float", {"message": 1.5}, approval),
        ("payload-list", ["message"], approval),
        ("rejected", raw, EffectDecision.reject(p, "denied")),
        ("rejected-bad-payload", ["message"], EffectDecision.reject(p, "denied")),
        ("other-approval", raw, EffectDecision.approve(proposals[1][0], fence_for(proposals[1][0]))),
        ("other-approval-bad-payload", {"x": 0.5}, EffectDecision.approve(proposals[1][0], fence_for(proposals[1][0]))),
    ]
    for name, payload_value, decision in refusals:
        script = Script(p, {"lookup1": "safe-to-retry", "fence": "same", "execute": "receipt", "lookup2": "raise"})
        try:
            EffectGateway(script, script).execute(p, payload_value, decision)
        except (TypeError, ValueError) as error:
            cases.append({"proposal": 0, "refused": name, "payload": payload_value, "approval": decision.to_data(),
                          "refusal": refusal(error), "calls": script.calls})
        else:
            raise AssertionError(name)
    return cases


def main() -> None:
    p = proposal()
    corpus = {
        "golden": {
            "ready_digest": digest_payload({"message": "ready"}),
            "proposal_data": p.to_data(),
            "proposal_canonical": json.dumps(p.to_data(), ensure_ascii=False, sort_keys=True, separators=(",", ":")),
            "proposal_digest": p.digest,
        },
        "digests": digest_cases(),
        "proposal_digests": proposal_digest_cases(),
        "decode": decode_cases(),
        "gateway": gateway_cases(),
    }
    OUT.write_text(json.dumps(corpus) + "\n")
    print(
        f"wrote {OUT.name}: {len(corpus['digests'])} digests, {len(corpus['proposal_digests'])} proposal digests, "
        f"{len(corpus['decode'])} decode cases, {len(corpus['gateway'])} gateway cases"
    )


if __name__ == "__main__":
    main()
