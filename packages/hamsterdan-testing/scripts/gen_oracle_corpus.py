"""Generate the ReadinessModel oracle corpus for hamsterdan-testing.

Run from the repository root against the pinned upstream environment:

    upstream/hamsterdan/.venv/bin/python -I -B \
        packages/hamsterdan-testing/scripts/gen_oracle_corpus.py

Writes test/corpus/oracle.jsonl, one row per encoded facts document:

    {"input": <JSON text handed to ReadinessFacts.load>,
     "facts_sha256": sha256 of the compact JSON of ReadinessFacts.load(input).dump(),
     "expectation": ReadinessModel().evaluate(facts).dump(),
     "liveness": [evaluate_liveness(expectation, env, budget_exhausted=b)
                  for env in ENVIRONMENTS for b in (False, True)]}

or, when the reference refuses the document,

    {"input": ..., "refused": true, "rule": <__post_init__ message> | null}

The documents are seeded random facts drawn from small pools (so heads,
operations, identities, and authorities collide often enough to reach every
rule), with a share of hostile documents: wrong JSON types, unknown or
missing members, unknown vocabulary, and values that break each
construction rule.
"""

from __future__ import annotations

import hashlib
import json
import random
from pathlib import Path

from pydantic import ValidationError

from hamsterdan.testing.readiness import FairEnvironment, ReadinessFacts, ReadinessModel, evaluate_liveness

OUT = Path(__file__).resolve().parents[1] / "test" / "corpus" / "oracle.jsonl"
DOCUMENTS = 2000

RNG = random.Random("hamsterdan-testing oracle corpus")

HEADS = ["a" * 8, "c" * 8, "d" * 8, ""]
BASES = ["b" * 8, "e" * 8]
POLICIES = ["policy-1", "policy-2"]
LIFECYCLES = ["active", "active", "active", "draft", "merged", "closed"]
CHECK_STATUSES = ["queued", "running", "success", "success", "failure", "canceled", "unavailable"]
RECOVERIES = ["none", "automatic", "human_authorization", "blocked"]
REVIEW_STATUSES = ["pending", "clear", "clear", "blocking", "unable"]
DISPOSITIONS = ["open", "dismissed", "resolved"]
MUTATIONS = ["idle", "idle", "requested", "in_flight", "accepted_pending_admission", "ambiguous", "blocked"]
INTENTS = ["change", "repair"]
KINDS = [
    "dashboard",
    "findings",
    "conversation",
    "reminder",
    "readiness",
    "rerun",
    "git_mutation",
    "agent_review",
    "coding",
]
EFFECT_STATUSES = ["requested", "accepted", "ambiguous", "blocked", "rejected", "settled", "canceled"]
TIMER_STATUSES = ["scheduled", "due", "acknowledged", "canceled"]
CHECKS = ["build", "security", "lint"]
OBSERVATIONS = ["delivery:open", "delivery:comment:1", "delivery:comment:2", "delivery:review:1"]
OPERATIONS = ["push:comment:1", "push:comment:2", "ready:1", "dashboard:1"]
DIGESTS = ["one", "two"]
ENVIRONMENTS = [
    FairEnvironment(*(index != off for index in range(5))) for off in range(-1, 5)
]


def pick(values: list) -> object:
    return RNG.choice(values)


def claim(base: dict | None = None) -> dict:
    value = dict(base) if base is not None else {
        "installation": 44,
        "repository": 31,
        "pull_request": 7,
        "head": HEADS[0],
        "base": BASES[0],
        "policy": POLICIES[0],
        "lifecycle": "active",
        "strict_base": True,
        "base_current": True,
        "mergeable": True,
    }
    if RNG.random() < 0.35:
        value["head"] = pick(HEADS[:3])
    if RNG.random() < 0.1:
        value["base"] = pick(BASES)
    if RNG.random() < 0.1:
        value["policy"] = pick(POLICIES)
    if RNG.random() < 0.25:
        value["lifecycle"] = pick(LIFECYCLES)
    for flag in ("strict_base", "base_current", "mergeable"):
        if RNG.random() < 0.1:
            value[flag] = not value[flag]
    if RNG.random() < 0.02:
        value[pick(["installation", "repository", "pull_request"])] = pick([0, -1, 8])
    return value


def facts() -> dict:
    provider = claim()
    generation = pick([0, 1, 1, 1, 2, 3])
    admitted = None if generation == 0 else (provider if RNG.random() < 0.6 else claim(provider))
    if RNG.random() < 0.03:
        admitted = None if admitted is not None else claim(provider)
    head = admitted["head"] if admitted is not None else provider["head"]
    document: dict = {
        "subject": f"github:{provider['installation']}:{provider['repository']}:pr:{provider['pull_request']}",
        "authority": {"generation": generation, "admitted": admitted, "provider": provider},
    }
    if RNG.random() < 0.02:
        document["subject"] = "github:44:31:pr:8"
    if RNG.random() < 0.8:
        document["admitted_observations"] = [pick(OBSERVATIONS) for _ in range(RNG.randint(0, 4))]
    if RNG.random() < 0.85:
        required = RNG.sample(CHECKS, RNG.randint(0, 3))
        document["ci"] = {
            "head": head if RNG.random() < 0.85 else pick(HEADS),
            "required_checks": required,
            "checks": [
                {"name": pick(CHECKS), "status": pick(CHECK_STATUSES)} for _ in range(RNG.randint(0, 4))
            ],
            "recovery": pick(RECOVERIES),
        }
    if RNG.random() < 0.85:
        document["review"] = {
            "head": head if RNG.random() < 0.85 else pick(HEADS),
            "status": pick(REVIEW_STATUSES),
            "findings": [
                {"identity": f"finding-{n}", "blocking": RNG.random() < 0.5, "disposition": pick(DISPOSITIONS)}
                for n in range(RNG.randint(0, 2))
            ],
        }
    if RNG.random() < 0.85:
        document["human"] = {
            "approvals": RNG.randint(0, 2),
            "required_approvals": RNG.randint(0, 2),
            "changes_requested": RNG.random() < 0.2,
            "unresolved_conversations": pick([0, 0, 0, 1, 2]),
            "distinct_reviewer_required": RNG.random() < 0.3,
            "distinct_reviewer_approved": RNG.random() < 0.5,
        }
        if RNG.random() < 0.02:
            document["human"][pick(["approvals", "required_approvals", "unresolved_conversations"])] = -1
    grant = None
    if RNG.random() < 0.5:
        grant = {
            "identity": pick(OBSERVATIONS[1:]),
            "operation": pick(OPERATIONS[:2]),
            "authority": pick([provider, admitted or provider, claim(provider)]),
            "intent": pick(INTENTS),
            "intent_digest": "sha256:repair-request-1",
        }
    if RNG.random() < 0.6:
        status = pick(MUTATIONS)
        mutation = {
            "status": status,
            "operation": pick(OPERATIONS[:2]) if status != "idle" or RNG.random() < 0.2 else "",
            "head": head if status != "idle" or RNG.random() < 0.2 else "",
            "result_head": "",
            "authorization": grant,
        }
        if status in {"accepted_pending_admission", "ambiguous"} and RNG.random() < 0.6:
            mutation["result_head"] = provider["head"] if RNG.random() < 0.7 else pick(HEADS[:3])
        if RNG.random() < 0.03:
            mutation["result_head"] = pick(HEADS[:3])
        if RNG.random() < 0.03:
            mutation["operation"] = ""
        document["mutation"] = mutation
    if RNG.random() < 0.75:
        effects = []
        for _ in range(RNG.randint(0, 3)):
            status = pick(EFFECT_STATUSES)
            authority = pick([provider, admitted or provider, claim(provider)])
            accepted = None
            if status in {"accepted", "settled"} or RNG.random() < 0.3:
                accepted = pick([provider, authority, admitted or provider, claim(provider)])
            if RNG.random() < 0.02:
                accepted = None
            effects.append(
                {
                    "kind": pick(KINDS),
                    "operation": pick(OPERATIONS),
                    "authority": authority,
                    "content_digest": pick(DIGESTS),
                    "status": status,
                    "provider_authority_at_acceptance": accepted,
                    "authorization": pick([None, None, *OBSERVATIONS[1:3]]),
                    "blocks_readiness": RNG.random() < 0.7,
                }
            )
        document["effects"] = effects
    if RNG.random() < 0.5:
        document["timers"] = [
            {
                "identity": f"reminder:{n}",
                "status": pick(TIMER_STATUSES),
                "blocks_readiness": RNG.random() < 0.5,
            }
            for n in range(RNG.randint(0, 2))
        ]
    return document


def coherent() -> dict:
    """Facts a well-behaved host would admit: mostly ready, one gate at a time."""

    provider = claim()
    if RNG.random() < 0.6:
        provider["lifecycle"] = "active"
    head = provider["head"]
    observations = RNG.sample(OBSERVATIONS, RNG.randint(1, 3))
    required = RNG.sample(CHECKS, RNG.randint(0, 3))
    document: dict = {
        "subject": "github:44:31:pr:7",
        "authority": {"generation": RNG.randint(1, 3), "admitted": provider, "provider": provider},
        "admitted_observations": observations,
        "ci": {
            "head": head,
            "required_checks": required,
            "checks": [
                {"name": name, "status": "success" if RNG.random() < 0.85 else pick(CHECK_STATUSES)} for name in required
            ],
            "recovery": pick(RECOVERIES),
        },
        "review": {"head": head, "status": "clear" if RNG.random() < 0.85 else pick(REVIEW_STATUSES), "findings": []},
        "human": {"approvals": 1, "required_approvals": 1 if RNG.random() < 0.9 else 2},
    }
    if RNG.random() < 0.3:
        grant = {
            "identity": pick(observations),
            "operation": "push:comment:1",
            "authority": provider,
            "intent": pick(INTENTS),
            "intent_digest": "sha256:repair-request-1",
        }
        status = pick(MUTATIONS)
        document["mutation"] = {
            "status": status,
            "operation": "push:comment:1" if status != "idle" else "",
            "head": head if status != "idle" else "",
            "authorization": grant,
        }
        if status in {"accepted_pending_admission", "ambiguous"} and RNG.random() < 0.5:
            pushed = dict(provider, head=pick(HEADS[:3]))
            document["mutation"]["result_head"] = pushed["head"]
            if RNG.random() < 0.5:
                document["authority"]["provider"] = pushed
        if RNG.random() < 0.5:
            document["effects"] = [
                {
                    "kind": pick(["coding", "git_mutation"]),
                    "operation": "push:comment:1",
                    "authority": provider,
                    "content_digest": "one",
                    "status": pick(["requested", "accepted", "settled", "ambiguous"]),
                    "provider_authority_at_acceptance": provider,
                    "authorization": grant["identity"],
                }
            ]
    effects = document.setdefault("effects", [])
    for index in range(RNG.randint(0, 2)):
        effects.append(
            {
                "kind": pick(["dashboard", "findings", "conversation", "reminder", "readiness", "rerun", "agent_review"]),
                "operation": f"effect:{index}",
                "authority": provider,
                "content_digest": "one",
                "status": "settled" if RNG.random() < 0.7 else pick(EFFECT_STATUSES),
                "provider_authority_at_acceptance": provider,
            }
        )
    if RNG.random() < 0.3:
        document["timers"] = [{"identity": "reminder:1", "status": pick(TIMER_STATUSES), "blocks_readiness": RNG.random() < 0.5}]
    return document


def drop_defaults_sometimes(document: dict) -> dict:
    """Omit members that have defaults, as a hand-written document would."""

    for container in [document, *(document.get(key) for key in ("ci", "review", "human", "mutation"))]:
        if isinstance(container, dict) and RNG.random() < 0.2:
            for key in list(container):
                if key not in {"subject", "authority"} and RNG.random() < 0.3:
                    del container[key]
    return document


def paths(value: object, prefix: tuple = ()) -> list[tuple]:
    found = [prefix] if prefix else []
    if isinstance(value, dict):
        for key, item in value.items():
            found += paths(item, (*prefix, key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found += paths(item, (*prefix, index))
    return found


def hostile(document: dict) -> dict:
    """One structural fault the strict codec must refuse (or, rarely, accept)."""

    location = pick(paths(document))
    parent = document
    for step in location[:-1]:
        parent = parent[step]
    key = location[-1]
    fault = RNG.randrange(6)
    if fault == 0 and isinstance(parent, dict):
        parent["credential"] = "must-not-enter-the-model"
    elif fault == 1 and isinstance(parent, dict):
        del parent[key]
    elif fault == 2:
        parent[key] = pick(["7", 7, 7.0, True, None, [], {}, "provider-private"])
    elif fault == 3 and isinstance(parent[key], str):
        parent[key] = parent[key].upper() or "X"
    elif fault == 4 and isinstance(parent[key], bool):
        parent[key] = int(parent[key])
    elif fault == 5 and isinstance(parent[key], int) and not isinstance(parent[key], bool):
        parent[key] = float(parent[key])
    else:
        parent[key] = "provider-private"
    return document


def row(document: dict) -> dict:
    encoded = json.dumps(document, sort_keys=RNG.random() < 0.3, separators=(",", ":"))
    try:
        loaded = ReadinessFacts.load(encoded)
    except ValidationError as error:
        # The rule is pinned only when it is the sole refusal: pydantic reports
        # every failing member, the strict codec the first.
        errors = error.errors()
        rule = str(errors[0]["ctx"]["error"]) if len(errors) == 1 and errors[0]["type"] == "value_error" else None
        return {"input": encoded, "refused": True, "rule": rule}
    expectation = ReadinessModel().evaluate(loaded)
    return {
        "input": encoded,
        "facts_sha256": hashlib.sha256(
            json.dumps(loaded.dump(), ensure_ascii=False, separators=(",", ":")).encode()
        ).hexdigest(),
        "expectation": expectation.dump(),
        "liveness": [
            evaluate_liveness(expectation, environment, budget_exhausted=budget)
            for environment in ENVIRONMENTS
            for budget in (False, True)
        ],
    }


def main() -> None:
    rows = []
    for _ in range(DOCUMENTS):
        document = drop_defaults_sometimes(coherent() if RNG.random() < 0.5 else facts())
        if RNG.random() < 0.12:
            document = hostile(document)
        rows.append(row(document))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as out:
        for item in rows:
            out.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
    accepted = [item for item in rows if "expectation" in item]
    dispositions = sorted({item["expectation"]["disposition"] for item in accepted})
    rules = sorted({item["rule"] for item in rows if item.get("rule")})
    print(f"{len(rows)} rows, {len(accepted)} accepted, dispositions {dispositions}")
    print(f"rules: {rules}")


if __name__ == "__main__":
    main()
