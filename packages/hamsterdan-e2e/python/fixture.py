"""The tier C fixture: the repository, organization and App one host acts on.

Standard library only. A fixture file is one JSON object::

    {
      "repository": "seasonedcc/demo-pr-readiness-py",
      "organization": "seasonedcc",
      "org_id": 123,
      "repository_id": 456,
      "app_slug": "hamster-dan-py",
      "hero_reviewer": "a-second-account",
      "broker_digest": "<64 hex>",
      "validator_digest": "<64 hex>"
    }

``broker_digest`` and ``validator_digest`` are the operator's
``_broker_digest`` of the copy's ``.github/workflows/rerun-broker.yml`` and
``tools/rerun_broker.py`` (``scripts/e2e prepare-repos`` computes them after
substituting the App's bot login). Upstream's own values are ``HBNETWORK``.

The reference operator reads it through ``e2e_operator.py`` (a runtime
overlay), the Haskell operator through ``hamsterdan-e2e-operator``.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass
from pathlib import Path

FIELDS = (
    "repository",
    "organization",
    "org_id",
    "repository_id",
    "app_slug",
    "hero_reviewer",
    "broker_digest",
    "validator_digest",
)


@dataclass(frozen=True)
class Fixture:
    repository: str
    organization: str
    org_id: int
    repository_id: int
    app_slug: str
    hero_reviewer: str
    broker_digest: str
    validator_digest: str

    @property
    def bot_login(self) -> str:
        return f"{self.app_slug}[bot]"

    def to_json(self) -> dict[str, object]:
        return asdict(self)


HBNETWORK = Fixture(
    repository="HBNetwork/demo-pr-readiness",
    organization="HBNetwork",
    org_id=108842540,
    repository_id=1316665126,
    app_slug="hamster-dan",
    hero_reviewer="crisbastos",
    broker_digest="373195c1935ef1a339526a577a6e3e6c30b9b618a135cfec8bd6fd2ad9c15ef9",
    validator_digest="2869cce84573f4d3d21202a023f14b6138144667ae1a058cffab7442b7ab767a",
)

# The upstream fixture commit the operator's delegated broker digests were
# accepted at (operator.py:47), which tier C copies.
FIXTURE_COMMIT = "a83e9223f7ffc6b0af919b0b8261fa2578261b41"
UPSTREAM_BOT_LOGIN = "hamster-dan[bot]"


def parse(value: object) -> Fixture:
    if not isinstance(value, dict) or set(value) != set(FIELDS):
        raise ValueError(f"a fixture has exactly the members {', '.join(FIELDS)}")
    for name in ("org_id", "repository_id"):
        if type(value[name]) is not int or value[name] <= 0:
            raise ValueError(f"fixture {name} must be a positive integer")
    for name in ("repository", "organization", "app_slug", "hero_reviewer", "broker_digest", "validator_digest"):
        if not isinstance(value[name], str) or not value[name]:
            raise ValueError(f"fixture {name} must be a non-empty string")
    owner, _, name = value["repository"].partition("/")
    if not name or owner != value["organization"]:
        raise ValueError("fixture repository must be <organization>/<name>")
    return Fixture(**value)


def load(path: Path) -> Fixture:
    return parse(json.loads(path.read_text(encoding="utf-8")))


def broker_digest(source: str) -> str:
    """``operator._broker_digest``."""
    return hashlib.sha256(source.replace("\r\n", "\n").strip().encode()).hexdigest()


def substitute_bot(source: str, bot_login: str) -> str:
    """The rerun broker of a copy: upstream's bot login replaced by the App's."""
    return source.replace(UPSTREAM_BOT_LOGIN, bot_login)
